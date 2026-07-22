#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes one bare PID line for the harness (agent) process found by walking the
# shell's ancestry, which lives as long as the firstmate session - unlike the
# transient subshell PID of any one tool call, which is dead moments after it is
# written.
# When the walk cannot run (a sandboxed session may be unable to exec ps at
# all: stock macOS /bin/ps is setuid root, and sandboxes refuse to exec setuid
# images), a launcher-provided harness PID from the trusted session
# environment - FM_HARNESS_PID first, then CLAUDE_PID - is used instead,
# validated as a live process and, whenever ps does work, as a harness.
# Usage: fm-lock.sh           acquire
#          exit 1: another live firstmate session holds the lock
#          exit 2: cannot identify this session's own harness process
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

ps_runs() {  # false when this environment cannot exec ps (sandboxed session)
  ps -o pid= -p "$$" >/dev/null 2>&1
}

pid_exists() {  # kill -0: EPERM still proves existence; only ESRCH proves death
  local pid=${1:-} err
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] || return 1
  err=$(kill -0 "$pid" 2>&1) && return 0
  case $err in
    *[Nn]o\ such\ process*) return 1 ;;
  esac
  return 0
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  # The walk found no harness (ps unusable, or none within the hop budget):
  # fall back to a launcher-provided harness PID from the session environment.
  for pid in "${FM_HARNESS_PID:-}" "${CLAUDE_PID:-}"; do
    case $pid in ''|*[!0-9]*) continue ;; esac
    pid_exists "$pid" || continue
    if ps_runs; then
      comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
      printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE" || continue
    fi
    echo "$pid"; return 0
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1
  pid_exists "$pid" || return 1
  # Without ps the holder's identity cannot be inspected; the pid provably
  # exists, so never steal the lock - report the holder live.
  ps_runs || return 0
  printf '%s' "$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || {
  echo "error: cannot identify this session's harness process (ancestry walk found none, and no FM_HARNESS_PID/CLAUDE_PID names a live harness)" >&2
  exit 2
}
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
