#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   sbx is EXPERIMENTAL and SECONDMATE-ONLY (never auto-detected): the
#   secondmate runs inside a clone-mode Docker Sandbox microVM and is
#   supervised through a bind-mounted signal directory (state/<id>.status and
#   state/<id>.turn-ended become host symlinks onto it); supported harnesses
#   are claude and codex, and ship/scout sbx spawns are refused
#   (docs/sbx-backend.md).
#   A claude sbx spawn fail-soft reconciles ~/.claude.json to firstmate's
#   intended workspace-trust shape (revoke the guest-wide grant sbx's own
#   claude-flavor create writes, grant the roots a guest launches under);
#   fm_backend_sbx_reconcile_claude_trust owns it and resurrection re-asserts
#   it, and the sbx guide owns the narrowness rationale and verification.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   Herdr additionally supports a default-off presentation-only layout when the
#   local config/herdr-presentation-spaces flag exists. A clean fresh task first
#   writes state/<id>.herdr-presentation atomically, then creates a disposable
#   workspace containing only the ordinary task pane. The journal and visible
#   random token are never endpoint or ownership authority. Existing, ambiguous,
#   or recovered state is never adopted, reused, closed, or deleted through that
#   presentation path; a flat launch is allowed only after duplicate-agent risk
#   is independently absent. Treehouse allocation and task metadata are unchanged.
#   A clean projected create makes one bounded attempt to hold the one
#   session-scoped presentation-order lock (keyed by named session plus
#   canonical socket, outside any home's state/) through launch handoff. Lock
#   contention warns and falls back to the ordinary flat layout before any
#   projection mutation. The exact response-derived new workspace is inserted
#   immediately after its owning parent (firstmate or 2ndmate-<id>) contiguous
#   child block. Ordering never authorizes lifecycle cleanup, and any
#   unavailable, ambiguous, or failed move warns while the spawn continues.
#   Every projected create, prune, and move captures and verifies the named
#   session's exact active workspace and tab. A detected focus change restores
#   only that exact tab id; an ambiguous pre-operation snapshot refuses the
#   focus-sensitive presentation mutation.
#   Every single-task invocation holds one task-id-scoped lock across backend
#   creation through metadata publication, so concurrent same-id spawns serialize
#   even when they select different backends.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Worktree acquisition and launch delivery (docs/spawn-launch-delivery.md owns
#   the incident and measurements behind both). A ship/scout worktree is leased
#   with `treehouse get --lease` in THIS process - never typed at the task pane's
#   shell prompt - and recorded as worktree_lease= so a respawn reuses that slot
#   instead of leaking it. The launch is then submitted as ONE command line
#   through the backend's own run-a-command primitive, and this script waits for
#   the pane to write a nonce into state/<id>.launched (the signal-bridge mount
#   for sbx) before it treats the task as started. An undelivered launch prints
#   the pane's last lines, restores the pre-spawn metadata, and exits non-zero.
#   Tunable, with defaults that only ever need raising on a very slow pane:
#     FM_SPAWN_LAUNCH_WAIT        seconds to wait for the nonce after each submit (20)
#     FM_SPAWN_LAUNCH_TRIES       submissions before giving up (3)
#     FM_SPAWN_LAUNCH_FLUSH_WAIT  seconds a retry gives its flushing Enter (3)
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
#   A ship/scout spawn also prints one `warning: branch-carried claude settings
#   drift` line when the task branch's committed .claude/settings.json differs
#   from the default branch's, naming which side carries the file when only one
#   does. It is DETECTION ONLY: the dispatch proceeds either way, no trust store
#   or launch flag is touched, and no line is printed when the two agree, when
#   the file is absent from both, or when no default branch resolves.
#   On Claude Code v2.1.220's host/tmux path, measured 2026-08-02, those settings
#   load without a prompt under the repo-root trust grant, which the fleet
#   accepts deliberately; docs/claude-settings-trust-posture.md owns that
#   posture and its evidence.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,84p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=orca does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=cmux does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = sbx ] && [ "$KIND" != secondmate ]; then
  # sbx is secondmate-only by design: crewmate/scout tasks live in treehouse
  # worktrees supervised through host panes, while an sbx task is a whole
  # microVM supervised through the signal bridge (docs/sbx-backend.md).
  echo "error: backend=sbx only supports --secondmate spawns" >&2
  exit 1
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
SPAWN_LEASE_PATH=
SPAWN_LEASE_RELEASE_ON_ABORT=0
SPAWN_WORKTREE_LEASE=
SPAWN_META_BACKUP=
CONFIG_INHERIT_LOCK=
CONFIG_INHERIT_LOCK_HELD=0
SPAWN_PR_URL=
SPAWN_PR_HEAD=

# The PR a task is watching belongs to the TASK, not to the worker process: a
# respawn keeps the same id, worktree, branch, and PR, and a genuinely finished
# task has its metadata deleted outright by bin/fm-teardown.sh, so a preserved
# identity cannot outlive its task. Both wholesale metadata writers below would
# otherwise truncate pr=/pr_head= away and silently disarm the merge poll -
# every artifact stays on disk and only the validation predicate disagrees.
#
# Only a record whose identity already parses is carried forward. A corrupt one
# (absent, duplicated, unparseable, or displaced by a later field) is left
# behind so the poll stays refused rather than being silently repaired here.
spawn_read_pr_identity() {  # <meta>
  local meta=$1 head
  SPAWN_PR_URL=
  SPAWN_PR_HEAD=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  fm_pr_metadata_identity_parse "$meta" || return 0
  SPAWN_PR_URL=$FM_PR_META_URL
  head=$(grep '^pr_head=' "$meta" | tail -1)
  [ -n "$head" ] || return 0
  head=${head#pr_head=}
  fm_pr_head_valid "$head" || return 0
  SPAWN_PR_HEAD=$head
}

# INVARIANT: pr= and pr_head= are the LAST lines of state/<id>.meta.
# bin/fm-pr-lib.sh's fm_pr_metadata_identity_parse rejects the whole record when
# any ordinary field follows pr=, so a field appended after this call disarms the
# merge poll of every watching task with no other symptom. Add new fields ABOVE
# the spawn_emit_pr_identity call, never after it.
spawn_emit_pr_identity() {
  [ -z "$SPAWN_PR_URL" ] || printf 'pr=%s\n' "$SPAWN_PR_URL"
  [ -z "$SPAWN_PR_HEAD" ] || printf 'pr_head=%s\n' "$SPAWN_PR_HEAD"
}

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

spawn_abort_cleanup() {
  local status=$?
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] \
     && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE" || true
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
        mkdir -p "$STATE" 2>/dev/null || true
        if [ -d "$STATE" ]; then
          {
            echo "window=$W"
            echo "worktree=${WT:-}"
            echo "project=$PROJ_ABS"
            echo "harness=$HARNESS"
            echo "kind=$KIND"
            echo "mode=${MODE:-no-mistakes}"
            echo "yolo=${YOLO:-off}"
            echo "tasktmp=${TASK_TMP:-}"
            echo "model=${MODEL:-default}"
            echo "effort=${EFFORT:-default}"
            echo "backend=orca"
            echo "orca_worktree_id=$ORCA_WORKTREE_ID"
            [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
            # Last, always: see spawn_emit_pr_identity's ordering invariant.
            spawn_emit_pr_identity
          } > "$STATE/$ID.meta" 2>/dev/null || true
        fi
      fi
    fi
  fi
  # Release a pool slot this run leased but never handed to a task. The flag is
  # cleared the moment the task's pane is created, so this only fires while the
  # slot is still meant to be empty.
  #
  # Deliberately NOT `--force`: forcing SIGKILLs whatever lives in the worktree
  # and resets it, and a spawn that failed late can still have left a dying pane
  # cwd'd there - measured on a live herdr projection, that kill disturbed the
  # captain's focused workspace. A plain return refuses instead, which costs a
  # held pool slot rather than a surprise.
  if [ "$SPAWN_LEASE_RELEASE_ON_ABORT" = 1 ]; then
    SPAWN_LEASE_RELEASE_ON_ABORT=0
    if [ -n "$SPAWN_LEASE_PATH" ]; then
      treehouse return "$SPAWN_LEASE_PATH" >/dev/null 2>&1 || true
    fi
  fi
  [ -z "$SPAWN_META_BACKUP" ] || rm -f "$SPAWN_META_BACKUP" 2>/dev/null || true
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$CONFIG_INHERIT_LOCK_HELD" = 1 ]; then
    CONFIG_INHERIT_LOCK_HELD=0
    fm_lock_release "$CONFIG_INHERIT_LOCK" || true
  fi
  return "$status"
}
trap spawn_abort_cleanup EXIT

# One bounded lock per live Herdr session/socket, shared across all homes.
# <session> is required so secondmate and primary spawns serialize against the
# same session without writing any other home's state directory.
spawn_herdr_presentation_order_lock_acquire() {
  local session=${1:-} attempt lock_path
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  HERDR_PRESENTATION_ORDER_LOCK="$lock_path"
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$HERDR_PRESENTATION_ORDER_LOCK"; then
      HERDR_PRESENTATION_ORDER_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

spawn_herdr_presentation_order_lock_release() {
  [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ] || return 0
  HERDR_PRESENTATION_ORDER_LOCK_HELD=0
  fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
}

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
# Read before either wholesale writer truncates the record. Both writers use the
# same captured value, and the Orca abort path fires only before the main write,
# so it never reads back a file this run already rewrote.
spawn_read_pr_identity "$STATE/$ID.meta"
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# replace_all <string> <from> <to>: literal replace of every occurrence.
# Exists because macOS's system bash 3.2 mis-parses ${var//"$from"/"$to"} when
# the QUOTED pattern contains a '/': the first slash is taken as the
# pattern/replacement delimiter even inside quotes, which scrambles the result
# (verified live - the guest brief's status path came out as
# 'x.status//mount/x.status/x.status'). '%%'/'#' expansions never treat '/'
# specially, so peel prefixes instead; correct under bash 3.2 and later alike.
replace_all() {
  local s=$1 from=$2 to=$3 out=
  case "$from" in '') printf '%s' "$s"; return 0 ;; esac
  while :; do
    case "$s" in
      *"$from"*)
        out="$out${s%%"$from"*}$to"
        s=${s#*"$from"}
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$out$s"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). It has no network or remote-origin-fetch dependency: a
  # worktree home already holds the commit, and a standalone clone gets it from
  # disk only when its resolved origin path matches the primary checkout
  # (fm-ff-lib.sh). ff-only and guarded; a dirty, diverged, or wrong-branch home is
  # left untouched and launches as-is. The agent re-reads AGENTS.md fresh on
  # launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  mkdir -p "$PROJ_ABS/state" || {
    echo "error: could not create secondmate state directory for $PROJ_ABS" >&2
    exit 1
  }
  CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
    echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
    exit 1
  fi
  CONFIG_INHERIT_LOCK_HELD=1
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into this secondmate home (fm-config-inherit-lib.sh).
  propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
    || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above,
# while the worktree the pool hands back is already physically resolved.
# Canonicalize once here so the isolation assertion compares the same physical
# form on both sides and cannot refuse a spawn that never actually tangled
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real proj_real wt_top wt_top_real
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# Report - never refuse - when the branch this spawn will work on carries a
# committed .claude/settings.json that differs from the default branch's.
#
# On Claude Code v2.1.220's host/tmux path, measured 2026-08-02, a linked
# worktree loaded branch-carried project settings, hooks included, under the
# PRIMARY checkout's repo-root trust grant with no per-worktree prompt
# (docs/claude-settings-trust-posture.md owns the measurement and the captain's
# decision to accept it). The fleet accepts that measured posture, so this
# exists to make the difference VISIBLE at the moment work is dispatched, not
# to stop the dispatch: the accepted risk is about who decided, and a
# supervisor can only weigh that if they are told.
#
# Two consequences of "detection, not a gate" are load-bearing. It never exits
# non-zero and is never called in a position that could abort the launch, and
# it stays quiet unless there is a real difference - an unresolvable default
# branch, a non-repository worktree, or no settings file on either side all
# print nothing. A line on every ordinary spawn would be tuned out inside a
# week, which would cost the detection its whole point.
#
# It reads git only; it touches no trust store and changes no launch flag.
report_settings_drift() {  # <worktree>
  local wt=$1 rel=.claude/settings.json
  local default base_rev rev head_blob base_blob change
  default=$(default_branch "$wt" 2>/dev/null) || return 0
  base_rev=
  for rev in "$default" "origin/$default"; do
    if git -C "$wt" rev-parse --quiet --verify "$rev^{commit}" >/dev/null 2>&1; then
      base_rev=$rev
      break
    fi
  done
  [ -n "$base_rev" ] || return 0
  head_blob=$(git -C "$wt" rev-parse --quiet --verify "HEAD:$rel" 2>/dev/null || true)
  base_blob=$(git -C "$wt" rev-parse --quiet --verify "$base_rev:$rel" 2>/dev/null || true)
  [ "$head_blob" = "$base_blob" ] && return 0
  # State the two trees, not a cause. A branch that merely trails the default
  # branch produces the same asymmetry as one that deleted the file, and this
  # line is read at dispatch by someone who has not looked at either yet.
  if [ -z "$base_blob" ]; then
    change="is present on this branch and absent on the base"
  elif [ -z "$head_blob" ]; then
    change="is absent on this branch and present on the base"
  else
    change="differs from the base"
  fi
  echo "warning: branch-carried claude settings drift for $ID: $rel $change (base $base_rev) in $wt; see the Claude Code v2.1.220 host/tmux measurement from 2026-08-02 in docs/claude-settings-trust-posture.md. Dispatch continues." >&2
  return 0
}

# A stale presentation journal never grants launch authority.
# When authoritative metadata already exists, require its endpoint to be
# positively dead before the journal's read-only token inspection may allow a
# flat fallback.
herdr_projection_existing_meta_allows_flat() {  # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    old_session=$FM_BACKEND_HERDR_SESSION
    old_pane=$FM_BACKEND_HERDR_PANE
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_herdr_pane_agent_state "$old_session" "$old_pane")
    case "$old_state" in
      dead|no-agent) return 0 ;;
      live|unknown)
        echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
        return 1
        ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
    dead) return 0 ;;
    alive|unknown)
      echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
}

# Worktree acquisition for a ship/scout task, made in THIS process rather than
# by typing a command at the task pane's shell prompt.
#
# A freshly created pane runs the captain's INTERACTIVE login shell, and
# anything that shell asks before a send lands eats the leading characters of
# it. Measured 2026-08-13 on the tmux reference backend: oh-my-zsh's auto-update
# prompt sat at "[oh-my-zsh] Would you like to update? [Y/n]" in every fresh
# window, ate the "t" of the `treehouse get` this script used to type, and the
# spawn died on the bounded worktree wait that followed - three times out of
# three, blocking every fleet member on the host until the prompt was answered
# by hand. No wait fixes that: an interactive prompt is perfectly stable on
# screen, so a settle-wait reads a calm pane and types straight into the
# question, and a clearing newline would answer an unknown question with its
# default.
#
# `treehouse get --lease` is the non-interactive acquire (the same durable lease
# bin/fm-home-seed.sh takes for a secondmate home): it prints the path on stdout,
# opens no subshell, and needs no pane at all. The pane is then created already
# inside the resolved worktree, so no shell prompt sits between firstmate and a
# correctly placed task.
#
# The lease is durable, so it must be acquired ONCE per task: a respawn reuses
# the slot its own metadata records rather than leaking it and taking another.
# Metadata and lease are created and destroyed together (bin/fm-teardown.sh
# returns the worktree and removes the record in one pass), so a record that
# still names a leased worktree still owns it. A record from before this script
# leased anything carries no worktree_lease= field and is never reused, because
# an unleased worktree can have been pruned or handed to another task since.
spawn_acquire_leased_worktree() {
  local prior_wt prior_lease
  prior_wt=
  prior_lease=
  if [ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
    prior_wt=$(grep '^worktree=' "$STATE/$ID.meta" | tail -1 | cut -d= -f2-)
    prior_lease=$(grep '^worktree_lease=' "$STATE/$ID.meta" | tail -1 | cut -d= -f2-)
  fi
  if [ "$prior_lease" = treehouse ] && [ -n "$prior_wt" ] && [ -d "$prior_wt" ]; then
    WT=$prior_wt
    SPAWN_WORKTREE_LEASE=treehouse
    return 0
  fi
  WT=$(cd "$PROJ_ABS" && treehouse get --lease --lease-holder "$ID") || {
    echo "error: treehouse get --lease could not acquire a worktree for $ID in $PROJ_ABS" >&2
    return 1
  }
  [ -n "$WT" ] || {
    echo "error: treehouse get --lease did not report a worktree for $ID" >&2
    return 1
  }
  SPAWN_LEASE_PATH=$WT
  SPAWN_LEASE_RELEASE_ON_ABORT=1
  SPAWN_WORKTREE_LEASE=treehouse
}

# The task's pane is created in the project, exactly as before, and the launch
# chain below cd's it into the worktree. Starting the pane in the worktree
# instead was tried and backed out: on a live herdr tab it intermittently came
# back with no shell in the pane at all (the pty echoed keystrokes and ran
# nothing), which the project-rooted pane never did. Placement is guaranteed by
# the chain's own `cd`, which the agent launch is && - chained behind.
SPAWN_CWD=$PROJ_ABS
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_acquire_leased_worktree || exit 1
  # The isolation assertion now runs BEFORE any pane exists, on the path the
  # pool actually handed over, so a tangled acquire can never reach a launch.
  validate_spawn_worktree "treehouse get --lease" "$WT"
fi

W="fm-$ID"
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once the
    # pane settles in the worktree. SEND_TARGET carries that stable id for every
    # spawn-time send below; the persisted window= handle stays $T (the name form),
    # which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$SPAWN_CWD") || exit 1
    SEND_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    HERDR_LABEL_HOME=$FM_HOME
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
    fi
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && [ -f "$CONFIG/herdr-presentation-spaces" ]; then
      if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
        if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
          herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
        fi
        HERDR_RECOVERY_SESSION=$(fm_backend_herdr_session)
        fm_backend_herdr_projection_recovery_allows_flat \
          "$HERDR_RECOVERY_SESSION" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
      elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
        HERDR_SES=$(fm_backend_herdr_session)
        HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label)
        # Session lock path resolution needs a live named-session socket.
        # Ensure the server before journal publication so lock failure degrades
        # to flat without ever creating an unlocked projection.
        if ! fm_backend_herdr_server_ensure "$HERDR_SES"; then
          echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
          HERDR_PROJECTION_ID=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
          HERDR_PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label "$ID" "$HERDR_PROJECTION_ID")
          if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
            "$SPAWN_CWD" "$HERDR_PROJECTION_LABEL" "$W"; then
            if [ "${FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE:-0}" = 1 ]; then
              HERDR_PROJECTION_ABORT_CLEANUP=1
              HERDR_PROJECTION_ABORT_SESSION=$FM_BACKEND_HERDR_PROJECTION_SESSION
              HERDR_PROJECTION_ABORT_TASK_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
              HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
            fi
            exit 1
          fi
          HERDR_PROJECTED=1
          HERDR_SES=$FM_BACKEND_HERDR_PROJECTION_SESSION
          HERDR_WORKSPACE_ID=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
          HERDR_SEEDED_DEFAULT_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
          HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
          HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
          HERDR_PROJECTION_ABORT_CLEANUP=1
          HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
          HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
          HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
          fm_backend_herdr_projection_order_best_effort \
            "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL"
        else
          echo "warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection" >&2
        fi
      fi
    fi
    if [ "$HERDR_PROJECTED" -ne 1 ]; then
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
      # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
      # (the second field empty when this call ADOPTED a pre-existing workspace
      # rather than creating a fresh one). Split on the guaranteed single tab
      # character; the seeded tab id is threaded through to create_task
      # untouched, which is the only function permitted to prune it (never
      # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
      CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
      HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
      HERDR_SES=${CONTAINER%%:*}
      HERDR_WORKSPACE_ID=${CONTAINER#*:}
      HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$SPAWN_CWD" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
      read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    fi
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$SPAWN_CWD") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$SPAWN_CWD") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  sbx)
    # One clone-mode microVM per secondmate (docs/sbx-backend.md; the sbx
    # backend is secondmate-only, enforced above). The signal-bridge mount is
    # created HERE, at provision, so `sbx create` can bind it read-write at
    # the same absolute path in the guest; state/<id>.status and
    # state/<id>.turn-ended become host-side symlinks onto it below, which is
    # what keeps fm-watch.sh's scan_signals byte-for-byte unchanged for sbx
    # secondmates. fm_backend_sbx_create_task refuses harnesses without a
    # verified sbx launch+resume shape (claude|codex) BEFORE creating
    # anything, so meta can only ever record an in-VM harness the liveness
    # sweep's verified list accepts.
    # The sandbox's AGENT FLAVOR is resolved here, first of everything: it
    # decides which credential wiring the guest receives, it is chosen
    # independently of the driver harness (FM_SBX_AGENT; bin/backends/sbx.sh),
    # and a flavor that cannot serve this driver must refuse before any
    # sandbox, signal directory, or guest state exists rather than produce a
    # guest that 401s on its first authenticated call. create_task re-resolves
    # the same pure function so a direct adapter caller is refused too; this
    # call additionally supplies the value meta records below.
    SBX_AGENT=$(fm_backend_sbx_agent_for_harness "$HARNESS") || exit 1
    # A projects-bearing home is refused before anything is created: its
    # projects/ sub-clones are independent gitignored repos that clone mode
    # structurally cannot carry into the VM, and a secondmate whose charter
    # references projects that silently don't exist in-guest would burn
    # turns discovering it. Loud refusal until an in-guest re-clone story
    # exists (agent-dotfiles docs/firstmate-sbx-guest-home-provisioning.md
    # §4.4/§8). Registry entries and physical clones are both checked, the
    # same two signals fm-home-seed.sh's --no-projects guard reads - and an
    # UNINSPECTABLE signal refuses too (fail-safe, matching that guard):
    # silently spawning a home whose project data cannot be ruled out is the
    # exact quiet degradation the refusal exists to prevent.
    if [ -f "$PROJ_ABS/data/projects.md" ] && [ ! -r "$PROJ_ABS/data/projects.md" ]; then
      echo "error: cannot inspect project registry at $PROJ_ABS/data/projects.md; resolve its access permissions before an sbx spawn (a projects-bearing home must be refused)" >&2
      exit 1
    fi
    if [ -L "$PROJ_ABS/projects" ]; then
      echo "error: cannot inspect projects directory at $PROJ_ABS/projects because it is a symlink; resolve the symlink before an sbx spawn (a projects-bearing home must be refused fail-safe)" >&2
      exit 1
    fi
    if [ -e "$PROJ_ABS/projects" ] && [ ! -d "$PROJ_ABS/projects" ]; then
      echo "error: cannot inspect projects directory at $PROJ_ABS/projects because it is not a directory; resolve its path before an sbx spawn (a projects-bearing home must be refused fail-safe)" >&2
      exit 1
    fi
    if [ -d "$PROJ_ABS/projects" ] && ! find -P "$PROJ_ABS/projects" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1; then
      echo "error: cannot inspect projects directory at $PROJ_ABS/projects; resolve its access permissions before an sbx spawn (a projects-bearing home must be refused)" >&2
      exit 1
    fi
    sbx_home_projects=
    if [ -f "$PROJ_ABS/data/projects.md" ]; then
      sbx_home_projects=$(awk '$1 == "-" && $2 != "" { print $2 }' "$PROJ_ABS/data/projects.md" | tr '\n' ' ')
    fi
    for sbx_proj in "$PROJ_ABS/projects"/* "$PROJ_ABS/projects"/.[!.]* "$PROJ_ABS/projects"/..?*; do
      [ -e "$sbx_proj" ] || [ -L "$sbx_proj" ] || continue
      case " $sbx_home_projects" in
        *" ${sbx_proj##*/} "*) ;;
        *) sbx_home_projects="$sbx_home_projects${sbx_proj##*/} " ;;
      esac
    done
    if [ -n "${sbx_home_projects% }" ]; then
      echo "error: secondmate home $PROJ_ABS carries projects (${sbx_home_projects% }); sbx clone mode cannot carry nested gitignored project clones into the VM - seed a --no-projects home for sbx, or use a host-pane backend (agent-dotfiles docs/firstmate-sbx-guest-home-provisioning.md §4.4)" >&2
      exit 1
    fi
    SIG_DIR="$FM_SBX_SIGNALS_ROOT/$ID"
    fm_backend_sbx_create_task "$W" "$PROJ_ABS" "$HARNESS" "$SIG_DIR" || exit 1
    T="sbx:$W"
    # Seed the tracked-file sync's staleness cache from the guest's OWN
    # rev-parse, never from the host clone's tip: what `sbx create --clone`
    # checked out is sbx's business, and recording an assumed value would
    # reproduce the exact silent-staleness failure the sync exists to close
    # (docs/sbx-backend.md "Tracked-file sync"). An unreadable or malformed
    # answer records nothing; the first sweep then verifies in-guest instead.
    SBX_GUEST_HEAD=$(sbx exec "$W" -- git -C "$PROJ_ABS" rev-parse HEAD 2>/dev/null | tr -d '[:space:]') || SBX_GUEST_HEAD=
    fm_backend_sbx_sha_valid "$SBX_GUEST_HEAD" || SBX_GUEST_HEAD=
    # The guest-side launch command lives in the adapter, next to its resume
    # variant, so resurrection can never drift from spawn (its codex template
    # carries the notify= turn-end hook that touches the mount's turn-ended
    # AND beat files). A raw launch command (unverified-adapter escape hatch)
    # still runs verbatim in the guest pane.
    case "$ARG3" in
      *' '*) : ;;
      *)
        LAUNCH=$(fm_backend_sbx_launch_template "$HARNESS") || {
          echo "error: no sbx launch template for harness '$HARNESS'" >&2
          exit 1
        }
        ;;
    esac
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
# #134 robustness: only tmux needs a send target distinct from $T - its
# rename-safe stable window id, set as SEND_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# SEND_TARGET to $T for them (and for any future backend) - the shared launch
# delivery below must never reference an unbound SEND_TARGET under set -u.
: "${SEND_TARGET:=$T}"
# A pane now lives in the leased worktree, so the abort path must never force it
# back to the pool: `treehouse return --force` kills what is inside a worktree
# and resets it. From here on a failed spawn leaves the slot held for this task
# and says so, instead of destroying whatever the pane is holding.
SPAWN_LEASE_RELEASE_ON_ABORT=0
# spawn_send_command_line: hand <line> to the backend's own "run this command
# line" primitive, which is how the launch is delivered.
#
# This is deliberately NOT "type the text, then press Enter". Herdr's `pane run`
# executes a command line through herdr itself, and a freshly created herdr tab
# can hand back a pane that has no shell in it yet: measured live on herdr 0.7.5,
# a pane in that state ECHOES typed characters and executes nothing, so a
# type-then-Enter launch left the command sitting on screen three times over
# while the task looked spawned. `pane run` needs no shell to already be there.
# Where a backend has no such API (tmux and the adapters that mirror it), this
# is still one call that submits the line, never a separate keystroke pair.
spawn_send_command_line() {  # <target> <line>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
    sbx)
      # sbx keeps its own verified spawn shape: its send_text_line carries the
      # pending-delivery bookkeeping that belongs to STEERING, not to a launch.
      fm_backend_sbx_send_literal "$1" "$2" || return 1
      sleep 0.3
      fm_backend_sbx_submit_composed "$1"
      ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
    zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_key "$1" "$2" ;;
    cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
    sbx)
      [ "$2" = Enter ] || return 1
      fm_backend_sbx_submit_composed "$1"
      ;;
  esac
}
# Both crewmate worktree paths (orca's create above, the pool lease taken before
# the pane existed) have resolved and validated $WT by now, so one call covers
# both. A secondmate's
# $WT is its own firstmate home rather than a project branch, which is not what
# this reports on. Detection only - see report_settings_drift; the launch below
# is unaffected either way.
if [ "$KIND" != secondmate ]; then
  report_settings_drift "$WT" || true
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
FM_SBX_BEAT_PATH=""
if [ "$BACKEND" = sbx ]; then
  # The guest's turn-end hook must write onto the signal-bridge mount, not
  # the primary's state dir (unreachable from inside the VM). The host-side
  # state/<id>.turn-ended becomes a symlink onto this same mount file below,
  # so the watcher's scan still reads its usual state/ paths.
  TURNEND="$SIG_DIR/$ID.turn-ended"
  FM_SBX_BEAT_PATH="$SIG_DIR/$ID.beat"
fi
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
# Keep the pre-spawn record so an undeliverable launch can put it back rather
# than leaving a record that reads as a started task (spawn_launch_failed).
if [ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
  SPAWN_META_BACKUP="$STATE/.$ID.meta.prespawn"
  cp "$STATE/$ID.meta" "$SPAWN_META_BACKUP" 2>/dev/null || SPAWN_META_BACKUP=
fi
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  # Present only for a worktree THIS script durably leased from the pool. Its
  # absence is what stops a respawn from adopting a worktree that predates the
  # lease and can since have been pruned or handed to another task.
  [ -z "$SPAWN_WORKTREE_LEASE" ] || echo "worktree_lease=$SPAWN_WORKTREE_LEASE"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$BACKEND" = sbx ]; then
    echo "sbx_signals_dir=$SIG_DIR"
    # The RESOLVED agent flavor, always recorded: it is the only durable
    # record of which credential wiring a live guest actually has, and
    # recording it only when pinned would force every reader to re-derive the
    # default map. It is placement state in the strongest sense - changing a
    # sandbox's flavor means destroying and recreating the VM - so the
    # liveness sweep's respawn re-enters it from here.
    echo "sbx_agent=$SBX_AGENT"
    # The template pin is placement state, like the backend itself: the
    # liveness sweep's respawn must reproduce the sandbox from the meta
    # alone (a session-start sweep has no FM_SBX_TEMPLATE in its env).
    [ -z "${FM_SBX_TEMPLATE:-}" ] || echo "sbx_template=$FM_SBX_TEMPLATE"
    [ -z "${SBX_GUEST_HEAD:-}" ] || echo "sbx_guest_synced=$SBX_GUEST_HEAD"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
  # LAST LINES OF THE RECORD - nothing may be emitted below this call.
  # spawn_emit_pr_identity owns why: any ordinary field after pr= invalidates the
  # whole record for bin/fm-pr-lib.sh and silently disarms this task's merge poll.
  spawn_emit_pr_identity
} > "$STATE/$ID.meta"
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

if [ "$BACKEND" = sbx ]; then
  # Host-side signal wiring: state/<id>.status and state/<id>.turn-ended
  # become symlinks onto the signal-bridge mount, so scan_signals, triage,
  # grace coalescing, and the wake queue run genuinely unchanged - the
  # symlink set is also the id allowlist (only names the host chose to link
  # are scan-visible; a guest inventing another id's file changes nothing).
  # A pre-existing REGULAR signal file (e.g. a host secondmate migrating to
  # sbx) is folded into the mount file first so its history survives.
  for sig in status turn-ended; do
    host_sig="$STATE_REAL/$ID.$sig"
    mount_sig="$SIG_DIR/$ID.$sig"
    if [ -e "$host_sig" ] && [ ! -L "$host_sig" ]; then
      cat "$host_sig" >> "$mount_sig" 2>/dev/null || true
    fi
    rm -f "$host_sig"
    ln -s "$mount_sig" "$host_sig"
  done
  # Guest-side private surface: clone mode carries only COMMITTED files, so
  # the brief (and claude's hook file) must be seeded into the guest
  # explicitly. The brief copy lands at the SAME absolute path the launch's
  # `$(cat __BRIEF__)` names, with the primary's status-file path rewritten
  # to the mount file - the host symlink above makes both names converge on
  # the same file, so the charter's status protocol works verbatim from
  # inside the VM.
  sbx_brief_content=$(cat "$BRIEF")
  # replace_all, not ${var//...}: the pattern contains slashes, which macOS's
  # bash 3.2 mis-parses inside a quoted patsub pattern (see the helper).
  sbx_brief_content=$(replace_all "$sbx_brief_content" "$STATE/$ID.status" "$SIG_DIR/$ID.status")
  sbx_brief_content=$(replace_all "$sbx_brief_content" "$STATE_REAL/$ID.status" "$SIG_DIR/$ID.status")
  printf '%s\n' "$sbx_brief_content" | fm_backend_sbx_guest_write "$W" "$BRIEF" || {
    echo "error: failed to seed the brief into sandbox $W" >&2
    exit 1
  }
  # The GOTMPDIR export below lands in the guest pane; create its target
  # inside the VM (the host-side mkdir above cannot reach the guest's /tmp).
  sbx exec "$W" -- mkdir -p "$TASK_TMP/gotmp" || true
  # Guest-home provisioning: one idempotent exec, shared with resurrection's
  # re-assert (bin/backends/sbx.sh). It rebuilds the inherited read path and
  # markers owned by docs/sbx-backend.md "Guest-home provisioning", and also
  # plants the shell-profile env snippet owned by "Guest shell-profile env".
  fm_backend_sbx_provision_guest_home "$W" "$PROJ_ABS" "$ID" "$SIG_DIR" || {
    echo "error: failed to provision the guest home's private surface in sandbox $W" >&2
    exit 1
  }
  # claude workspace trust, paired with the pass above and shared with
  # resurrection's re-assert (bin/backends/sbx.sh). Harness-gated inside, and
  # fail-soft: a guest that cannot be reconciled still launches. It runs HERE
  # rather than in the claude* branch below so spawn and resurrection reconcile
  # through one call shape.
  fm_backend_sbx_reconcile_claude_trust "$W" "$PROJ_ABS" "$HARNESS"
  case "$HARNESS" in
    claude*)
      # claude's turn-end signal cannot ride the launch command; write its
      # Stop hook into the guest clone, touching the mount's turn-ended AND
      # beat files (design §6.1: the beat is the same touch). Kept out of
      # the clone's git view so the secondmate's own home never reads dirty.
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch %s %s"}]}]}}\n' \
        "'$TURNEND'" "'$FM_SBX_BEAT_PATH'" \
        | fm_backend_sbx_guest_write "$W" "$PROJ_ABS/.claude/settings.local.json" || {
        echo "error: failed to install the claude turn-end hook in sandbox $W" >&2
        exit 1
      }
      # shellcheck disable=SC2016  # single quotes deliberate: $1 expands in the guest sh, not here
      sbx exec "$W" -- sh -c 'printf "%s\n" ".claude/settings.local.json" >> "$1/.git/info/exclude"' _ "$PROJ_ABS" || true
      ;;
    codex*)
      # codex's directory-trust TUI gate blocks a non-interactive first
      # launch in a fresh clone-mode home (verified live, codex 0.142.5: the
      # dialog parks the pane before the brief is read, and
      # --dangerously-bypass-approvals-and-sandbox does NOT cover it). Seed
      # the guest config's project-trust entry for the home before launch;
      # the [projects."<path>"] shape is what codex itself persists on
      # accept. Idempotent for respawns over a kept sandbox. Hook trust is
      # deliberately NOT seeded here - its trusted_hash scheme is
      # codex-internal - so the launch and resume templates carry
      # --dangerously-bypass-hook-trust instead (bin/backends/sbx.sh).
      # shellcheck disable=SC2016  # single quotes deliberate: $1/$HOME expand in the guest sh, not here
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$PROJ_ABS" \
        | sbx exec -i "$W" -- sh -c 'mkdir -p "$HOME/.codex" && { grep -qsF "[projects.\"$1\"]" "$HOME/.codex/config.toml" || cat >> "$HOME/.codex/config.toml"; }' _ "$PROJ_ABS" || {
        echo "error: failed to seed codex project trust in sandbox $W" >&2
        exit 1
      }
      ;;
  esac
fi

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_beat=$(shell_quote "${FM_SBX_BEAT_PATH:-}")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__BEAT__/$sq_beat}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Launch delivery, verified before this spawn is allowed to claim a started task.
#
# The pane's shell is the captain's own interactive login shell, and this script
# cannot make it stop asking things. What it CAN do is refuse to believe a send
# landed until the shell proves it ran the exact bytes that were typed. The line
# below is one `&&` chain whose first two commands claim a sentinel file
# firstmate can read:
#
#   test ! -s <sentinel> && printf %s <nonce> > <sentinel>
#     && ( cd <worktree> && export GOTMPDIR=... && <launch> )
#
# It is built to survive two different things a pane can do to it.
#
# MANGLED: a prompt swallows the leading characters (the measured oh-my-zsh case
# ate exactly one). The shell is left with a mangled first word, which exits
# non-zero and short-circuits the whole chain - no nonce, no cd, no export, and
# above all no agent. Firstmate sees no nonce and knows nothing ran.
#
# REPEATED: a pane whose shell has not started yet buffers keystrokes in the tty
# and runs them all at once when it wakes, so a retyped line can arrive twice.
# The leading `test ! -s` makes the chain idempotent - the second copy finds the
# sentinel already claimed and stops before the launch. One agent, always.
# (`-s`, not `-e`: a mangled copy's redirection can still create the file empty.)
#
# The cd and the launch are wrapped in a SUBSHELL so the pane's own shell never
# moves into the worktree. bin/fm-teardown.sh returns that worktree to the pool
# before it closes the pane, and the return kills everything living inside it -
# with the pane's shell cd'd there, teardown killed the pane out from under the
# backend, which then could not close it cleanly (measured on a live herdr
# projection: the dying pane took the captain's focus with it). Only the agent
# and its children live in the worktree, exactly as they did when treehouse's own
# subshell held it. GOTMPDIR is exported inside that subshell, so it still
# reaches the agent and every child process (go build, go test, ...).
LAUNCH_SENTINEL="$STATE_REAL/$ID.launched"
[ "$BACKEND" != sbx ] || LAUNCH_SENTINEL="$SIG_DIR/$ID.launched"
LAUNCH_NONCE=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ -n "$LAUNCH_NONCE" ] || LAUNCH_NONCE="fm-$ID-$$-${RANDOM:-0}"
LAUNCH_LINE="test ! -s $(shell_quote "$LAUNCH_SENTINEL")"
LAUNCH_LINE="$LAUNCH_LINE && printf %s $(shell_quote "$LAUNCH_NONCE") > $(shell_quote "$LAUNCH_SENTINEL")"
LAUNCH_LINE="$LAUNCH_LINE && ( cd $(shell_quote "$WT")"
LAUNCH_LINE="$LAUNCH_LINE && export GOTMPDIR=$(shell_quote "$TASK_TMP/gotmp")"
LAUNCH_LINE="$LAUNCH_LINE && $LAUNCH )"

# Seconds to wait for the nonce after each submission, and how many submissions
# to make. The wait only has to cover a `printf` in a live shell, so it is
# generous by a wide margin; the retries cover a pane that needs more than one.
FM_SPAWN_LAUNCH_WAIT=${FM_SPAWN_LAUNCH_WAIT:-20}
FM_SPAWN_LAUNCH_TRIES=${FM_SPAWN_LAUNCH_TRIES:-3}
# Seconds to give a retry's flushing Enter before concluding it submitted nothing.
FM_SPAWN_LAUNCH_FLUSH_WAIT=${FM_SPAWN_LAUNCH_FLUSH_WAIT:-3}

spawn_launch_delivered() {
  local seen
  [ -f "$LAUNCH_SENTINEL" ] || return 1
  seen=$(cat "$LAUNCH_SENTINEL" 2>/dev/null) || return 1
  [ "$seen" = "$LAUNCH_NONCE" ]
}

# 0 delivered, 1 the backend refused the send outright, 2 the pane never ran it.
spawn_deliver_launch() {
  local attempt=0 waited state
  # Cleared ONCE, never between attempts: the chain's own idempotence guard reads
  # this file, so clearing it per attempt would re-arm a buffered duplicate.
  rm -f "$LAUNCH_SENTINEL" 2>/dev/null || true
  while [ "$attempt" -lt "$FM_SPAWN_LAUNCH_TRIES" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1 ]; then
      # Flush the pane's input line before retyping. A lost or half-delivered
      # send can leave a fragment sitting there, and typing the line again on top
      # of it produces one concatenated command that no check could ever confirm.
      # This Enter is not the rejected "clear an unknown prompt with a newline"
      # move: it lands only AFTER a full command line and an Enter of our own
      # have already gone into that shell, so it answers nothing our own first
      # attempt did not already reach.
      spawn_send_key "$SEND_TARGET" Enter || return 1
      # The flush can itself be the delivery: if the previous attempt's text was
      # complete and only its Enter went missing, that line just ran. Re-check
      # before retyping, or the retype starts a SECOND agent - the no-double-text
      # rule bin/fm-tmux-lib.sh already follows for steering.
      waited=0
      while [ "$waited" -lt "$FM_SPAWN_LAUNCH_FLUSH_WAIT" ]; do
        spawn_launch_delivered && return 0
        sleep 1
        waited=$((waited + 1))
      done
      spawn_launch_delivered && return 0
    fi
    spawn_send_command_line "$SEND_TARGET" "$LAUNCH_LINE" || return 1
    waited=0
    while :; do
      spawn_launch_delivered && return 0
      [ "$waited" -lt "$FM_SPAWN_LAUNCH_WAIT" ] || break
      sleep 1
      waited=$((waited + 1))
    done
    # No nonce, so the chain died on its first word. Before retyping, take the
    # one reading that could contradict that: a backend able to name the pane's
    # foreground process must not show a live agent. Backends that answer
    # "unknown" (no probe, or an agent behind a generic interpreter) leave the
    # chain's own guarantee as the only evidence, which is what it was built for.
    state=$(fm_backend_agent_alive "$BACKEND" "$SEND_TARGET")
    if [ "$state" = alive ]; then
      echo "error: $ID launch is unverifiable: no launch confirmation from the pane, but an agent is already running in it; refusing to retype and risk a second agent" >&2
      return 2
    fi
  done
  return 2
}

# The two causes seen live are named without picking one, because the pane's own
# last lines below tell them apart: a shell sitting at an unanswered startup
# question eats the leading characters, while a pane with nothing reading its
# input echoes the whole line and runs none of it
# (docs/spawn-launch-delivery.md).
spawn_launch_failed() {  # <exit-status-to-use>
  local tail_text
  echo "error: $ID launch command was not delivered to its pane after $FM_SPAWN_LAUNCH_TRIES attempts; $META_WINDOW either has a shell consuming typed input (an unanswered startup question does this) or nothing reading its input at all. Nothing was launched and the task is NOT recorded as started. Inspect that window and spawn again. Worktree $WT is still held for $ID" >&2
  # Show what the pane is actually displaying. Whatever swallowed the command is
  # almost always still on screen, and quoting it here saves the operator from
  # having to reach a pane that may be on another machine entirely.
  tail_text=$(fm_backend_capture "$BACKEND" "$SEND_TARGET" 30 2>/dev/null | tail -20) || tail_text=
  if [ -n "$tail_text" ]; then
    echo "--- last lines of $META_WINDOW ---" >&2
    printf '%s\n' "$tail_text" >&2
    echo "--- end ---" >&2
  fi
  if [ -n "$SPAWN_META_BACKUP" ] && [ -f "$SPAWN_META_BACKUP" ]; then
    mv -f "$SPAWN_META_BACKUP" "$STATE/$ID.meta" 2>/dev/null || rm -f "$STATE/$ID.meta"
  else
    rm -f "$STATE/$ID.meta"
  fi
  exit "$1"
}

spawn_deliver_launch || {
  spawn_deliver_status=$?
  if [ "$spawn_deliver_status" -eq 1 ]; then
    echo "error: $ID launch could not be sent to $META_WINDOW at all; the runtime refused the send. The task is NOT recorded as started, and worktree $WT is still held for $ID" >&2
    if [ -n "$SPAWN_META_BACKUP" ] && [ -f "$SPAWN_META_BACKUP" ]; then
      mv -f "$SPAWN_META_BACKUP" "$STATE/$ID.meta" 2>/dev/null || rm -f "$STATE/$ID.meta"
    else
      rm -f "$STATE/$ID.meta"
    fi
    exit 1
  fi
  spawn_launch_failed 1
}
# The projection's ordering lock is held across the WHOLE launch handoff, which
# is not over until the launch is confirmed: releasing at the send would let a
# concurrent projected spawn interleave its own create and cleanup with this
# one's. A handoff that never confirms leaves both the lock and the
# abort-cleanup claim with spawn_abort_cleanup, which owns tearing the
# projection down under that same lock.
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
rm -f "$SPAWN_META_BACKUP" 2>/dev/null || true
if [ "$KIND" = secondmate ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT"
