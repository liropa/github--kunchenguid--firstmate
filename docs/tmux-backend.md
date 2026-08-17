# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend; [`docs/configuration.md`](configuration.md) owns the current backend matrix.
tmux remains the fully verified reference path for secondmate homes.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

## Submit acknowledgement: "landed" is empty (with one busy-queue exception)

The shared `fm_tmux_submit_enter_core` (`bin/fm-tmux-lib.sh`) types the message once, then retries Enter (Enter only, never a retype) until the composer clears.
The submit is reported `empty` iff the composer cleared, which is the same corrected, border-aware detector the composer guard uses, so a bordered-but-empty composer is correctly seen as the positive acknowledgement of a delivered submit.
A genuine swallowed Enter leaves the typed text in the composer and the function reports `pending`; `fm-send` fails on `pending` so the captain learns the steer did not land instead of leaving it unsubmitted.

**Exception (opencode 1.18.4, on the tmux backend):** while the agent is mid-turn, opencode accepts Enter as a "send when the turn ends" keystroke but does not clear the composer until then, so the typed text stays visible the whole time.
After the Enter-retry budget is spent and the composer still reads `pending`, the submit core falls back to `fm_pane_is_busy`:
a busy pane means the harness accepted and queued the Enter (reported as `empty`, so the caller does not re-send), and an idle pane keeps `pending` as a genuine swallow.
This is the only place that exception lives; the herdr adapter observes the same opencode behavior but needs a separate fix (see the opencode note in [harness-adapters](../.agents/skills/harness-adapters/SKILL.md) and the opencode-busy gap recorded in [herdr-backend.md](herdr-backend.md)).
Regression coverage: `tests/fm-tmux-submit-busy.test.sh` covers the four scenarios (busy pane + pending composer -> `empty`, idle pane + pending composer -> `pending`, busy pane + cleared composer -> `empty`, idle pane + cleared composer -> `empty`).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Transport reachability

`fm_backend_tmux_transport_reachable` (`bin/backends/tmux.sh`) answers the generic probe in `bin/fm-backend.sh`: can THIS process context reach the tmux server at all?
It exists so `bin/fm-pending-reply-lib.sh`'s recovery leg defers an unroutable send instead of spending the record's single recovery attempt on it and then recording a delivery failure for a message that never went on the wire (fork issue #29, the tmux instance of the sbx defect in fork issue #27).

Every tmux steer primitive is a client connection to the server socket, so the probe reads that socket and nothing else.
Verified on this host 2026-07-27, tmux 3.7b, against a private socket (`tmux -L fmprobe-<pid>`):

```
no server yet:            rc=1  error connecting to /private/tmp/tmux-501/fmprobe-9019 (No such file or directory)
server up, one session:   rc=0  probe: 1 windows (created Mon Jul 27 01:29:38 2026)
server up, ABSENT window: rc=0  (capture-pane -t nosuch:0 -> "can't find session: nosuch")
after kill-server:        rc=1  no server running on /private/tmp/tmux-501/fmprobe-9019
sandboxed watcher socket: rc=1  error connecting to /private/tmp/tmux-501/default (Operation not permitted)
```

`list-sessions` never started a server (the socket did not reappear after `kill-server`), so the probe stays passive.
A confirmed-absent *window* is REACHABLE - the server answered - matching the sbx contract in [sbx-backend.md](sbx-backend.md); the send path's own missing-target handling owns that case.
`rc=1` deliberately covers both a denied socket and no server at all: neither can carry a send, and both must leave the one recovery unspent, because a respawned endpoint can still receive a held recovery but never a spent one.

### Why the recovery leg is reachable here (2026-07-27)

The sbx work assumed this gap was latent on tmux, on the reasoning that a context denied the tmux socket also cannot observe turn completion, so the recovery leg is never entered.
That masking does hold **within a single poll**, but not across polls, and the recovery leg is reachable without any sandbox-posture change or watcher restart:

- `request_turn_completed_epoch` is durable in the record and is never re-validated; `fm_pending_reply_send_recovery` reads that persisted field, not the current observation.
- A `busy` -> `idle` pane transition sets it as soon as it is seen, but the send additionally waits for `now - delivered_epoch >= grace_secs` (120 s by default).

So the guard **structurally** separates observing completion from attempting the send by up to the full grace, and the transport only has to become unreachable inside that window.
Reproduced end to end in one process, one record, real send path, stubbed tmux server (`tests/fm-pending-reply.test.sh`, `test_tmux_transport_loss_after_completion_defers_recovery_unspent`):
pane busy at T+10 s, pane idle at T+20 s (completion persisted, send correctly held), tmux server gone at T+200 s.
Before the probe, that sequence spent the attempt and published `blocked: pending-reply-recovery-delivery-failed:` - a delivery claim for a message that never left the host, which also reads to an operator as a sick secondmate rather than a missing route.

### Open gap: the other backends still assume reachable

`fm_backend_transport_reachable` now answers explicitly for every backend in `FM_BACKEND_KNOWN`, but only `sbx` and `tmux` have a real probe.
Each of the four steers through a control plane that could answer the same question, and each returns "unknown, assumed reachable" until a probe is verified against a denied context on real infrastructure:

- `orca` steers through `orca terminal send --json` and `cmux` through its `workspace list --json` control socket, so both have an obvious cheap read to probe with; they need verification on real infrastructure, not new design.
- `herdr` and `zellij` need actual design work first, because their readiness helpers (`fm_backend_herdr_server_ensure`, `fm_backend_zellij_server_ensure`) **start** the server as a side effect, and a reachability probe must stay passive the way `tmux list-sessions` and `sbx ls` do.

Until then a recovery on those backends spends its one attempt and reports a real delivery failure, exactly as before this change.
Assuming reachable remains the correct fallback - an unproven backend must keep attempting rather than be newly held back - but it is recorded here rather than left implied in the code, because a silent catch-all is what let the tmux gap survive the sbx work.

## Pane progress, not pane bytes (2026-08-15)

tmux exposes no native agent state, so `fm_backend_busy_state` always returns unknown and the stopped-worker alarm on this backend is the watcher's poll path alone.
That path used to require three byte-identical captures in a row before it would classify a window as stale.

<!-- fm-authority: firstmate-observation 2026-08-15 - measured on a live parked pane by the worker-pane-blocked-invisible investigation; the figures cannot be reproduced from inside a checkout -->
The investigation `worker-pane-blocked-invisible` measured why that gate failed here, on macOS with `claude 2.1.233` and `tmux 3.7b`.
Claude Code animates the pending-tool-call bullet U+23FA (bytes `e2 8f ba`) for as long as a tool call is outstanding, and a permission dialog raised mid-tool-call keeps it outstanding for the whole block.
A worker parked on that dialog, doing nothing at all, produced a capture that alternated between exactly two hashes on a period near 7 seconds, so the counter never reached 2 and the stale branch was never entered.
On one unchanged parked pane the real watcher surfaced `stale:` in 52s at `FM_POLL=10` and surfaced nothing in 16m01s at the default `FM_POLL=15` while provably still cycling.
Detection was a beat frequency between the poll interval and the animation period, not a property of the worker.
<!-- /fm-authority -->

`pane_progress_hash` in `bin/fm-watch.sh` now asks whether the window is progressing instead: a capture the window has shown within its last `FM_PANE_CYCLE_MEMORY` distinct captures (default 4) carries no new output, so it does not advance the window's progress hash.
The shape needs no knowledge of any harness's glyphs, which matters because only `claude 2.1.233` has been measured; normalizing the animated indicator itself away would need a new measured fact per harness.
`FM_PANE_CYCLE_MEMORY=1` retains only the immediately preceding capture, so a capture is progress unless it is identical to the one before it.
`tests/fm-watch-triage.test.sh`'s `test_animated_pane_still_reaches_stale` fails under that setting and passes without it.

Two limits are inherent to hashing the raw capture and are not closed here:

- A monotonic ticker (an elapsed-time counter, a token count) produces a genuinely new capture every poll forever. Such a pane never enters the stale branch at all, so it also never accumulates a wedge timer.
- A pane cycling among more distinct captures than the memory holds still advances its progress hash and is treated as new output, so it does not accumulate a wedge timer.

herdr needs none of this: `push_block_dwell_check` escalates a natively-reported blocked pane after `FM_PUSH_BLOCK_DWELL` and runs before the capture, so neither the gate nor a capture failure can suppress it.
This is what lets the tmux poll path reach the same state herdr reaches natively.

## An unreadable pane is reported, not skipped (2026-08-16)

Everything above assumes the capture succeeded.
`bin/fm-watch.sh` used to end that capture with `|| continue`, so a failed capture skipped the window with no triage line and no wake.
The heartbeat backstop cannot compensate, because `scan_captain_relevant_statuses` reads `state/*.status` and never touches a backend.
A watcher that could read no pane at all therefore kept absorbing heartbeats on schedule and kept touching `state/.last-watcher-beat`: alive to the guard, alive in its own log, and every pane-derived alarm silently off.

<!-- fm-authority: firstmate-observation 2026-08-15 - measured on the captain's host by the worker-pane-blocked-invisible investigation, section 6; a checkout cannot reproduce a sandbox denial -->
That failure is reachable on this host rather than hypothetical.
A sandboxed `tmux capture-pane -p -t <target> -S -40` fails with `error connecting to /private/tmp/tmux-501/default (Operation not permitted)` and exit 1, and `bin/fm-crew-state.sh` then reports `backend target gone` for a window that is present and running.
<!-- /fm-authority -->

`blind_capture_check` now counts consecutive capture failures per window in `state/.blind-<key>` and surfaces a `stale:` wake naming the pane unreadable once the count reaches `FM_BLIND_CAPTURE_POLLS` (default 3).
Three is the same "not a one-off" bar the progress gate applies, so a transient miss costs one or two captures and wakes nobody, while a sustained blindness is reported within two poll intervals.
The alarm fires once per unbroken blind run: the count survives the wake's exit and a watcher re-arm, so a blindness that cannot be fixed on the spot reports once instead of spinning the supervisor, and a successful capture deletes the count and re-arms the alarm.
<!-- fm-authority: captain-decision 2026-08-17 - the captain reviewed this exact edge case at the review gate and chose to accept it rather than add durable alarm state -->
That one-alarm guarantee assumes a fixed threshold for the blind run, as `BLIND_CAPTURE_POLLS` is read at watcher startup.
Changing `FM_BLIND_CAPTURE_POLLS` during blindness can suppress the alarm when lowered below the count or cause a second alarm when raised after one fired; a successful capture still re-arms it, and separate durable alarm state was declined as unnecessary machinery for a case unreachable in normal operation.
<!-- /fm-authority -->
It is a `stale:` reason keyed by the window rather than a new wake kind, because the handling it needs is the one `AGENTS.md` section 8 already prescribes for `stale:`.

`tests/fm-watch-triage.test.sh` covers both halves.
`test_blind_capture_surfaces_after_threshold` fails against the previous `|| continue`, where the watcher stays silent and alive.
`test_intermittent_capture_failure_stays_quiet` holds an unbounded fail/fail/succeed cycle silent, which is also what proves the count resets on a success.
Both are fixture-driven; no live-host run was taken for this change, so the sandbox denial recorded above remains the investigation's measurement rather than a fresh one.

## Limitations

The reference path is fully verified, with two probe-specific limitations:

- The agent-liveness probe cannot confidently classify `pi`'s generic `node` process name; see [Known gap: `pi` cannot be confidently classified](#known-gap-pi-cannot-be-confidently-classified).
- The transport probe cannot distinguish a denied socket from an absent server, and reports both as no route; see [Transport reachability](#transport-reachability).
