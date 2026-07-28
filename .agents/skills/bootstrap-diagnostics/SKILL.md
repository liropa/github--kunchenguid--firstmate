---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, CREW_DISPATCH invalid, FLEET_SYNC, PR_CHECK_MIGRATION, STATE_KEY_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, NUDGE_SECONDMATES, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`docs/configuration.md` "Backlog backend" owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because crew-dispatch `quota-balanced` may call it; `bin/fm-dispatch-select.sh` still degrades at runtime when quota data is unavailable.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the malformed schema, unverified harness name, unknown selector, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `STATE_KEY_MIGRATION: state/<file> could name more than one live task (<ids>); left untouched until those names no longer collide` - a per-task marker file written under the superseded key fold cannot be attributed to one task, because the listed ids all folded to the same name.
  The sweep never guesses, so that marker is now invisible to the watcher and behaves as absent: the affected secondmate's delivery breadcrumb stays quiet until the next steer republishes it, and its counters rebuild.
  No repair is needed for the beacons themselves; the line clears once the colliding ids no longer coexist in this home, so retire or rename one of them when convenient rather than hand-renaming state files.
- `STATE_KEY_MIGRATION: state/<file> could be current for <id> or legacy for <id>; moved aside as state/<preserved-file>` - a filename crossed the old and new schemes, so the sweep preserved it under the inert destination it names rather than attributing it to either task.
  Inspect the preserved destination when investigating its contents; no consumer reads it.
- `STATE_KEY_MIGRATION: watcher exclusion could not be acquired; marker migration did not run` - supervision is already active or its lock is uncertain, so bootstrap left every marker untouched.
  Let the current watcher finish or stop it through the normal supervision protocol, then rerun session start.
- A `STATE_KEY_MIGRATION:` line saying watcher blocking could not be established, a cross-scheme marker could not be moved aside, the block could not be cleared, or migration completion was invalid or could not be published leaves supervision disabled for that home.
  Inspect the named state path and rerun session start after repairing it; `bin/fm-watch.sh` refuses to read per-task markers until valid completion is present and the block is absent.
- Any other marker-specific `STATE_KEY_MIGRATION:` line names a marker the sweep left in place because its target name already existed or the rename failed.
  Inspect the named path before touching it; the same absent-not-wrong behavior applies, so nothing is at risk while it stands.
  `bin/fm-state-key-lib.sh`'s `fm_state_key_decode` reads a current-scheme name back to its owner when you need to tell the two files apart.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - the local-HEAD secondmate sync left a live secondmate home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing the primary target commit, or otherwise not fast-forwardable, or because inherited local-material propagation could not run; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_SYNC: secondmate <id> guest: skipped: <reason>` - the same honesty for an sbx-backed secondmate's in-VM clone, which no host-home fast-forward reaches (`docs/sbx-backend.md` "Tracked-file sync" owns the mechanism): a running-VM skip clears itself at the guest's next restart, while a dirty or diverged guest deserves the same inspection as a host home with that reason; a completed guest sync is the no-action `BOOTSTRAP_INFO: secondmate <id> guest: updated <a>..<b>` fact.
  If the reason says the home is not writable from this session, the home could not create its inheritance lock artifacts at all; retrying bootstrap from the same sandbox will not help until that filesystem access is fixed.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed: <reason>` - the session-start liveness sweep could not guarantee that a live secondmate's recorded endpoint is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - the secondmate sweep fast-forwarded a running secondmate home and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
