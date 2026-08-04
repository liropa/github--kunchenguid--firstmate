# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and the home watcher lock is not verified healthy.
Identity matching works without process inspection: publication holds an identity flock that a sandboxed session (which cannot exec setuid ps) can probe, and a lock that predates the flock degrades to a distinct unverifiable-identity refusal rather than a false absence claim; `bin/fm-wake-lib.sh` owns the contract.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Inter-cycle supervision gaps

The one-shot design above has a direct operational consequence worth stating plainly, because the alarm it eventually produces reads as a fault and frequently is not one.
Supervision is a chain of cycles joined only by the next arm, so every interval between one cycle's exit and the next arm starting is unsupervised by construction rather than by failure.
The normal interval is 10 to 40 seconds, comfortably inside the 300-second grace, and `bin/fm-guard.sh` stays deliberately silent for it.

What stretches that interval into a lapse is anything that suspends the operator's turn.
The arm is a harness-tracked background task precisely so its exit notifies the model, which means the decision to re-arm can only be taken while a turn is running.
A turn held at a permission prompt, or otherwise suspended mid-tool-call, suspends supervision for exactly as long as it lasts.
The measured instance was a permission prompt that held one turn for 19m51s.

The second consequence is easy to miss: the suspended command may itself be a steer.
A lapse then postpones real work as well as monitoring, because the crewmate instruction waits exactly as long as the supervision does.

Nothing reports the gap while it is open, and that is structural rather than a defect in either guard.
`bin/fm-guard.sh` is pull-based and warns only when some other fleet-touching command runs.
`bin/fm-turnend-guard.sh` is push-based but fires only at turn end.
A turn stalled mid-tool-call reaches neither boundary, because no further command runs and the turn never ends.
The `WATCHER DOWN - SUPERVISION IS OFF` banner therefore surfaces after the fact, carrying a beacon age that already encodes the whole elapsed gap.

`state/.watch-cycle-exits.log` is the decisive evidence store for diagnosing any of this, and the first thing to read.
Its per-cycle records distinguish a designed wake exit from a terminated one, and carry the start and end timestamps that make the gap between consecutive cycles directly computable.

Measured bounds come from a 570-cycle ledger in one home, reported in that home's investigation record `data/watcher-midflight-lapse-cause/report.md` (2026-08-04, home-local and not tracked in this repo).
74 of 569 gaps exceeded the grace window, or 13.0%, with a median lapse of 680 seconds.
That ledger contained zero kill signatures, so no lapse in it was a killed watcher.
The same ledger separately records arm terminations by `SIGTERM` at session end or interrupt, which that report treats as a real but distinct second mechanism rather than the cause of the lapses it examined.
Those figures predate the in-cycle beacon refresh now bounded by `FM_BEACON_MAX_AGE` (`docs/configuration.md`), which changed how much grace a live watcher consumes inside a cycle but not the inter-cycle gap measured here.

The durable wake queue holds across a lapse.
No observed lapse lost a signal, and a wake enqueued as the cycle exited drained intact once supervision resumed.
The cost is delayed reaction, not lost work.

Accepting this exposure is a legitimate posture, and the bounds above are what make it assessable rather than a guess.
Decoupling the arm from the operator's turn is the real fix, and it costs the notification-on-exit property the current design is built on, so it needs its own design pass rather than an incremental patch.
Each home weighs that trade against its own tolerance for delayed reaction; nothing here settles it.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
