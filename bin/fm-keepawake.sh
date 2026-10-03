#!/usr/bin/env bash
# fm-keepawake.sh - run one command under a declared job lease, so a sandbox
# keep-alive can see a job that outlives the worker's own turn.
#
# Usage:
#   fm-keepawake.sh -- <cmd> [args...]
#
# Runs <cmd> in the foreground (stdin, signals, and output pass through
# unchanged) and returns its exit status. While it runs, a background refresher
# touches state/<task-id>.active in the active home every FM_KEEPAWAKE_INTERVAL
# seconds (default 30). When the command exits, the refresher stops; the lease
# file is left in place and simply goes stale, so two wrapped jobs of one task
# never cut each other's lease short.
#
# Resolution, the same as the other worker-side scripts:
#   home     $FM_HOME, else $FM_ROOT_OVERRIDE, else this code root; the state
#            directory is $FM_STATE_OVERRIDE, else <home>/state.
#   task id  the one state/<id>.meta whose worktree= is the git top level of
#            the current directory (the worker's own task worktree).
# The command is never run when either cannot be resolved: the script prints
# the reason and exits 2, so a job is never started believing it is covered.
#
# WHY. Docker Sandboxes stop a VM about 35 s after its last host connection.
# bin/backends/sbx.sh's keep-alive holds that connection only while its arms see
# work, and a job a worker backgrounded (`&`, nohup, a harness background task)
# moves no pane, writes no status, and is not a gate run - so on 2026-10-02 five
# keepers released on top of a running, paid eval and the VM stopped under it.
# Keep-alive arm2 reads state/*.active within FM_SBX_GUEST_ACTIVE_WINDOW (120 s),
# so a lease refreshed every 30 s pins the VM exactly while the job runs, and
# releases within one window after it ends (docs/sbx-backend.md "Job lease").
#
# The refresher is tied to this wrapper's own pid: if the
# wrapper is killed outright, the lease stops within one interval rather than
# pinning the VM until the keep-alive cap.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --) shift ;;
  *) echo "error: usage: fm-keepawake.sh -- <cmd> [args...]" >&2; exit 2 ;;
esac
[ $# -gt 0 ] || { echo "error: no command given after --" >&2; exit 2; }

interval=${FM_KEEPAWAKE_INTERVAL:-30}
case "$interval" in
  ''|*[!0-9]*|0) echo "error: FM_KEEPAWAKE_INTERVAL must be a positive integer (got '$interval')" >&2; exit 2 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: no state directory at $STATE; set FM_HOME to the firstmate home that spawned this task" >&2; exit 2; }

top=$(git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: not inside a git worktree; run this from the task's own worktree" >&2; exit 2; }
top=$(cd "$top" && pwd -P)

id=
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  wt=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  [ "$(cd "$wt" && pwd -P)" = "$top" ] || continue
  if [ -n "$id" ]; then
    echo "error: more than one task in $STATE records worktree $top; cannot tell which lease to hold" >&2
    exit 2
  fi
  id=$(basename "$meta" .meta)
done
[ -n "$id" ] || { echo "error: no task in $STATE records worktree $top; run this from the task's own worktree, with FM_HOME set to the home that spawned it" >&2; exit 2; }

lease="$STATE/$id.active"
touch "$lease" || { echo "error: cannot write the job lease $lease" >&2; exit 2; }

owner=$$
(
  while sleep "$interval" && kill -0 "$owner" 2>/dev/null; do
    touch "$lease" 2>/dev/null || true
  done
) </dev/null >/dev/null 2>&1 &

exec -- "$@"
