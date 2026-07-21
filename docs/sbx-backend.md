# sbx backend (EXPERIMENTAL, secondmate-only)

The `sbx` backend runs each secondmate inside its own clone-mode [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) microVM, with an in-guest tmux hosting the agent.
Host-side supervision rides the **signal bridge**: a per-secondmate host directory bind-mounted read-write into the VM at the same absolute path, whose files back `state/<id>.status` and `state/<id>.turn-ended` symlinks in the primary home.
`bin/fm-watch.sh`'s `scan_signals`, triage, grace coalescing, and the wake queue run byte-for-byte unchanged.

The authoritative design (topology, transport, verdict mapping, security model, and the measured virtiofs Gate 0 results) is agent-dotfiles' `docs/firstmate-sbx-secondmate-event-bridge.md` (rev 2).
This guide records the fork-side adapter contract and the empirical CLI facts it depends on.

Adapter: `bin/backends/sbx.sh`, dispatched through `bin/fm-backend.sh`.
Spawn branch: `bin/fm-spawn.sh` (secondmate-only; ship/scout sbx spawns are refused).
Tests: `tests/fm-backend-sbx.test.sh`, `tests/fm-spawn-sbx.test.sh`, `tests/fm-watch-sbx-signals.test.sh`.

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
4. Wires the turn-end hook to touch the mount's `<id>.turn-ended` **and** `<id>.beat`:
   claude via a Stop hook written into the guest clone's `.claude/settings.local.json` (git-excluded in-guest), codex via `-c notify=[...]` on the launch command.
5. For a codex harness, seeds the guest's `~/.codex/config.toml` project-trust entry for the home (idempotent), so the directory-trust dialog never parks the launch; the launch command itself carries `--dangerously-bypass-hook-trust` for the hooks gate.
6. Records the sbx-specific meta fields owned by [`docs/configuration.md`](configuration.md#runtime-backend), including `sbx_template=` when `FM_SBX_TEMPLATE` was set.
7. The launch delivery's send starts a **keep-alive** exec (below) pinning the VM through the launch turn.

Supported harnesses: **claude and codex** (the intersection of the sweep's verified list, sbx's installable agents, and a verified turn-end + resume shape).
Anything else is refused before any sandbox is created.

Latency budget: worst case ≈ `POLL` (15 s) + `SIGNAL_GRACE` (30 s) + sub-millisecond mount visibility.
The grace share is deliberate (coalescing a status write with its turn-end saves whole first-mate turns).
Measured live (2026-07-19, steady-state watcher): **34.5 s** turn-end → wake (≈4 s poll phase + 30 s grace), one coalesced wake for status + turn-end; a full steer of a stopped VM (resurrection + verified delivery) took 16.5 s and the guest's reply landed ~3 s later.
Idle supervision costs **zero** sbx CLI calls (the scan is pure host stats; stopped VMs stay stopped) - versus an `sbx exec`-polling design's ~240 exec round-trips/hour/secondmate at 302 ms p50 (Gate 0) that would also auto-start every stopped VM on each probe.
The design doc's v2 latency trigger is **not met**: the wake path is grace-dominated by design, and v2's event layer could only shave the ≤15 s poll share.

## Steering and resurrection (`fm_backend_sbx_send_*`)

Delivery is `sbx exec <name> -- tmux send-keys` into the in-guest `fm:fm-<id>` pane.
Because auto-stop kills the guest process tree, the send path owns the resurrection sequence:

1. Refuse a confirmed-absent/unreadable sandbox.
2. The tmux-ready check's `exec` starts a stopped VM as a side effect.
3. No guest tmux server → rebuild: new `fm` session at the recorded `home=`, relaunch the agent with its harness's **resume** command (`claude --continue ...` / `codex resume --last ... --dangerously-bypass-hook-trust`, notify re-wired for codex), wait `FM_SBX_RESURRECT_SETTLE` (default 8 s).
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
  - *Mount unavailable* (the host signal target goes missing → the `state/<id>.*` symlinks dangle): `scan_signals`'s `[ -e "$f" ]` gate follows the symlink, finds the target gone, and skips it - a **silent no-op**, no wake, no marker change, no crash. When the mount returns, `[ -e ]` passes and the next real write is detected normally (verified: wake resumed, `.seen-*` advanced). Note macOS `stat -L` on a dangling link returns the *link's own* size:mtime rather than failing, so the `[ -e ]` gate - not `stat_sig`'s `|| continue` - is what makes this safe.
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

## Teardown (`fm_backend_sbx_unlanded_work`)

Retiring an sbx secondmate is a `sbx rm --force`, which destroys the VM disk (above), so `fm-teardown.sh` verifies the guest's work landed **before** the kill - the in-VM half of teardown's host worktree safety check, which cannot see inside the microVM. The secondmate teardown path (non-`--force`) probes the guest through the generic `fm_backend_unlanded_work` dispatcher (only sbx implements it; host-worktree backends answer "nothing hidden"):

- The in-guest clone lives at the SAME absolute path as the recorded `home=` (clone mode), so the probe runs `git -C <home> status --porcelain` and `git -C <home> log --oneline HEAD --not --remotes` **inside** the VM.
- **Safe (proceed)** only for a clean tree whose every commit is on a remote (a fork counts), OR a confirmed-**absent** sandbox (already gone, nothing to lose).
- **Refuse (preserve the VM and home)** on uncommitted changes, on commits that live nowhere but the VM disk, OR on any *unverifiable* reading - an unreadable sandbox state or an in-guest `git` failure is never treated as clean (fail-safe, mirroring the host check's posture).
- A **stopped** VM is inspected too (its disk holds the work); `sbx exec` auto-starts it, acceptable because retire is an explicit one-shot act, not routine triage.
- No PR-merged / content-in-default fallback like the host ship check: a secondmate lands by pushing, and reproducing gh/PR resolution inside the VM is out of scope. `--force` is the captain's explicit discard authority and skips the probe entirely (a squash-merged-but-unpushed guest is confirmed that way).

## Remaining gaps

- **Keep-alive covers only host-initiated turns** - the pin is armed at delivery (launch and steers). A turn the guest agent starts on its own (its own crew supervision, a scheduled follow-up) has no pin and dies with the ~45-100 s post-disconnect stop if it outlasts it; the auto-stop grace is Docker's heuristic and may change under us. Revisit if sbx grows a keep-alive/idle knob. (Confirmed still open after step 4.)
- **Mid-session death detection is still session-start-only** - the beacon scan alarms on mount loss and stranding, but a secondmate whose VM goes *absent* mid-session (stale beat + gone sandbox) is still only caught by the next session-start sweep or a failing steer. Wiring a stale-beat → `sbx ls` probe into the beacon scan is the natural extension if this bites.
- **Guest-side home provisioning** - only the brief is seeded in v1; the rest of the private surface (`data/captain-shared.md`, `config/*` inheritance) stays absent in the guest, so the secondmate bootstraps with ABSENT markers.
  The full provisioning story is the companion backend design's scope.
- **Host OAuth rotation strands running claude guests** - the guest env carries a placeholder substituted host-side per request, so rotating the host token (e.g. a host-side `/login`) plus a stale custom secret 401s in-guest claude; refreshing the secret (`sbx secret set-custom ...`) hot-applies to running sandboxes, **but an already-401'd claude TUI caches its logged-out state and never recovers in place** - stop the VM and let the next steer's resurrection relaunch the process (verified live: 3 stranded guests all recovered on `sbx stop` + steer; codex guests were unaffected). The beacon's stranding alarm (above) now names the pattern for the captain; the recovery itself is still manual.

## Security posture

Guest-written signal content is untrusted data, never code: status lines are parsed for fixed verb shapes and never interpolated into a shell command.
The mount is the only deliberate guest-to-host write path, scoped to `~/dev/fm-signals/<id>/`; the symlink set caps what the scan can see, and signature-based change detection plus grace coalescing bound a hostile guest at roughly one wake per ~45 s per id.
No new network surface: host-localhost stays blocked, egress stays allowlisted, and the bridge carries no credentials.
