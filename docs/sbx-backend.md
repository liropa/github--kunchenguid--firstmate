# sbx backend (EXPERIMENTAL, secondmate-only)

The `sbx` backend runs each secondmate inside its own clone-mode [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) microVM, with an in-guest tmux hosting the agent.
Host-side supervision rides the **signal bridge**: a per-secondmate host directory bind-mounted read-write into the VM at the same absolute path, whose files back `state/<id>.status` and `state/<id>.turn-ended` symlinks in the primary home.
`bin/fm-watch.sh`'s `scan_signals`, triage, grace coalescing, and the wake queue run byte-for-byte unchanged.

The authoritative design (topology, transport, verdict mapping, security model, and the measured virtiofs Gate 0 results) is agent-dotfiles' `docs/firstmate-sbx-secondmate-event-bridge.md` (rev 2).
This guide records the fork-side adapter contract and the empirical CLI facts it depends on.

Adapter: `bin/backends/sbx.sh`, dispatched through `bin/fm-backend.sh`.
Spawn branch: `bin/fm-spawn.sh` (secondmate-only; ship/scout sbx spawns are refused).
Tests: `tests/fm-backend-sbx.test.sh`, `tests/fm-spawn-sbx.test.sh`, `tests/fm-secondmate-liveness.test.sh`, `tests/fm-watch-sbx-signals.test.sh`, `tests/fm-sbx-tracked-sync.test.sh`.

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
  Two tmux-capable templates verified as of 2026-07-20: **`adf-codex:v2`** (agent-dotfiles' `adf-codex:v1` + tmux 3.6, codex 0.142.5) and **`adf-claude:v3`** (agent-dotfiles' `adf-claude:v2` + tmux 3.6, claude 2.1.195).
  The template image and the sandbox's agent flavor are independent choices ("Agent flavor vs driver harness" below).
  Both templates' apt lists were corrupt in the base image; the tmux install recipe is `sudo find /var/lib/apt/lists -type f -delete && apt-get update && apt-get install -y tmux && apt-get clean` inside a builder sandbox, then `sbx template save`.
- Clone mode (`sbx create --clone`) clones the workspace repo into the VM **at the same absolute path**, mounts the host repo read-only at `/run/sandbox/source`, and carries only **committed** files (gitignored `data/`, `state/`, `config/` never arrive).
  Extra workspace mounts (the signal directory) are plain bind mounts at the same absolute path, read-write, with sub-millisecond guest-to-host visibility for both appends and mtime-only touches (Gate 0, agent-dotfiles design doc §10).
- Clone mode **refuses linked git worktrees** outright (`ERROR: --clone is not supported when run from a Git worktree (...); run from the main repository instead`, verified 2026-07-19).
  Secondmate homes for this backend must be **plain clones** - `fm-home-seed.sh <id> <path>`'s git-clone path, never a treehouse lease; `fm_backend_sbx_create_task` refuses a `.git`-file home before creating anything.
- **Auto-stop is HOST-CONNECTION-based, not guest-workload-based** (measured 2026-07-19): a VM with no live `sbx exec`/attach stops within roughly 45-100 s of the last connection closing, **even with a CPU-busy guest process**; one held `sbx exec sleep 130` kept the VM running for its full duration and the VM stopped ~45 s after it exited.
  A detached in-guest tmux agent therefore gets **no auto-stop protection at all** - unlike agent-as-exec rigs, where the run itself is the connection.
  This is why every turn-submitting delivery starts a keep-alive (below); the exact grace is Docker's heuristic and may change under us.
- **codex 0.142.5 gates a fresh home's first interactive launch behind TUI dialogs** that no one is in the pane to answer: a directory-trust dialog (cleared by seeding `[projects."<home>"] trust_level = "trusted"` into the guest's `~/.codex/config.toml` - the exact shape codex itself persists on accept) and a hooks-review gate for the home's committed `.codex/hooks.json` (cleared with `--dangerously-bypass-hook-trust` on the launch/resume commands; its `trusted_hash` scheme is codex-internal - not a plain sha256 of the hook command or its JSON object, probed empirically - so it cannot be pre-seeded).
  `--dangerously-bypass-approvals-and-sandbox` covers **neither** gate.
- **A freshly resumed codex TUI eats first keystrokes nondeterministically**: stable-looking notices swallow typed text without a trace, while the identical keys land fine seconds later (observed twice).
  Pane stability cannot distinguish a parked notice from a ready composer, which is why the steer path verifies submission by reading the pane back (below).

## Agent flavor vs driver harness (verified 2026-07-27)

`sbx create <agent>` picks the sandbox's **agent flavor**, which selects the credential wiring sandboxd makes available to the guest.
It does **not** decide which CLI the guest can run, and the two are **not symmetric**: a flavor can serve a driver it is not named after.
Firstmate therefore chooses them separately - the task's harness picks the driver, `FM_SBX_AGENT` pins the flavor - because a claude driver that must also run codex in-guest (a no-mistakes adversarial review) is expressible only as a codex-flavor sandbox.

Measured live 2026-07-27, both rows created from the same `docker.io/library/adf-codex:v4` template, guest codex 0.145.0:

| `sbx create` agent | `claude` CLI in guest | `codex` CLI in guest |
|---|---|---|
| `claude` | works (the `CLAUDE_CODE_OAUTH_TOKEN` custom secret is present in the guest env) | **401 Unauthorized** |
| `codex` | works (`claude --print --model claude-opus-5` returned live model output) | works (`gpt-5.6-sol` returned live model output) |

The codex failure on a claude-flavor sandbox is exact, against `https://chatgpt.com/backend-api/codex`:

```
{"detail":"Could not parse your authentication token. Please try signing in again."}
```

Cause: the guest's `~/.codex/config.toml` carries `experimental_bearer_token = "oai-oat01-proxy-managed"`, a **placeholder** the sandboxd proxy resolves only for a codex-flavor sandbox - the same placeholder-not-credential posture as the Anthropic side ("Guest shell-profile env" below).
The failure is therefore credential wiring, not a missing binary or a stale token, and no in-guest repair fixes it.

Supporting facts from the same probes:

- **The discriminating tell is at create time**: a codex-flavor create prints `Using stored OpenAI OAuth credentials`, and a claude-flavor create prints nothing.
- **Only the ACTIVE agent's own config file is regenerated at create.** `[features] hooks = true` and the entire sandboxd proxy block bake intact into a claude-flavor sandbox built from a codex template; the template's other-agent config survives, only its credential resolution does not.
- **sbx does not refuse a mismatched pairing.** `sbx create` with an agent the template was not built for warns and creates the sandbox anyway: `template "..." was built for the "codex" agent but you are using "claude"`.
  Choosing the pairing deliberately is therefore firstmate's job, which is why the adapter refuses an unservable pairing before any VM exists.
- **The launch and resume command templates need no change.** Guest codex is 0.145.0 (newer than this host's 0.142.5) and still carries `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, and `codex resume --last`.

What the adapter does with that matrix:

- `FM_SBX_AGENT` pins the flavor for a spawn, mirroring `FM_SBX_TEMPLATE`'s template pin.
  Unset or empty preserves the previous 1:1 flavor resolution and sandbox choice: the driver harness's own flavor.
  Template and flavor stay independent knobs: a template built for one agent can back a sandbox created with the other, at the cost above.
- `fm_backend_sbx_harnesses_for_agent` encodes the matrix (flavor `claude` serves the `claude` driver; flavor `codex` serves both), and `fm_backend_sbx_agent_for_harness` refuses an unsupported flavor, or a flavor that cannot serve the requested driver, naming what that flavor does serve.
- `bin/fm-spawn.sh` resolves the flavor before the projects check or signal-directory creation.
  [`docs/configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns the resulting task-meta field; "Agent liveness probe" below owns its durable respawn behavior and the manual-spawn exception.

Verified against the fixtures in `tests/fm-backend-sbx.test.sh`, `tests/fm-spawn-sbx.test.sh`, and `tests/fm-secondmate-liveness.test.sh` for resolution, refusal, the meta record, and respawn re-entry.
The credential matrix itself is the live measurement above; a codex-flavor sandbox driven by claude through firstmate's own spawn path has not yet been provisioned end to end.

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

The sweep's respawn re-enters the meta's **recorded** placement, not ambient detection: it passes `--backend` from the meta's `backend=`, `FM_SBX_TEMPLATE` from the meta's `sbx_template=`, and `FM_SBX_AGENT` from the meta's `sbx_agent=`.
Without this, a dead sbx secondmate on a `HERDR_ENV=1` host was respawned into a host-side herdr pane - a silent containment downgrade, not a recovery (found live 2026-07-20 during the design's §10 item 4 pass, fixed same day).
The harness is deliberately *not* pinned from meta - respawns re-resolve it through `config/secondmate-harness -> config/crew-harness -> own` (the durable-mode contract), and an sbx-unverified resolution is refused loudly before any sandbox is created, as is a re-resolved harness the recorded agent flavor cannot serve ("Agent flavor vs driver harness" above).
This persistence is load-bearing because changing the flavor requires destroying and recreating the VM; silently reverting to the default map could strand the guest without the credentials its work needs.
A hand-run `fm-spawn.sh <id> --secondmate` does not read task meta: read the recorded `sbx_agent=` and pass it as `FM_SBX_AGENT`, just as a manual reprovision must re-enter the recorded template pin.

Mid-session, the watcher's beacon scan (below) consumes the same turn-end beacon for bridge-health alarms; full mid-session *death* detection (stale beat checked against `sbx` state) remains session-start-only (design doc open question 6, partially closed).

## Signal bridge wiring (spawn)

`bin/fm-spawn.sh`'s sbx branch, per secondmate `<id>` (sandbox name `fm-<id>`, meta `window=sbx:fm-<id>`):

1. Creates `${FM_SBX_SIGNALS_ROOT:-~/dev/fm-signals}/<id>/` and passes it to `sbx create --clone` as the extra RW mount.
2. Symlinks `state/<id>.status` and `state/<id>.turn-ended` at the mount's files.
   A pre-existing regular signal file is folded into the mount file first, so history survives a host-to-sbx migration.
   The symlink set is the id allowlist: a guest-invented foreign-id file has no symlink and is invisible to the scan.
3. Seeds the brief into the guest at its own absolute path (clone mode drops gitignored files), rewriting the primary's status-file path to the mount file - the host symlink makes both names converge on the same file.
4. Runs guest-home provisioning: read-through symlinks for inherited local material and markers as described in "Guest-home provisioning" below, plus the credential-placeholder shell profile snippet described in "Guest shell-profile env" below.
5. Wires the turn-end hook to touch the mount's `<id>.turn-ended` **and** `<id>.beat`:
   claude via a Stop hook written into the guest clone's `.claude/settings.local.json` (git-excluded in-guest), codex via `-c notify=[...]` on the launch command.
6. For a codex harness, seeds the guest's `~/.codex/config.toml` project-trust entry for the home (idempotent), so the directory-trust dialog never parks the launch; the launch command itself carries `--dangerously-bypass-hook-trust` for the hooks gate.
7. Records the sbx-specific meta fields owned by [`docs/configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend).
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

## Guest shell-profile env (`CLAUDE_CODE_OAUTH_TOKEN`)

sbx plants `CLAUDE_CODE_OAUTH_TOKEN=<placeholder>` into the guest env once, at sandbox creation, and the claude agent does not pass it down to the processes it spawns.
An in-guest daemon the agent starts therefore comes up unauthenticated while interactive sessions in the same VM authenticate fine: observed live 2026-07-23 in the `agent-dotfiles` secondmate, where the no-mistakes daemon restarted from the secondmate's own shell failed with `Not logged in` / `401`, twice, each costing a validation round and a manual repair.
Verified at the time: `bash -lc` through `sbx exec` carries the placeholder; a child the agent spawns does not.

The same guest-home provisioning pass (`fm_backend_sbx_provision_guest_home`) closes it by re-supplying the value at shell init, which is the only seam a stripped child ever crosses:

- `~/.fm-sbx-env.sh` (mode 0600) is rewritten on every pass with `: "${CLAUDE_CODE_OAUTH_TOKEN:=<placeholder>}"` plus an `export`, and a one-line `. "$HOME/.fm-sbx-env.sh"` guard is inserted at the **top** of `~/.bashrc`, `~/.profile`, and `~/.bash_profile` when that file already exists (its presence would otherwise shadow `~/.profile` for bash login shells).
- A stale source line bearing firstmate's `# firstmate sbx guest env` signature is removed and reinserted before the first non-comment statement so resurrection repairs an owned line that landed below Debian's non-interactive early return.
- A profile mention without that signature is treated as operator-authored content: provisioning leaves the file byte-identical, prints a stderr diagnostic naming the profile, and still returns success.
- Rewriting an existing profile preserves its file mode, while a newly created profile keeps the default umask behavior.
- **Top, not bottom**: the stock Debian `~/.bashrc` the sbx templates build on returns early for non-interactive shells, and the failing case is precisely a non-interactive agent child, so an appended export would never run.
  `tests/fm-backend-sbx.test.sh` reproduces that early return in its guest-home fixture and measures what a non-interactive child actually inherits; asserting the line was written would pass either way.
- **`:=`, so the operator always wins**: a value already set in the child's env, or exported by the operator's own profile, is never overwritten, whatever the ordering.
- **The value never leaves the guest**: it is read from the provisioning exec's own guest env rather than passed as an argument, so it reaches no host process table and no host-side log.
  It is also refused unless every character is in `[A-Za-z0-9._:/+=-]`, because the snippet is shell source and an unexpected value must never become code - that set covers realistic token alphabets while excluding every character that could break out of the assignment.
- **No credential is involved**: the planted value is the proxy placeholder, not the token.
  The real token is substituted host-side on egress and never enters the VM (agent-dotfiles `docs/docker-sandboxes-fit-assessment.md`: an httpbin `/headers` echo showed the real value arriving server-side while the guest held only the placeholder, and the guest filesystem carried no token material).
  A host-side rotation reuses the pinned `--placeholder` string, so a persisted snippet does not go stale.

**Coverage**: new sandboxes get this at spawn, and existing sandboxes at their next resurrection or respawn - the same reach the `FM_INHERITABLE_CONFIG` re-assert has, for the same reason (both ride the one provisioning exec).
A guest that is running right now, with its tmux server alive, is not touched until it auto-stops and the next steer resurrects it.
Nothing here hot-applies to a live guest, and `~/.bash_login` is not handled (the Debian-based templates ship neither it nor `~/.bash_profile`).

Verified against the fixtures in `tests/fm-backend-sbx.test.sh` and `tests/fm-spawn-sbx.test.sh` (a fake `sbx` CLI plus a plain-directory guest-user-home fixture, per this doc's testing convention) - not yet re-verified end to end against a real sandbox VM the way the "Live verification status" section is.

## Guest claude gate trust (`~/.no-mistakes/worktrees`)

A fresh guest's first in-guest no-mistakes run parked because the pipeline's review agent needed the gate clone trust-accepted in the guest's shared `~/.claude.json`; the secondmate diagnosed and set it by hand on 2026-07-23, costing one full pipeline restart (fork issue #17).
Spawn's `claude*` guest-provisioning branch now pre-accepts that trust before launch, alongside the Stop hook.

The gate checks out every run into its own directory, `<no-mistakes home>/worktrees/<repo id>/<run id>`, so no fixed exact-path grant can cover a future run.
Path shape read from real host run logs 2026-07-29 (`/Users/lp1/.no-mistakes/worktrees/1b27f869c922/01KXY39H7YT9CT9YM5VCB395YG/bin/fm-supervise-daemon.sh`); the repo id is stable per gated repo (no-mistakes' own `repos` table keys it by working path) and the run id is a per-run ULID.

What makes a narrow grant possible is that claude resolves **workspace** trust by walking the cwd's ancestors, so a grant on any ancestor directory satisfies it.
Firstmate therefore grants exactly one key, the guest's gate worktree ROOT, which is the only ancestor every future run shares.
The walk only ever moves UP from cwd, so that grant never reaches `$HOME`, the secondmate's own home, its project clones, or `/`; `tests/fm-spawn-sbx.test.sh` asserts each of those stays untrusted by re-running claude's own resolution rule against the seeded file.

The exact per-worktree key is deliberately NOT granted, because trust is not one switch:

- **Workspace** trust (the launch-blocking dialog) walks ancestors.
- **Project-settings** loading (`.claude/settings.json` permissions, hooks, MCP servers) uses the git-root-canonicalized exact key and does **not** walk.

A gate worktree is its own git root, so the ancestor grant clears the dialog while leaving settings carried by the branch under review dropped - a gate reviewing a pull request must not adopt permissions or hooks from the code it is reviewing.
The narrow grant is thus strictly weaker than "trust the gate worktree", not merely narrower than "trust everything".

Merge, not replace: `~/.claude.json` is shared with the secondmate's own claude sessions and holds its credentials and accepted-workspace history.
An entry already marked trusted is left byte-for-byte alone, so respawns and resurrections over a kept sandbox converge, matching the codex trust seed's grep-then-append.
A guest without `python3`, an existing config that does not parse, or a parseable config whose `projects` map or gate-worktree entry is not an object prints a stderr diagnostic and continues.
Malformed state is left byte-for-byte untouched: not seeding costs one recoverable park on the first validation run, while failing the spawn or overwriting claude's own state costs the whole task.
The seed hard-codes no-mistakes' `worktrees/` layout, so an upstream layout change makes the grant inert and the park returns - the safe direction, never a wider grant.

### Verification (2026-07-29, claude 2.1.220, macOS 26.5.2 arm64)

Host-side, against throwaway fixtures and a scratch `HOME` - a real PTY under `tmux`, because the dialog is an interactive TUI component.
Each workspace below is its own git root, matching a gate worktree.

The seed's own guest script was extracted from `bin/fm-spawn.sh` and run under `dash` (the Debian templates' `/bin/sh`, stricter than the bash the host tests use) against a scratch `HOME`, then the `~/.claude.json` it produced was handed to a real `claude` at real gate-worktree paths.
Inside the granted root, `.../.no-mistakes/worktrees/1b27f869c922/01KYPG4E22ZN03GF19NXV2KRDQ`, no dialog - the session reached its normal banner:

```
│                  Welcome back!                  │
│   ~/…/1b27f869c922/01KYPG4E22ZN03GF19NXV2KRDQ   │
```

Outside it, `$HOME/work/repo` and `$HOME/.no-mistakes/repos/1b27f869c922.git` (a sibling of `worktrees/`, one level below the same `.no-mistakes` parent) both still park:

```
 Accessing workspace:
 ❯ 1. Yes, I trust this folder
```

That is the narrowness assertion measured rather than reasoned: the grant reaches every gate worktree and stops at the worktree root.
The same `dash` run also covered the seed's other branches - fresh file created, merge preserving an unrelated `oauthAccount` and a pre-existing project entry, byte-identical no-op on re-run, unparseable config left untouched with a diagnostic and a zero exit, and file mode preserved at 0644.

Print mode reports the settings half separately, and shows it does not walk.
With `.claude/settings.json` carrying one `permissions.allow` rule, `claude -p` printed `Ignoring 1 permissions.allow entry from .claude/settings.json: this workspace has not been trusted.` for a workspace whose ancestor was granted, and printed nothing for the same workspace granted by exact key, or for a plain subdirectory inside a granted git root.
`claude --help` additionally documents that the workspace trust dialog is skipped entirely in non-interactive mode (`-p`, or a non-TTY stdout), which is how no-mistakes invokes its agent - so on 2.1.220 the seed removes a dialog the interactive path still shows, and is inert rather than widening anything on the print path.

Behavior-level, against the real scripts with a faked `sbx` CLI:

```
$ bash tests/fm-spawn-sbx.test.sh | tail -1
# all fm-spawn-sbx tests passed
$ bin/fm-lint.sh; echo "exit=$?"
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
exit=0
```

**Not verified end to end against a real sandbox VM.**
The only guest on this host is the captain's running secondmate, which this change must not disturb, so the in-guest half - that `python3` resolves on the `sbx exec` PATH, and that a fresh guest's first validation run now starts clean - remains unproven until the next guest is built.
The `python3` expectation comes from the templates' own build-time assertion (`agent-dotfiles scripts/sbx-templates/lib.sh` asserts `python3 --version` through `sbx exec`, with mise shims symlinked into `~/.local/bin` ahead of the exec PATH), not from a measurement made here.
Also unmeasured in-guest: `agent-dotfiles scripts/sbx-templates/seed/claude-state.json` seeds `projects["/"].hasTrustDialogAccepted`, which given the ancestor walk would trust the entire guest filesystem; whether that key survives `sbx create`'s regeneration of the active agent's config is unknown, and the narrow seed here is correct either way (a no-op if it survives, the actual fix if it does not).

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

1. Refuse a confirmed-absent sandbox, or one whose inventory this caller cannot read (the two are reported apart - see "Caller reachability" below).
2. The tmux-ready check's `exec` starts a stopped VM as a side effect.
3. No guest tmux server → rebuild: first re-assert guest-home provisioning (above; idempotent, resurrect-only cost), then run the tracked-file sync at this pre-agent safe point ("Tracked-file sync" above; a skip never blocks the steer), then new `fm` session at the recorded `home=`, relaunch the agent with its harness's **resume** command (`claude --continue ...` / `codex resume --last ... --dangerously-bypass-hook-trust`, notify re-wired for codex), wait `FM_SBX_RESURRECT_SETTLE` (default 8 s).
4. **Verify the harness took the pane**: one `pane_current_command` read - a shell name means the resume died, and delivering there would execute the steer as a guest shell command (observed live before this check existed), so fail loudly instead.
5. **Wait for the TUI to stop redrawing**: up to `FM_SBX_RESURRECT_READY_TRIES` (default 15) 2 s polls for two consecutive identical pane captures - the watcher's own stability idiom - then let the caller deliver.

The steer itself (`fm_backend_sbx_send_text_submit`) **verifies submission**: after Enter it reads the pane back; text absent → clear (C-u) and retype; text parked in the composer with no busy footer → re-send Enter only (never retype); busy on the text → `submitted`.
Retries exhausted stays the conservative `unknown`.
**Presence means newly appeared, not merely visible**: the needle is the steer's first 24 chars (marker + a few payload chars), which a *previous* steer's rendered line in scrollback also matches - so the occurrence count is baselined from the full tmux history after the ready poll and before typing, and only a count above the baseline reads as our text (one extra capture exec per steer). Without this, a resume-time swallow behind a stale same-prefix line converts the designed retype into a no-op Enter loop and the steer is lost behind a clean exit (observed live, 5-secondmate soak: 1 of 5 concurrent resurrections).
Every successful turn-submitting delivery then fires a **keep-alive**: one background `sbx exec` whose guest-side loop pins the VM until the guest is done working (or `FM_SBX_KEEPALIVE_MAX`, default 7200 s, elapses) - without it, connection-based auto-stop kills any work that outlasts the post-disconnect grace, the turn-end never fires, and the secondmate silently freezes.
Literal typing and standalone special keys, including Enter, do not prove that a turn started, so they neither arm the delivery alarm nor start a keep-alive.
Verified text submissions and spawn's explicit literal-plus-composed-submit path do both.
The loop releases only when the id's `turn-ended` mount file has advanced past its delivery baseline (the original v1 condition) AND the guest shows no work: no tmux pane whose visible tail matches the busy regex (`FM_BUSY_REGEX`, the same busy idiom the watcher and the submit verify use), and no `*.status`/`*.turn-ended` file under the guest home's `state/` (an in-guest child worker's signals) touched within `FM_SBX_GUEST_ACTIVE_WINDOW` (default 120 s).
Releasing on the secondmate's own turn-end alone re-opened the auto-stop trap one level down: an in-guest crewmate holds no host connection, so the VM died 45-100 s after the secondmate's turn ended and killed the mid-implementation worker (fork issue #12, proven three times 2026-07-23, the third taking an in-guest no-mistakes daemon and a live validation run with it).
The busy-pane probe is the primary activity signal because worker status appends are sparse by contract (a mid-implementation worker may write nothing for half an hour) while a working TUI shows its busy tail continuously; the child-signal window is the secondary leg that bridges a worker's short between-turns gaps.
The pin stays bounded: an idle-parked worker TUI (no busy tail, no recent signals) is not work and never pins - recovering it after a stop is the secondmate's own stuck-worker playbook - so a genuinely idle guest still auto-stops and §8's stopped-is-healthy premise is preserved.
While work is visible, the loop touches the mount's `<id>.guest-active` breadcrumb (guest-written and untrusted, only ever stat'ed, never read), giving the host a pure-stat view of in-guest activity.
When the exec ends, the keep-alive's host-side wrapper classifies the outcome: an idle release or an idle cap expiry is silent, while a cap expiry with work still active - or an exec death while the breadcrumb was fresh (an explicit `sbx stop`, a crash) - waits `FM_SBX_MIDTASK_STOP_SETTLE` (default 120 s, covering the measured auto-stop grace), reads the sandbox state once (the only sbx CLI cost, spent per rare suspicious exit, never per poll), and on `stopped`/`absent` records the `state/.sbx-midtask-stop-` marker the watcher surfaces as a named mid-task-stop alarm (below).
The keep-alive loop, its release/pin decisions, and the wrapper's marker classification are verified against the fixtures in `tests/fm-backend-sbx.test.sh` (the loop executed directly with a fake tmux, the wrapper against the fake `sbx` CLI) - not yet re-verified end to end against a real sandbox VM the way the "Live verification status" section is.

In-guest daemons a workflow needs (e.g. the no-mistakes daemon) do not come back on VM start; the resumed agent restarts them on demand - its brief owns that knowledge.
Such a daemon inherits its credentials from the guest shell profiles ("Guest shell-profile env" above), not from the agent's own env.

Triage protection (design doc §7.3): `bin/fm-crew-state.sh`'s `pane_readable` uses the state probe for sbx (a stopped sandbox is present, classified from the status log), and the adapter's capture refuses outright unless the sandbox is already running - so routine triage can never churn an idle-stopped VM.

### Caller reachability (`fm_backend_sbx_transport_reachable`)

Steering requires the caller to reach the **sbx daemon**, and not every firstmate context can.
Every primitive above funnels through `fm_backend_sbx_ensure_stack`, whose first act is the `sbx ls --json` inventory read, so a caller with no route cannot steer a *running* sandbox any more than a stopped one.
Reachability is therefore a property of the caller, never of the guest's power state.

Verified on this host 2026-07-26 (`sbx ls --json` from inside a script, sandboxed vs not):

```
sandboxed:   rc=1  Starting sandboxd daemon...
                   Waiting for the previous sandboxd to exit...
                   ERROR: ensure daemon: previous sandboxd (PID 89025) did not exit within 10s
unsandboxed: rc=0  {"sandboxes":[{"name":"fm-agent-dotfiles",...,"status":"stopped"}]}
```

Denied the daemon socket, `sbx` concludes no daemon is running, tries to start its own, finds the real one's pid file, and gives up after ~10 s.
The agent-dotfiles sandbox policy lists `sbx` in `excludedCommands`, but that exempts only **top-level** commands - `sbx` nested inside `bin/fm-*.sh` stays sandboxed, which is exactly how the watcher calls it.
The same denial shape applies to the tmux backend's server socket (`/private/tmp/tmux-501/default`, `Operation not permitted`), so this is a general property of the sandboxed watcher context rather than an sbx quirk.
tmux has its own probe for that reason; the reachability contract and the evidence that its recovery leg is genuinely reachable live in [tmux-backend.md](tmux-backend.md#transport-reachability).

`fm_backend_sbx_transport_reachable` reports that route: a **confirmed absence is reachable** (the inventory answered; the target is simply gone), and only an unreadable inventory is unreachable.
`ensure_stack` reports the two apart, because they need opposite operator responses - recreate the sandbox, versus re-issue the steer from a context that can reach the daemon.

The probe costs ~10 s when denied, so callers must spend it only when they are about to steer, never per poll: idle supervision keeps its structurally-zero-sbx-CLI-calls property.
`bin/fm-pending-reply-lib.sh`'s recovery leg is the first caller - it asks once, after every eligibility gate has passed, and **defers** an unroutable recovery instead of spending the record's single attempt on a send that cannot leave the host (fork issue #27).

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

Every watcher cycle sweeps the `state/*.turn-ended` **symlinks** (only bridge-backed secondmates have them, so host-pane homes skip untouched) with pure host stats - zero sbx CLI calls, preserving the idle-supervision cost property. Three captain-facing alarms, all durable `check` wakes:

- **Mount health** (`sbx-mount:<id>`): the symlink's target *directory* gone means the mount vanished and the scan's `[ -e ]` skip has silently blinded the watcher to this secondmate. One alarm per outage (a `.sbx-mount-alarmed-<key>` marker suppresses repeats across watcher restarts); the mount returning clears the marker and re-arms. A dangling link whose directory *exists* is a fresh spawn that has not signaled - quiescent, no alarm.
- **Mid-task stop** (`sbx-midtask-stop:<id>`): surfaces the keep-alive wrapper's `state/.sbx-midtask-stop-` marker (above) - a VM that stopped while in-guest work was under way. A stopped VM fires no turn-ends, so the stranding counter is structurally blind to exactly this failure (fork issues #12/#13: three real mid-work stops on 2026-07-23 produced zero alarms). The wake carries the wrapper's recorded reason and is consumed with its marker; a recurrence re-records, and no turn-end is required first (a VM stopped before its first turn-end still alarms).
- **Stranding** (`sbx-stranded:<id>`): two arms, because a count of events cannot measure their absence, and the observed failures come in both shapes. Both raise the same wake key and share one `.sbx-stranded-alarmed-` marker, so an episode alarms exactly once however it was detected, and status progress re-arms both - acknowledgement silences the delivery it answers but never clears the marker, or a guest that answers every steer without progressing would re-alarm on each one.
  - *No-progress turn-ends*: `FM_SBX_NOPROGRESS_TURNS` (default 3; 0 disables) consecutive turn-ends with zero status-file progress. This is the guest that still runs its turn-end hook but cannot make progress: each bare turn-end already surfaces as a generic signal wake, and the beacon names the pattern. Any status progress resets the counter and re-arms. A turn-end that lands while the mount's `<id>.guest-active` breadcrumb is fresh (within `FM_SBX_GUEST_ACTIVE_WINDOW`) is recorded but **not counted**: supervision turns during a long in-guest pipeline are legitimately status-sparse, and counting them produced issue #13's false alarms.
  - *Unacknowledged delivery*: `FM_SBX_DELIVERY_ACK_SECS` (default 900; 0 disables) of complete silence after the host last delivered to the guest.
    **This arm exists because the counter above is structurally blind to the worst variant**: an agent that cannot process at all fires no turn-ends, so the counter it depends on never advances (evidence below).
    Immediately before each potentially turn-submitting Enter, the send creates a host-written, content-free candidate.
    A successful send atomically promotes the latest injected attempt's candidate to `state/.sbx-delivered-<key>` without changing its pre-injection mtime and discards earlier unpublished candidates.
    If a later retry cannot be injected, the previous attempt's candidate remains the conservative delivery edge.
    A preparation failure never injects that attempt's Enter; before any earlier attempt, verified submit reports the typed text as pending, while after an earlier attempt it retains that attempt's candidate as the conservative edge.
    A rare post-delivery promotion failure reports that the input was delivered but untracked and explicitly says not to resend.
    The arm alarms when no guest-side file is strictly newer than the delivery.
    Acknowledgement is any of three signals - the turn-ended beat, the status file, or the `<id>.guest-active` breadcrumb - so the beacon **never rests on turn-ends exclusively**.
    The strict platform-stat comparison preserves native filesystem nanosecond precision, preventing a signal from immediately before delivery in the same integer-mtime second from acknowledging it.
    Comparing mount mtimes against the delivery mtime is stateless, so a watcher restart cannot lose the edge, and it trusts guest clocks no more than the freshness check above already does, with a far wider tolerance.
    The `[ -e ]` gate before each comparison is load-bearing: macOS stat behavior on dangling links could otherwise let a guest that never wrote a mount file acknowledge every delivery with its spawn-time symlink, silently and on one platform only.

  Delivery is **not** processing evidence: a send lands in the guest tmux pane whether or not the agent behind it can work, which is exactly why the acknowledgement clock is a separate signal from delivery success.
  The wake's reason carries the recovery (`sbx stop fm-<id>` + steer, secret refresh first).
  The delivery breadcrumb is host-written in the primary's `state/`, so a guest can neither forge nor suppress it, and a hostile guest touching the mount's `<id>.guest-active` forever only suppresses its own stranding alarm - the same self-harm class as deleting its own provisioning links.
  An sbx secondmate with no outstanding delivery is silent by construction: an empty queue and a stopped VM are its healthy resting state, never a fault.

Tracking state is per-id marker files in the primary's `state/` (`.sbx-beat-te-`, `.sbx-beat-status-`, `.sbx-noprogress-`, `.sbx-stranded-alarmed-`, `.sbx-mount-alarmed-`, `.sbx-midtask-stop-`, `.sbx-delivered-`, plus transient `.sbx-delivery-pending-` candidates), so counters survive the actionable exit each turn-end causes.
Teardown removes the transient candidates and, when the current key cannot also be another live task's legacy key, the durable markers with the id's other state files.
An ambiguous durable marker is left untouched rather than risking another task's live beacon; otherwise a leftover alarmed marker would suppress a re-provisioned same-id secondmate's alarm, and a leftover delivery marker would raise one for a delivery the replacement never received.

### Marker naming (`bin/fm-state-key-lib.sh`)

Every durable marker above is `<prefix><key>`; transient delivery candidates append the delimiter and nonce owned by `bin/fm-state-key-lib.sh`.
That library is the single owner of the key for the producer (this adapter), the consumer (`bin/fm-watch.sh`), and the cleanup (`bin/fm-teardown.sh`).
Its header owns the encoding, delimiter, length, reversibility, and signal-signature rules in full.

Until 2026-07-27 the key was `printf '%s' "$id" | tr '.' '_'`, which is not injective: ids `a.b` and `a_b` both produced `a_b` and therefore shared one file in every family.
That let one task's delivery breadcrumb arm or silence the other's unacknowledged-delivery alarm, surfaced one task's `.sbx-midtask-stop-` as a named alarm against the other, and let either task's teardown delete the other's live beacons.
`bin/fm-state-key-migrate.sh` renames pre-existing markers directly from the locked `bin/fm-session-start.sh` path; standalone bootstrap deliberately does not run the sweep.
The earlier acceptance-criterion wording that placed marker-key migration in `bin/fm-bootstrap.sh`'s mutating sweeps is superseded intent, written before the captain chose this session-start-only structure; the direct session-start invocation is deliberate, not implementation drift.
It resolves a legacy name only against task ids or signal filenames the home can enumerate from `state/`, reports rather than picks when a name maps to more than one live owner, and never discards marker state.
That errs toward under-reporting: an unmigrated marker reads as absent and each affected mechanism recovers on its next natural event, whereas a misattributed marker can alarm against a healthy secondmate and latch the marker that suppresses the real alarm.

#### Verification (2026-07-27, macOS 26.5.2 arm64, GNU bash 3.2.57(1)-release, ShellCheck 0.11.0)

Behavior-level, against the real scripts with a faked `sbx` CLI - the same harness the rest of this backend's suites use:

```
$ bash tests/fm-state-key.test.sh | tail -1
# fm-state-key.test.sh: all assertions passed
$ bash tests/fm-watch-sbx-signals.test.sh | tail -1
# all fm-watch-sbx-signals tests passed
$ bash tests/fm-backend-sbx.test.sh | tail -1
# all fm-backend-sbx tests passed
$ bash tests/fm-spawn-sbx.test.sh | tail -1
# all fm-spawn-sbx tests passed
$ bin/fm-lint.sh; echo "exit=$?"
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
exit=0
```

Operand-terminator and atomic no-replace verification (2026-07-28, macOS 26.5.2 build 25F84, stock `/bin` utilities):

```
$ printf 'source\n' > SRC
$ /bin/ln -P -- SRC DST; echo "exit=$?"
exit=0
$ /bin/ln -P -- SRC DST; echo "exit=$?"
ln: DST: File exists
exit=1
$ /bin/rm -f -- PATH; echo "exit=$?"
exit=0
$ /bin/mkdir -- PATH; echo "exit=$?"
exit=0
$ /bin/rmdir -- PATH; echo "exit=$?"
exit=0
$ /bin/mv -- SRC DST; echo "exit=$?"
exit=0
```

These results disprove the earlier claim that stock macOS `ln`, `rm`, `mkdir`, and `rmdir` reject `--`.
The terminators are correct guards against an operand path beginning with a hyphen, and the repeated `ln` refusal confirms the atomic no-replace primitive the migration uses.

`tests/fm-state-key.test.sh` covers the `a.b` / `a_b` collision directly (it fails against the superseded fold), round-trip reversibility, the path-segment and length properties, migration idempotency across three consecutive runs, and the migration's refusal to resolve an ambiguous legacy name.
`tests/fm-backend-sbx.test.sh` proves the producer half - two steers to fold-colliding ids publish separate `.sbx-delivered-` breadcrumbs - and that teardown of one id no longer reaches a neighbouring id's in-flight candidate.
`tests/fm-watch-sbx-signals.test.sh` proves the consumer half through the real watcher: a `.sbx-midtask-stop-` written for `a.b` alarms as `sbx-midtask-stop:a.b` and never as `a_b`.

The migration was also run against a scratch replica of this home's real `state/` **filenames** (76 entries copied as empty files; contents and the live home itself untouched), which holds one live sbx secondmate plus the `.seen-*` markers of long-retired tasks:

```
$ bin/fm-state-key-migrate.sh --state "$replica"
BOOTSTRAP_INFO: migrated 2 state marker name(s) to the reversible key encoding
$ bin/fm-state-key-migrate.sh --state "$replica"; echo "exit=$?"
exit=0
$ diff before.txt after.txt
32,33c32,33
< .seen-agent-dotfiles_status
< .seen-agent-dotfiles_turn-ended
---
> .seen-agent-dotfiles_2estatus
> .seen-agent-dotfiles_2eturn-ended
```

That is the expected shape: the live secondmate's id is a bare slug, so its `.sbx-beat-status-`, `.sbx-beat-te-`, and `.sbx-delivered-` markers were already current and were never moved - the acknowledgement clock stays exactly where it was - only the two signal signatures were renamed, the retired tasks' orphan signatures were left alone silently, nothing was ambiguous, and the second run was a no-op.

**Outstanding**: not exercised against a real sandbox.
No live VM was provisioned for this change, so whether `sbx` accepts a sandbox name containing `.` (`fm-a.b`) is unverified, and the migration has not been observed running against a live secondmate's beacon files.
The behavior above is host-side file naming only, which is why the faked-CLI suites cover it; the live gap is narrow but real and should be closed the next time a real sbx secondmate is provisioned.

### Stranding evidence and what each arm covers (2026-07-23 incident, corrected 2026-07-27)

The original stranding rationale in this document was **wrong on a load-bearing point**.
It stated that for the auth-dead variant "every steer still fires the Stop hook, so each turn-end surfaces as a generic signal wake".
The 2026-07-23 night disproves that: during the dead-credential episode the signal-bridge beat and turn-ended mount files were **never touched at all** - the beat directory was empty from creation, so zero turn-ends were produced.
An alarm counting turn-ends therefore could not see the very failure it was built for.
Across three real stalls that night the beacon produced **two false alarms and zero true alarms**.
The sbx version, harness version, exact observation commands, and raw output for that historical incident were not retained, so these figures are an operator incident record rather than reproducible live-host evidence.

The three fault shapes share one symptom (a secondmate that stops making progress) but have different triggers and different masking conditions, which is why one counter was wrong in both directions:

| Fault | Initiating trigger | What masks or exposes it | Covered by |
| --- | --- | --- | --- |
| Healthy status-sparse supervision | A long in-guest pipeline; the secondmate's own turns are legitimately sparse | Exposed as a false alarm by counting bare turn-ends; masked (correctly) by a fresh `guest-active` breadcrumb | Breadcrumb suppression on both arms - **silent** |
| Auto-stopped VM, work mid-flight | Docker's connection-based auto-stop, ~45-100 s after the last exec drops | A stopped VM emits no turn-ends, so any turn-end counter is blind | Keep-alive pin (prevention) + `sbx-midtask-stop` (naming), and the unacknowledged-delivery arm when the stop killed the delivered turn itself |
| Auth-dead TUI | A host OAuth rotation against a running guest; the TUI caches its logged-out state | Produces **no turn-ends and no status writes at all**, so every event-driven check stays silent forever | Unacknowledged-delivery arm |

Verified at the beacon level 2026-07-27 against implementation commit `1c20123701ef51590aa612aab690b1edd55f7c41` with `bash tests/fm-watch-sbx-signals.test.sh`, covering both directions - the silence cases are proven silent, not asserted.
Relevant exact output lines:

```
ok - a healthy idle secondmate with no outstanding delivery never alarms
ok - a delivery still inside the acknowledgement window never alarms
ok - a same-timestamp signal does not acknowledge a later delivery
ok - an unacknowledged delivery alarms once even with zero turn-ends
ok - a turn end acknowledges its delivery; a later unanswered one re-alarms
ok - a status line acknowledges a delivery with no turn-end at all
ok - live in-guest work acknowledges a delivery; stale work does not
ok - a fresh guest-active breadcrumb suppresses the stranding count; a stale one re-enables it
ok - status progress resets the no-progress counter; healthy turns never alarm
ok - acknowledging a delivery never re-arms an alarm that already stands
ok - status progress re-arms the alarm with no turn-end in the whole episode
```

Verified at the delivery boundary 2026-07-27 against implementation commit `1c20123701ef51590aa612aab690b1edd55f7c41` with `bash tests/fm-backend-sbx.test.sh`.
Relevant exact output lines:

```
ok - send_text_submit: text visible + busy pane -> submitted, typed once
ok - send_text_submit: each Enter retry uses a fresh delivery candidate
ok - send_text_submit: total failure preserves the previous delivery edge
ok - send_text_submit: failed retype preserves the earlier delivery edge
ok - send path: the delivery breadcrumb causally predates an immediate guest acknowledgement
ok - send path: a beacon preparation failure refuses before delivery
ok - send path: a post-delivery beacon failure reports untracked delivery without inviting resend
ok - send path: failed injection preserves the previous delivery edge
ok - send path: only proven composed submission arms the delivery beacon
```

The last two beacon-level cases are the falsification check for the shared-marker rules, not decoration: with acknowledgement restored to clearing the marker, `acknowledged steers must not re-arm a standing alarm` fails, and with the status bookkeeping moved back below the turn-end gates, `status progress must re-arm the alarm even with no turn-ended file at all` fails.
Both were confirmed failing against the reverted logic on 2026-07-27 before being accepted as passing.

The auth-dead reproduction is a fixture, not a live rig: `state/x.turn-ended` is left dangling with the mount directory present (the observed "empty from creation" shape) and the delivery breadcrumb backdated past the window.
**A live-host confirmation on a real auth-dead guest is still outstanding** - the logic is verified, the end-to-end path is not.

The pending-reply missed-report guard is a second host-side consumer of the same signal-bridge symlinks: `bin/fm-pending-reply-lib.sh` follows `state/<id>.status` to rescan for correlated replies and follows `state/<id>.turn-ended` to prove turn completion with zero sbx CLI calls (contract in that library's header); its recovery delivery preflight is covered by "Caller reachability" above.

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

- **Keep-alive covers only windows where a keeper is armed** - pins are created by turn-submitting deliveries (launch and verified text submissions) and released when the guest goes genuinely idle, so in-guest child work and guest-initiated turns are protected only while at least one keeper from a prior turn-submitting delivery is alive and under its cap ("Steering and resurrection" above). Guest work that starts after every keeper has released or capped can still die with the ~45-100 s post-disconnect stop; the no-keeper alarm gap is documented next. The auto-stop grace is Docker's heuristic and may change under us; revisit if sbx grows a keep-alive/idle knob.
- **A mid-task stop with no keeper alive is deliberately not alarmed** - the mid-task-stop marker is written by the keep-alive wrapper, so it needs a keeper from a prior turn-submitting delivery to still be running when the VM dies. Guest work killed after every keeper released or capped (or with keep-alives disabled, or after the host process tree that armed them went away) produces no marker. This is scoped out rather than solved with a watcher-side VM state poll, because **`stopped` is the healthy resting state of an idle secondmate**: state alone cannot separate "idle, correctly stopped" from "stopped on top of live child work", and the keeper is the only host-side observer of in-guest child work there is. Alarming on stopped-plus-anything would reintroduce exactly the false-positive class this beacon was fixed for. The unacknowledged-delivery arm still catches the sub-case where the stop killed the delivered turn itself (nothing comes back), and the pending-reply guard still notices a marked request that was never reported; a stop that kills only child work *after* the secondmate's own turn ended stays uncovered.
- **Mid-session death detection is still session-start-only** - the beacon scan alarms on mount loss and stranding, but a secondmate whose VM goes *absent* mid-session (stale beat + gone sandbox) is still only caught by the next session-start sweep or a failing steer. Wiring a stale-beat → `sbx ls` probe into the beacon scan is the natural extension if this bites.
- **Projects-bearing homes stay refused at spawn** until an in-guest re-clone story exists (the remaining deferral from the guest-home provisioning v2 scope; the other half - tracked files frozen at spawn HEAD - is closed by "Tracked-file sync" above, after the 2026-07-24 staleness evidence showed it biting).
- **The sandboxed watcher cannot steer a secondmate at all** - it has no route to the sbx daemon ("Caller reachability" above), so no automatic recovery, nudge, or repost it wants to send can leave the host, whatever the guest's power state. The pending-reply guard now defers those sends unspent and escalates them as owed rather than reporting a delivery it never made, but the delivery itself still has to come from a context that can reach the daemon. Closing this needs a sanctioned route for nested `sbx` calls from watcher-context scripts, which lives in the agent-dotfiles sandbox policy, not here; `excludedCommands` cannot supply it because it exempts only top-level commands.
- **Host OAuth rotation strands running claude guests** - the guest env carries a placeholder substituted host-side per request, so rotating the host token (e.g. a host-side `/login`) plus a stale custom secret 401s in-guest claude; refreshing the secret (`sbx secret set-custom ...`) hot-applies to running sandboxes, **but an already-401'd claude TUI caches its logged-out state and never recovers in place** - stop the VM and let the next steer's resurrection relaunch the process (verified live: 3 stranded guests all recovered on `sbx stop` + steer; codex guests were unaffected). The beacon's unacknowledged-delivery arm (above) now names the pattern for the captain - the arm that does not depend on turn-ends, because this variant produces none; the recovery itself is still manual.

## Security posture

Guest-written signal content is untrusted data, never code: status lines are parsed for fixed verb shapes and never interpolated into a shell command.
The mount is the only deliberate guest-to-host write path, scoped to `~/dev/fm-signals/<id>/`; the symlink set caps what the scan can see, and signature-based change detection plus grace coalescing bound a hostile guest at roughly one wake per ~45 s per id.
No new network surface: host-localhost stays blocked, egress stays allowlisted, and the bridge carries no credentials.
