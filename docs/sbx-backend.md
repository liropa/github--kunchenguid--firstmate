# sbx backend (EXPERIMENTAL, secondmate-only)

The `sbx` backend runs each secondmate inside its own clone-mode [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) microVM, with an in-guest tmux hosting the agent.
Host-side supervision rides the **signal bridge**: a per-secondmate host directory bind-mounted read-write into the VM at the same absolute path, whose files back `state/<id>.status` and `state/<id>.turn-ended` symlinks in the primary home.
`bin/fm-watch.sh`'s `scan_signals`, triage, grace coalescing, and the wake queue run byte-for-byte unchanged.

The authoritative design (topology, transport, verdict mapping, security model, and the measured virtiofs Gate 0 results) is agent-dotfiles' `docs/firstmate-sbx-secondmate-event-bridge.md` (rev 2).
This guide records the fork-side adapter contract and the empirical CLI facts it depends on.

Adapter: `bin/backends/sbx.sh`, dispatched through `bin/fm-backend.sh`.
Spawn branch: `bin/fm-spawn.sh` (secondmate-only; ship/scout sbx spawns are refused).
Tests: `tests/fm-backend-sbx.test.sh`, `tests/fm-spawn-sbx.test.sh`, `tests/fm-watch-sbx-signals.test.sh`, `tests/fm-sbx-tracked-sync.test.sh`.

## Empirical CLI facts (verified 2026-07-19, sbx CLI against a real shell-agent sandbox)

- `sbx ls --json` prints `{"sandboxes":[{"name","id","agent","status","workspaces":[...]}]}`.
  Observed `status` values: `running`, `stopped`.
  An absent name is simply missing from a parse-clean listing - that is the adapter's **confirmed absent**, distinct from a CLI failure.
- `sbx exec <name> -- ...` **auto-starts a stopped sandbox** (observed: "Sandbox ... started successfully", ~1.9 s to first command).
  This is why routine supervision reads (presence, capture, busy) are state-gated in the adapter: routine probes must use `sbx ls`, never `exec`; explicit teardown is the one exception because it must inspect the disk before destruction.
- `sbx exec`'s default working directory is the workspace path, at the **same absolute path** as on the host; the guest user is `agent`.
- `sbx stop <name>` stops the VM; disk state stays intact and the sandbox restarts on the next `exec` (~1.5-2 s).
  sbx also auto-stops idle sandboxes on its own - an idle-stopped secondmate is a HEALTHY state, not a failure.
- Auto-stop (and `sbx stop`) kill the guest **process tree**: the agent, its tmux server, and any in-guest daemons die; only disk survives.
  Empirical corroboration from agent-dotfiles: the in-guest no-mistakes daemon does not come back on VM restart.
- `sbx rm` requires `--force` non-interactively (the confirmation prompt dies on "stdin is not a terminal").
  `sbx rm --force` destroys the VM **including its disk** - the in-guest home clone's private `data/` and any unlanded work, which is why teardown probes the guest first (see "Teardown" below).
- `sbx exec` against an absent name fails rc 1 with `ERROR: no sandbox named '...'`.
- The stock `shell` agent image has **no tmux**.
  `fm_backend_sbx_create_task` verifies tmux inside the fresh sandbox and refuses loudly when the template lacks it; pin `FM_SBX_TEMPLATE` to a template image that ships tmux.
  Two verified templates as of 2026-07-20: **`adf-codex:v2`** (agent-dotfiles' `adf-codex:v1` + tmux 3.6, codex 0.142.5) for the codex harness, and **`adf-claude:v3`** (agent-dotfiles' `adf-claude:v2` + tmux 3.6, claude 2.1.195) for the claude harness.
  Both templates' apt lists were corrupt in the base image; the tmux install recipe is `sudo find /var/lib/apt/lists -type f -delete && apt-get update && apt-get install -y tmux && apt-get clean` inside a builder sandbox, then `sbx template save`.
- Clone mode (`sbx create --clone`) clones the workspace repo into the VM **at the same absolute path**, mounts the host repo read-only at `/run/sandbox/source`, and carries only **committed** files (gitignored `data/`, `state/`, `config/` never arrive).
  Extra workspace mounts (the signal directory) are plain bind mounts at the same absolute path, read-write, with sub-millisecond guest-to-host visibility for both appends and mtime-only touches (Gate 0, agent-dotfiles design doc §10).
- Clone mode **refuses linked git worktrees** outright (`ERROR: --clone is not supported when run from a Git worktree (...); run from the main repository instead`, verified 2026-07-19).
  Secondmate homes for this backend must be **plain clones** - `fm-home-seed.sh <id> <path>`'s git-clone path, never a treehouse lease; `fm_backend_sbx_create_task` refuses a `.git`-file home before creating anything.
- **Auto-stop is HOST-CONNECTION-based, not guest-workload-based** (measured 2026-07-19): a VM with no live `sbx exec`/attach stops within roughly 45-100 s of the last connection closing, **even with a CPU-busy guest process**; one held `sbx exec sleep 130` kept the VM running for its full duration and the VM stopped ~45 s after it exited.
  A detached in-guest tmux agent therefore gets **no auto-stop protection at all** - unlike agent-as-exec rigs, where the run itself is the connection.
  This is why every delivery starts a keep-alive (below); the exact grace is Docker's heuristic and may change under us.
- **codex 0.142.5 gates a fresh home's first interactive launch behind TUI dialogs** that no one is in the pane to answer: a directory-trust dialog (cleared by seeding `[projects."<home>"] trust_level = "trusted"` into the guest's `~/.codex/config.toml` - the exact shape codex itself persists on accept) and a hooks-review gate for the home's committed `.codex/hooks.json` (cleared with `--dangerously-bypass-hook-trust` on the launch/resume commands; its `trusted_hash` scheme is codex-internal - not a plain sha256 of the hook command or its JSON object, probed empirically - so it cannot be pre-seeded).
  `--dangerously-bypass-approvals-and-sandbox` covers **neither** gate.
- **A freshly resumed codex TUI eats first keystrokes nondeterministically**: stable-looking notices swallow typed text without a trace, while the identical keys land fine seconds later (observed twice).
  Pane stability cannot distinguish a parked notice from a ready composer, which is why the steer path verifies submission by reading the pane back (below).

## Agent liveness probe (`fm_backend_sbx_agent_alive`)

Upstream three-valued contract (`bin/fm-backend.sh`; the session-start secondmate-liveness sweep acts only on a confident `dead`).
Probe order:

| Evidence | Verdict | Why |
|---|---|---|
| `<id>.beat` mtime within `FM_SBX_BEAT_GRACE` (default 300 s) | `alive` | The guest turn-end hook touched the beat moments ago; costs one host `stat`, no sbx CLI call. |
| state `running` | `alive` | VM up. |
| state `stopped` | `alive` | Idle-resumable: disk intact, restarts in ~2 s; a respawn here would destroy a healthy secondmate. |
| state `absent` (parse-clean listing lacks the name) | `dead` | Truly gone; the sweep may re-provision. |
| CLI error / unparseable JSON / unrecognized status | `unknown` | **Never `dead`**: a transient docker/CLI hiccup must not trigger a duplicate-supervisor respawn. |

The sweep's harness gate (`bin/fm-bootstrap.sh`) demotes `dead` to `unknown` for harnesses outside `claude|codex|opencode|pi|grok`; the sbx spawn branch only ever records `claude` or `codex` (see below), so sbx metas always pass that gate.

The sweep's respawn re-enters the meta's **recorded** placement, not ambient detection: it passes `--backend` from the meta's `backend=` and `FM_SBX_TEMPLATE` from the meta's `sbx_template=`.
Without this, a dead sbx secondmate on a `HERDR_ENV=1` host was respawned into a host-side herdr pane - a silent containment downgrade, not a recovery (found live 2026-07-20 during the design's §10 item 4 pass, fixed same day).
The harness is deliberately *not* pinned from meta - respawns re-resolve it through `config/secondmate-harness -> config/crew-harness -> own` (the durable-mode contract), and an sbx-unverified resolution is refused loudly before any sandbox is created.
`bin/fm-spawn.sh` records `sbx_template=` in meta so the respawn can reproduce the sandbox from durable state alone (a session-start sweep has no `FM_SBX_TEMPLATE` in its env).

Mid-session, the watcher's beacon scan (below) consumes the same turn-end beacon for bridge-health alarms; full mid-session *death* detection (stale beat checked against `sbx` state) remains session-start-only (design doc open question 6, partially closed).

## Signal bridge wiring (spawn)

`bin/fm-spawn.sh`'s sbx branch, per secondmate `<id>` (sandbox name `fm-<id>`, meta `window=sbx:fm-<id>`):

1. Creates `${FM_SBX_SIGNALS_ROOT:-~/dev/fm-signals}/<id>/` and passes it to `sbx create --clone` as the extra RW mount.
2. Symlinks `state/<id>.status` and `state/<id>.turn-ended` at the mount's files.
   A pre-existing regular signal file is folded into the mount file first, so history survives a host-to-sbx migration.
   The symlink set is the id allowlist: a guest-invented foreign-id file has no symlink and is invisible to the scan.
3. Seeds the brief into the guest at its own absolute path (clone mode drops gitignored files), rewriting the primary's status-file path to the mount file - the host symlink makes both names converge on the same file.
4. Provisions the rest of the guest home's private surface as a **read path** ("Guest-home provisioning" below): read-through symlinks for the inherited `config/` items and `data/captain-shared.md` onto the clone-mode RO source mount, plus the `.fm-secondmate-home` identity marker and a `.fm-sbx-signals-dir` marker (content = the signal-bridge dir's absolute path) as regular files - the guest user is `agent`, not the host user, so it cannot reconstruct `FM_SBX_SIGNALS_ROOT/<id>` from its own `$HOME` ("Backlog handoff" below).
5. Wires the turn-end hook to touch the mount's `<id>.turn-ended` **and** `<id>.beat`:
   claude via a Stop hook written into the guest clone's `.claude/settings.local.json` (git-excluded in-guest), codex via `-c notify=[...]` on the launch command.
6. For a codex harness, seeds the guest's `~/.codex/config.toml` project-trust entry for the home (idempotent), so the directory-trust dialog never parks the launch; the launch command itself carries `--dangerously-bypass-hook-trust` for the hooks gate.
7. Records the sbx-specific meta fields owned by [`docs/configuration.md`](configuration.md#runtime-backend), including `sbx_template=` when `FM_SBX_TEMPLATE` was set.
8. The launch delivery's send starts a **keep-alive** exec (below) pinning the VM through the launch turn.

Supported harnesses: **claude and codex** (the intersection of the sweep's verified list, sbx's installable agents, and a verified turn-end + resume shape).
Anything else is refused before any sandbox is created, as is a **projects-bearing home** (below).

Latency budget: worst case ≈ `POLL` (15 s) + `SIGNAL_GRACE` (30 s) + sub-millisecond mount visibility.
The grace share is deliberate (coalescing a status write with its turn-end saves whole first-mate turns).
Measured live (2026-07-19, steady-state watcher): **34.5 s** turn-end → wake (≈4 s poll phase + 30 s grace), one coalesced wake for status + turn-end; a full steer of a stopped VM (resurrection + verified delivery) took 16.5 s and the guest's reply landed ~3 s later.
Idle supervision costs **zero** sbx CLI calls (the scan is pure host stats; stopped VMs stay stopped) - versus an `sbx exec`-polling design's ~240 exec round-trips/hour/secondmate at 302 ms p50 (Gate 0) that would also auto-start every stopped VM on each probe.
The design doc's v2 latency trigger is **not met**: the wake path is grace-dominated by design, and v2's event layer could only shave the ≤15 s poll share.

## Guest-home provisioning (read-through inheritance)

Design: agent-dotfiles `docs/firstmate-sbx-guest-home-provisioning.md` (Gate P1 verified the original read-through shape live 2026-07-21; the 2026-07-23 stale-mount evidence below narrows it to inheritance, not runtime delivery).
Clone mode carries committed files only, so the home's private (gitignored) surface would otherwise be ABSENT in-guest and the secondmate would bootstrap without captain preferences or inherited crew settings.
Spawn rebuilds that surface as a **read path, not a copy pipeline**, in one idempotent exec after the brief seed (`fm_backend_sbx_provision_guest_home`, shared with resurrection):

- Each declared `FM_INHERITABLE_CONFIG` item (`config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/herdr-presentation-spaces`) and `data/captain-shared.md` become symlinks onto clone mode's RO source mount of the host home (`FM_SBX_SOURCE_MOUNT`, default `/run/sandbox/source`).
  That keeps the host home as the source every convergence point (spawn, the bootstrap secondmate sweep, `fm-config-push.sh`) already writes, but the mount is not a reliable low-latency delivery channel: after a VM stop/resurrect cycle it can lag host reality by hours, and a freshly written host file may be absent from the whole mount.
  Use it only as the guest-home inheritance read path that spawn/resurrection re-asserts; runtime handoff data that must be proven live must ride the signal bridge ("Backlog handoff" below).
  The RO mount is still stronger than the host-side mode-444 posture: the guest cannot write through it at all, and a guest deleting its own links only blinds itself until the next re-assert.
- `.fm-secondmate-home` is seeded as a **regular file** (content = the id): `fm_root_is_secondmate_home` hard-refuses symlinks, and with the marker present hometag and the is-secondmate predicates read the guest as what it is.
- Right after `sbx create`, spawn probes `test -r $FM_SBX_SOURCE_MOUNT/AGENTS.md` in-guest and refuses loudly when the mount is not readable there: the mount path is an sbx implementation detail, not a documented contract, so upstream drift must fail the spawn instead of leaving inheritance dangling forever (a half-provisioned secondmate is worse than none).
- **Projects-bearing homes are refused before `sbx create`** (`data/projects.md` registry entries or `projects/` clones, the same two signals `fm-home-seed.sh --no-projects` guards): sub-project clones are independent gitignored repos clone mode structurally cannot carry, and a secondmate whose charter references projects that silently don't exist in-guest would burn turns discovering it. Seed sbx homes with `--no-projects`; in-guest re-cloning is a designable v2.
- Resurrection re-runs the same pass before relaunching the agent, healing guest-side link/marker damage and picking up `FM_INHERITABLE_CONFIG` items declared since spawn - a list addition reaches existing guests at their next resurrect or respawn, not at the next push (`docs/configuration.md`).
- Teardown is unaffected: links and marker live under gitignored paths, so the landed-work probe's `git status --porcelain` stays clean.

Deliberately NOT inherited: `config/backend` (the guest detects its own in-VM backend) and `config/secondmate-harness` (a secondmate never spawns secondmates).

## Tracked-file sync (guest clone fast-forward)

Clone mode snapshots the host home's committed files into the VM exactly once, at provisioning, so the guest clone's tracked surface (`AGENTS.md`, `bin/`, `.agents/skills/`) froze at spawn HEAD while every host-side sync path - `/updatefirstmate`, the bootstrap secondmate sweep, `fm-spawn`'s pre-launch fast-forward - advanced only the HOST clone and reported updated/current from the host's point of view (fork issue #20).
Measured live 2026-07-24: `/updatefirstmate` fast-forwarded a host secondmate home `b6bdddf..698a68f` (instructions changed: AGENTS.md, bin, .agents/skills) while its guest VM, provisioned 2026-07-22, still ran the provisioning-era snapshot - a guest frozen pre-`bin/fm-backlog-ingest.sh` cannot merge a signal-bridge backlog handoff, and instruction or safety updates never reach live guests at all.

`fm_backend_sbx_tracked_sync` (`bin/backends/sbx.sh`) closes the gap by fast-forwarding the guest clone itself:

- **Source of truth is the host clone**, delivered as a self-contained git bundle (`<signals-dir>/tracked-sync/host-<tip>.bundle`, staged tmp+mv, ~7 MB at the current repo size) on the signal bridge - the only host<->guest surface proven live in both directions regardless of VM lifecycle.
  The clone-mode RO source mount is never a sync source: it can lag host reality by hours after a stop/resurrect cycle ("Backlog handoff" above; issue #11).
- **In-guest guards mirror `ff_target`'s** (`bin/fm-ff-lib.sh`), executed by one host-driven `sbx exec` running plain git: wrong-branch, dirty, current, diverged/unique-commit (is-ancestor), then `merge --ff-only`; detached HEAD is allowed, matching the secondmate-home ff contract, and a skip prints the honest reason with the guest's work untouched.
  A tracked-files fast-forward never touches the gitignored operational dirs (`data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`).
  The dirty check tolerates exactly the two untracked seeded markers (`.fm-secondmate-home`, `.fm-sbx-signals-dir`): a pre-fix guest's snapshot predates their `.gitignore` entries, and syncing past the ignore commit is precisely the upgrade the tolerance exists for - the `ignore_seed_marker` precedent.
- **Chicken-and-egg safe**: the guest side needs only plain git (the same in-guest guarantee the teardown landed-work probe already relies on), so the first sync into a guest that predates this mechanism requires nothing to have been delivered first.
- **Safe points only, never mid-turn**: resurrection runs the sync between the guest-home provisioning re-assert and the agent relaunch (nothing in-guest can be mid-turn there), and the sweep paths sync only a STOPPED VM - the agent process tree is dead, the sync exec auto-starts the VM, and it auto-stops again after.
  A running VM is skipped with the honest reason and picks the update up at its next restart; an absent sandbox is left to the liveness sweep, whose respawn re-clones the current host home anyway.
  Repeat runs are idempotent: an already-current guest is a no-op, and retries of the same tip reuse the published bundle.
- **`sbx_guest_synced=` meta cache**: the guest clone's last verified HEAD, recorded only from the guest's own report (spawn's post-create `rev-parse` read, or a completed sync verdict) - never assumed from the host clone.
  A cache hit short-circuits before any state probe or exec, so steady-state sweeps cost zero sbx CLI calls and zero VM churn; a missing cache (every pre-fix guest) verifies in-guest once, then caches.
  Guest output is untrusted data: verdicts are strictly pattern-matched, shas validated before recording, and skip reasons sanitized - a hostile guest faking a verdict can only mis-record its own staleness, the same self-harm class as deleting its own provisioning links.
- **Honest end-to-end reporting**: `bin/fm-update.sh` prints one `secondmate <id> guest: updated <a>..<b> / already current / skipped: <reason>` line per sbx-backed secondmate (detected from recorded task metadata, never by probing), and the bootstrap sweep prints a completed guest sync as `BOOTSTRAP_INFO:`, keeps an already-current guest silent, and surfaces every skip as an actionable `SECONDMATE_SYNC:` line - a host-clone line never implies the guest advanced.
  A registry-only secondmate with no live task metadata has no recorded sandbox and gets no guest line.

Verified against the fixtures in `tests/fm-sbx-tracked-sync.test.sh` (the fake `sbx` CLI executing the real guarded scripts against a guest-clone git fixture via the same-absolute-path remap, per this doc's testing convention) - not yet re-verified end to end against a real sandbox VM the way the "Live verification status" section is.

## Steering and resurrection (`fm_backend_sbx_send_*`)

Delivery is `sbx exec <name> -- tmux send-keys` into the in-guest `fm:fm-<id>` pane.
Because auto-stop kills the guest process tree, the send path owns the resurrection sequence:

1. Refuse a confirmed-absent/unreadable sandbox.
2. The tmux-ready check's `exec` starts a stopped VM as a side effect.
3. No guest tmux server → rebuild: first re-assert guest-home provisioning (above; idempotent, resurrect-only cost), then run the tracked-file sync at this pre-agent safe point ("Tracked-file sync" above; a skip never blocks the steer), then new `fm` session at the recorded `home=`, relaunch the agent with its harness's **resume** command (`claude --continue ...` / `codex resume --last ... --dangerously-bypass-hook-trust`, notify re-wired for codex), wait `FM_SBX_RESURRECT_SETTLE` (default 8 s).
4. **Verify the harness took the pane**: one `pane_current_command` read - a shell name means the resume died, and delivering there would execute the steer as a guest shell command (observed live before this check existed), so fail loudly instead.
5. **Wait for the TUI to stop redrawing**: up to `FM_SBX_RESURRECT_READY_TRIES` (default 15) 2 s polls for two consecutive identical pane captures - the watcher's own stability idiom - then let the caller deliver.

The steer itself (`fm_backend_sbx_send_text_submit`) **verifies submission**: after Enter it reads the pane back; text absent → clear (C-u) and retype; text parked in the composer with no busy footer → re-send Enter only (never retype); busy on the text → `submitted`.
Retries exhausted stays the conservative `unknown`.
**Presence means newly appeared, not merely visible**: the needle is the steer's first 24 chars (marker + a few payload chars), which a *previous* steer's rendered line in scrollback also matches - so the occurrence count is baselined from the full tmux history after the ready poll and before typing, and only a count above the baseline reads as our text (one extra capture exec per steer). Without this, a resume-time swallow behind a stale same-prefix line converts the designed retype into a no-op Enter loop and the steer is lost behind a clean exit (observed live, 5-secondmate soak: 1 of 5 concurrent resurrections).
Every successful delivery then fires a **keep-alive**: one background `sbx exec` that self-terminates guest-side when the id's `turn-ended` mount file advances (or after `FM_SBX_KEEPALIVE_MAX`, default 7200 s), pinning the VM through the guest turn the delivery started - without it, connection-based auto-stop kills any turn that outlasts the post-disconnect grace, the turn-end never fires, and the secondmate silently freezes.
Idle VMs still auto-stop once the turn ends: §8's stopped-is-healthy premise is preserved.

In-guest daemons a workflow needs (e.g. the no-mistakes daemon) do not come back on VM start; the resumed agent restarts them on demand - its brief owns that knowledge.

Triage protection (design doc §7.3): `bin/fm-crew-state.sh`'s `pane_readable` uses the state probe for sbx (a stopped sandbox is present, classified from the status log), and the adapter's capture refuses outright unless the sandbox is already running - so routine triage can never churn an idle-stopped VM.

## Live verification status (codex rig 2026-07-19: adf-codex:v2; claude rig + 5-secondmate soak 2026-07-20: adf-claude:v3; scratch primary + plain-clone homes)

Verified end to end on real sandboxes (design doc §10 "Then (v1)" items 2, 3, 4, 7, 8 and §11 steps 3-4):

- **Full loop** (both harnesses): spawn (dialog-free launch), guest agent reads the brief, appends `working`/`done` to the mount's status file at the rewritten path, the turn-end hook touches turn-ended AND beat, the watcher coalesces status + turn-end through one grace into a single wake naming both files, `.wake-queue` populated, `.seen-*` advanced.
- **claude harness** (2026-07-20, adf-claude:v3): clean autonomous launch through a Stop hook that touched turn-ended + beat and surfaced a wake within ~30 s grace; `claude --continue` resume of a stopped VM lands a routed steer; the guest env carries the `CLAUDE_CODE_OAUTH_TOKEN` placeholder, substituted host-side by the sbx custom secret (the real token never enters the VM). Stopped-VM steer round-trip ≈ 23-24 s (VM restart + resume settle + verified submit).
- **Auto-stop survival**: signals written before an auto-stop surfaced on the next watcher cycle with the VM left **stopped** through triage; the already-surfaced signatures did not re-deliver.
- **Resurrection**: steer of a dead-stack sandbox restarts the VM, rebuilds the guest tmux, resumes the conversation (`codex resume --last` / `claude --continue`), and a routed steer processed by the resumed agent lands a `done` status through the bridge.
- **Sweep-respawn** (item 4, 2026-07-20): `sbx rm`-ing a running secondmate's sandbox makes the probe read `absent -> dead`; the session-start liveness sweep respawns it back into sbx with the recorded template, and the respawned agent completes a routed turn through the bridge. A stopped VM reads `stopped -> alive` and is never respawned. (This pass surfaced and fixed the containment-downgrade bug above.)
- **Fault injection** (item 8, 2026-07-20, all graceful - no crash, no execution, no marker corruption):
  - *Hostile content* (shell metacharacters, command substitutions, ANSI/control bytes in a status line): stored verbatim as data, never executed; the wake queue records only the filename descriptor, not the content. A host canary file was never created.
  - *Torn final line* (a partial append with no trailing newline): `last_status_line`'s `grep -v blank | tail -1` reads it as the last line and parses its verb normally; `.seen-*` advances to the real signature.
  - *Truncation / rotation* (the guest shrinks the status file): the size:mtime signature catches the shrink where a strict `-nt` mtime compare would not; the watcher wakes and `.seen-*` follows the smaller size.
  - *Mount unavailable* (the host signal target goes missing → the `state/<id>.*` symlinks dangle): `scan_signals`'s `[ -e "$f" ]` gate follows the symlink, finds the target gone, and skips it, while `scan_sbx_beacon` names the outage with one durable `sbx-mount:<id>` check wake per missing-mount episode.
    When the mount returns, `[ -e ]` passes, the mount alarm re-arms, and the next real write is detected normally (verified: wake resumed, `.seen-*` advanced).
    Note macOS `stat -L` on a dangling link returns the *link's own* size:mtime rather than failing, so the `[ -e ]` gate - not `stat_sig`'s `|| continue` - is what keeps fresh spawns quiescent until the mount writes real signal files.
- **Multi-secondmate soak** (step 4, 2026-07-20, two claude secondmates): **no data cross-talk** - each secondmate wrote only its own mount's status file (the per-id symlink allowlist holds); per-row wake-queue attribution is correct (each row names its own id's file). When two secondmates' turns end in the *same* grace window the watcher coalesces them into **one** firstmate wake whose reason lists all involved files across both ids - intended cost-bounding (N simultaneous turn-ends → 1 wake), not cross-talk, because the individual queue rows stay per-id. Each VM's auto-stop is independent (one stopped while the other stayed up under its own connection activity); idle supervision stays structurally zero sbx CLI calls regardless of count (secondmates are exempt from the watcher's pane-staleness capture).
- **Keep-alive**: with a pinned exec the VM survives the whole guest turn (measured inversely: unpinned VMs die ~45-100 s after the last connection, busy or not).
- **Five-secondmate soak** (2026-07-20 evening, 3× claude adf-claude:v3 + 2× codex adf-codex:v2, ~2 h 15 m on a 16 GB/8-core host): isolation, per-id wake attribution, and grace coalescing all hold at N=5 (a same-window burst of turn-ends coalesces to one wake naming every id's files; per-row attribution stays per-id; each guest's `data/soak-notes.md` contains only its own turns). Independent per-VM auto-stop, idle watcher structurally quiet. **Concurrent resurrection**: steering all 5 stopped VMs simultaneously lands every steer in 25-32 s each (vs the 23-24 s single-VM baseline - mild contention only); a 3-way claude round after re-auth took 26 s each. Host resource ceilings were never approached: Docker-family RSS stayed ~2-3.4 GB total across all 5 VMs, load average low single digits, no swap growth beyond the spawn ramp. The soak surfaced the stale-needle submit-verify defect above (fixed) and the token-rotation recovery note below.
- **Teardown landed-work probe, live**: a deliberately dirtied guest (`README.md` edit in-VM) made non-`--force` `fm-teardown.sh` REFUSE with the VM and home preserved; after restoring the file the same command proceeded (`sbx rm`), and four more clean secondmates retired the same way. Both probe paths verified on real sandboxes.

All six original codex-rig gaps and the containment-downgrade bug are fixed in this tree: the bash-3.2 brief-rewrite scramble, the printf-format quote-eating in the codex resume template, delivery into a dead pane after a failed resume, codex's trust-dialog launch park, resume-time keystroke swallowing (now a verified submit), the BSD-stat-signs-symlinks watcher freeze, and the sweep's ambient-backend containment downgrade.

## Beat-beacon alarms (`scan_sbx_beacon`, `bin/fm-watch.sh`)

Every watcher cycle sweeps the `state/*.turn-ended` **symlinks** (only bridge-backed secondmates have them, so host-pane homes skip untouched) with pure host stats - zero sbx CLI calls, preserving the idle-supervision cost property. Two captain-facing alarms, both durable `check` wakes:

- **Mount health** (`sbx-mount:<id>`): the symlink's target *directory* gone means the mount vanished and the scan's `[ -e ]` skip has silently blinded the watcher to this secondmate. One alarm per outage (a `.sbx-mount-alarmed-<id>` marker suppresses repeats across watcher restarts); the mount returning clears the marker and re-arms. A dangling link whose directory *exists* is a fresh spawn that has not signaled - quiescent, no alarm.
- **Stranding** (`sbx-stranded:<id>`): `FM_SBX_NOPROGRESS_TURNS` (default 3; 0 disables) consecutive turn-ends with zero status-file progress. The observed cause is an auth-dead claude TUI after a host OAuth rotation (below): every steer still fires the Stop hook, so each turn-end surfaces as a generic signal wake, but nothing named the pattern. Any status progress resets the counter and re-arms; one alarm per episode. The wake's reason carries the recovery (`sbx stop fm-<id>` + steer, secret refresh first).

Tracking state is per-id marker files in the primary's `state/` (`.sbx-beat-te-`, `.sbx-beat-status-`, `.sbx-noprogress-`, `.sbx-stranded-alarmed-`, `.sbx-mount-alarmed-`), so counters survive the actionable exit each turn-end causes; teardown removes them with the id's other state files (a leftover alarmed marker would suppress a re-provisioned same-id secondmate's alarm).

The pending-reply missed-report guard is a second host-side consumer of the same `turn-ended` files: `bin/fm-pending-reply-lib.sh` anchors a size/mtime signature at request delivery and reads a later change as turn completion for its recovery and escalation legs, with the same follow-symlinks stat discipline and zero sbx CLI calls (contract in that library's header).

## Teardown (`fm_backend_sbx_unlanded_work`)

Retiring an sbx secondmate is a `sbx rm --force`, which destroys the VM disk (above), so `fm-teardown.sh` verifies the guest's work landed **before** the kill - the in-VM half of teardown's host worktree safety check, which cannot see inside the microVM. The secondmate teardown path (non-`--force`) probes the guest through the generic `fm_backend_unlanded_work` dispatcher (only sbx implements it; host-worktree backends answer "nothing hidden"):

- The in-guest clone lives at the SAME absolute path as the recorded `home=` (clone mode), so the probe runs `git -C <home> status --porcelain` and `git -C <home> log --oneline HEAD --not --remotes` **inside** the VM.
- **Safe (proceed)** only for a clean tree whose every commit is on a remote (a fork counts), OR a confirmed-**absent** sandbox (already gone, nothing to lose).
- **Refuse (preserve the VM and home)** on uncommitted changes, on commits that live nowhere but the VM disk, OR on any *unverifiable* reading - an unreadable sandbox state or an in-guest `git` failure is never treated as clean (fail-safe, mirroring the host check's posture).
- A **stopped** VM is inspected too (its disk holds the work); `sbx exec` auto-starts it, acceptable because retire is an explicit one-shot act, not routine triage.
- No PR-merged / content-in-default fallback like the host ship check: a secondmate lands by pushing, and reproducing gh/PR resolution inside the VM is out of scope. `--force` is the captain's explicit discard authority and skips the probe entirely (a squash-merged-but-unpushed guest is confirmed that way).

## Backlog handoff (signal-bridge batches)

`bin/fm-backlog-handoff.sh` hands queued main-backlog items to a secondmate's own backlog (`AGENTS.md` section 10; `secondmate-provisioning`).
For an sbx-backed destination, that write can never land in the secondmate's host clone: clone mode's guest runs against a private in-VM clone snapshotted at provisioning, and the guest never re-reads a later host-side write into it (GitHub issue #11).
Steering the guest to copy the routed item from the clone-mode RO source mount instead - the first workaround this gap produced - is **not reliable either**: the mount can be hours stale after a VM stop/resurrect cycle (the guest sees the snapshot from its last provisioning or resurrection, not a live view), confirmed live 2026-07-23 (a freshly filed item was absent from the whole mount, and an existing file's mtime was hours behind host reality).
Do not steer a secondmate to copy from `FM_SBX_SOURCE_MOUNT` as a backlog-handoff delivery mechanism.

The only surface proven live in both directions regardless of VM lifecycle is the signal bridge, so delivery rides it instead:

1. `fm-backlog-handoff.sh` detects an sbx destination from the recorded task metadata (`backend=sbx` and `sbx_signals_dir=` in the resolving home's `state/<id>.meta`; never by probing the clone or the source mount) and, instead of writing into the secondmate's `data/backlog.md`, delegates the moved item(s) to `tasks-axi mv --to <signals-dir>/backlog-handoff/pending/<batch-id>.md` - the same atomic, connected-set-preserving delegation the non-sbx path uses, just to a different destination file. Success or failure of this move is unconditional and atomic exactly as it always was: on failure nothing moves, the freshly-seeded batch scaffold is removed, and the main backlog is untouched.
2. The secondmate is nudged via the ordinary routed `bin/fm-send.sh` path (steer, never a poll) to run `bin/fm-backlog-ingest.sh`.
3. `bin/fm-backlog-ingest.sh` (shipped in `bin/`, so every seeded home - sbx or not - has it) finds its own signal-bridge dir from the `.fm-sbx-signals-dir` marker, merges each pending batch into its own `data/backlog.md` via `tasks-axi mv` (per-key idempotent skip: an already-present key is left alone, so a batch mixing new and already-merged keys still merges the rest), and archives a batch whose tasks-axi mv succeeds - or that arrives with nothing left to merge - from `pending/` to `ingested/`. A batch whose merge fails stays in `pending/` for the next run to retry; it is never silently dropped or falsely archived.

Delivery is therefore asynchronous by design, and `fm-backlog-handoff.sh` reports it that way: its success output says **queued via the signal bridge**, explicitly disclaims guest-side confirmation, and points at the verification and recovery tools below - it never claims the item reached the secondmate's own backlog, and a failed nudge (the secondmate unreachable, or `fm-send` itself refusing) is reported as a loud failure while leaving the already-atomic batch artifact untouched (the data is not lost, only not yet actioned).
A batch's *location* on the signal bridge is its own ground truth, independent of the secondmate's own status replies: `pending/` means not yet merged, `ingested/` means the guest's own `tasks-axi mv` into its own backlog succeeded, `rolled-back/` means a host operator reclaimed it instead (below).

- **`bin/fm-backlog-handoff-status.sh <secondmate-id> [batch-id]`** - read-only; lists (or reports one named) batch's location and item keys, straight off the signal bridge. Use this to confirm actual ingestion rather than trusting the handoff command's immediate output alone.
- **`bin/fm-backlog-handoff-rollback.sh <secondmate-id> <batch-id>`** - the recovery path for a batch that will never be ingested (the sandbox is confirmed gone and will not be re-provisioned under the same id): reclaims every item still present in a `pending/` batch back into the main backlog via `tasks-axi mv`, then archives the (now-drained) batch to `rolled-back/`. Refuses loudly, with nothing moved, for an already-ingested, already-rolled-back, or unknown batch id - an already-ingested batch already lives in the secondmate's own backlog, and reclaiming it here would duplicate the item without the secondmate's cooperation. This is a rare, explicit, operator-run act, not routine recovery: the batch file carries no lock, so rolling one back while the guest is concurrently ingesting the same file races two independent `tasks-axi mv` calls against it - only run it after `fm-backlog-handoff-status.sh` confirms the batch is genuinely stuck, not merely slow.

Verified only against the fixtures in `tests/fm-backlog-handoff-sbx.test.sh`, `tests/fm-backlog-ingest.test.sh`, `tests/fm-backlog-handoff-status.test.sh`, and `tests/fm-backlog-handoff-rollback.test.sh` (a fake `sbx` CLI and plain-directory guest-home fixtures, per this doc's own testing convention) - not yet re-verified end to end against a real sandbox VM the way the rest of this document's "Live verification status" section is.

## Remaining gaps

- **Keep-alive covers only host-initiated turns** - the pin is armed at delivery (launch and steers). A turn the guest agent starts on its own (its own crew supervision, a scheduled follow-up) has no pin and dies with the ~45-100 s post-disconnect stop if it outlasts it; the auto-stop grace is Docker's heuristic and may change under us. Revisit if sbx grows a keep-alive/idle knob. (Confirmed still open after step 4.)
- **Mid-session death detection is still session-start-only** - the beacon scan alarms on mount loss and stranding, but a secondmate whose VM goes *absent* mid-session (stale beat + gone sandbox) is still only caught by the next session-start sweep or a failing steer. Wiring a stale-beat → `sbx ls` probe into the beacon scan is the natural extension if this bites.
- **Projects-bearing homes stay refused at spawn** until an in-guest re-clone story exists (the remaining deferral from the guest-home provisioning v2 scope; the other half - tracked files frozen at spawn HEAD - is closed by "Tracked-file sync" above, after the 2026-07-24 staleness evidence showed it biting).
- **Host OAuth rotation strands running claude guests** - the guest env carries a placeholder substituted host-side per request, so rotating the host token (e.g. a host-side `/login`) plus a stale custom secret 401s in-guest claude; refreshing the secret (`sbx secret set-custom ...`) hot-applies to running sandboxes, **but an already-401'd claude TUI caches its logged-out state and never recovers in place** - stop the VM and let the next steer's resurrection relaunch the process (verified live: 3 stranded guests all recovered on `sbx stop` + steer; codex guests were unaffected). The beacon's stranding alarm (above) now names the pattern for the captain; the recovery itself is still manual.

## Security posture

Guest-written signal content is untrusted data, never code: status lines are parsed for fixed verb shapes and never interpolated into a shell command.
The mount is the only deliberate guest-to-host write path, scoped to `~/dev/fm-signals/<id>/`; the symlink set caps what the scan can see, and signature-based change detection plus grace coalescing bound a hostile guest at roughly one wake per ~45 s per id.
No new network surface: host-localhost stays blocked, egress stays allowlisted, and the bridge carries no credentials.
