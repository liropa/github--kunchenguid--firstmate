#!/usr/bin/env bash
# Contract tests for bin/fm-keepawake.sh - the job lease a worker wraps a
# long background command in, so the sbx keep-alive's arm2 can see it
# (docs/sbx-backend.md "Job lease").
#
# The properties that matter: the lease is fresh exactly while the command
# runs, the command's exit status passes through, and an unresolvable home or
# task refuses before the command starts.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEPAWAKE="$ROOT/bin/fm-keepawake.sh"
TMP_ROOT=$(fm_test_tmproot fm-keepawake)

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

make_task() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  fm_git_init_commit "$dir/wt" >/dev/null
  fm_write_meta "$dir/home/state/w1.meta" kind=ship "worktree=$dir/wt"
  printf '%s\n' "$dir"
}

test_lease_is_held_while_the_command_runs_and_status_passes_through() {
  local dir rc=0 seen
  dir=$(make_task runs)
  # shellcheck disable=SC2016  # single quotes deliberate: $1/$2 expand in the wrapped sh, not here
  (cd "$dir/wt" && FM_HOME="$dir/home" "$KEEPAWAKE" -- \
    sh -c 'test -e "$1" && : > "$2"; exit 7' _ "$dir/home/state/w1.active" "$dir/seen") || rc=$?
  [ "$rc" = 7 ] || fail "the command's exit status should pass through, got $rc"
  seen=no
  [ -e "$dir/seen" ] && seen=yes
  [ "$seen" = yes ] || fail "the lease state/w1.active should exist before the command starts"
  pass "keepawake: the lease is held while the command runs, and its exit status passes through"
}

test_lease_is_refreshed_until_the_command_exits() {
  local dir lease pid
  dir=$(make_task refresh)
  lease="$dir/home/state/w1.active"
  (cd "$dir/wt" && FM_HOME="$dir/home" FM_KEEPAWAKE_INTERVAL=1 "$KEEPAWAKE" -- sleep 3) &
  pid=$!
  sleep 0.5
  touch -t 202001010000 "$lease"
  sleep 1.5
  [ $(($(date +%s) - $(mtime "$lease"))) -le 5 ] \
    || fail "a running command's lease should be refreshed within one interval"
  wait "$pid" || fail "the wrapped sleep should succeed"
  touch -t 202001010000 "$lease"
  sleep 2
  [ "$(mtime "$lease")" -lt 1600000000 ] \
    || fail "the lease must go stale once the command has exited"
  pass "keepawake: the lease is refreshed until the command exits, then left to go stale"
}

test_term_reaches_background_job_and_lease_stops_after_it_exits() (
  local dir lease pid='' job='' _ rc=0
  trap 'kill -KILL "$pid" "$job" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  dir=$(make_task term)
  lease="$dir/home/state/w1.active"
  cat > "$dir/job.sh" <<'SH'
set -eu
dir=$1
finish() {
  : > "$dir/terminating"
  while [ ! -e "$dir/finish" ]; do sleep 0.1; done
  : > "$dir/ended"
  exit 23
}
trap finish TERM
printf '%s\n' "$$" > "$dir/job.pid"
IFS= read -r input
printf '%s\n' "$input"
: > "$dir/ready"
while :; do sleep 0.1; done
SH
  printf 'job input\n' > "$dir/input"
  (
    cd "$dir/wt" || exit 1
    export FM_HOME="$dir/home" FM_KEEPAWAKE_INTERVAL=1
    exec "$KEEPAWAKE" -- sh "$dir/job.sh" "$dir"
  ) < "$dir/input" > "$dir/output" 2> "$dir/error" &
  pid=$!
  for _ in {1..50}; do
    [ ! -e "$dir/job.pid" ] || read -r job < "$dir/job.pid"
    [ ! -e "$dir/ready" ] || break
    sleep 0.1
  done
  [ -e "$dir/ready" ] || fail "the background job should read stdin and become ready"
  [ "$(cat "$dir/output")" = 'job input' ] || fail "stdin and stdout should pass through"

  kill -TERM "$pid" || fail "TERM should reach the wrapper pid"
  for _ in {1..50}; do
    [ ! -e "$dir/terminating" ] || break
    sleep 0.1
  done
  [ -e "$dir/terminating" ] || fail "TERM to the wrapper pid should reach the job"
  kill -0 "$pid" 2>/dev/null || fail "the wrapper should wait for the job's shutdown"
  touch -t 202001010000 "$lease"
  sleep 2
  [ $(($(date +%s) - $(mtime "$lease"))) -le 5 ] \
    || fail "the lease should stay fresh while the job shuts down"
  touch "$dir/finish"
  for _ in {1..50}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && fail "the wrapper should end when the job exits"
  wait "$pid" || rc=$?
  [ "$rc" = 23 ] || fail "the job's signal-handler exit status should pass through, got $rc"
  [ -e "$dir/ended" ] || fail "the job should finish its shutdown"
  kill -0 "$job" 2>/dev/null && fail "the job should no longer be running"
  touch -t 202001010000 "$lease"
  sleep 2
  [ "$(mtime "$lease")" -lt 1600000000 ] \
    || fail "the lease must stop refreshing after the terminated job exits"
  pass "keepawake: TERM reaches the background job and its lease stops after shutdown"
)

test_resolves_the_task_from_a_subdirectory() {
  local dir
  dir=$(make_task subdir)
  mkdir -p "$dir/wt/src"
  (cd "$dir/wt/src" && FM_HOME="$dir/home" "$KEEPAWAKE" -- true) \
    || fail "a command run from inside the task worktree should be wrapped"
  [ -e "$dir/home/state/w1.active" ] || fail "the lease should be named for the task whose worktree holds the cwd"
  pass "keepawake: the task is resolved from any directory inside its worktree"
}

test_refuses_outside_a_registered_worktree() {
  local dir rc=0 out
  dir=$(make_task unregistered)
  fm_git_init_commit "$dir/other" >/dev/null
  out=$(cd "$dir/other" && FM_HOME="$dir/home" "$KEEPAWAKE" -- touch "$dir/ran" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "an unregistered worktree should refuse with exit 2, got $rc"
  assert_contains "$out" "no task in" "the refusal should say no task records this worktree"
  [ ! -e "$dir/ran" ] || fail "the command must not run when the task cannot be resolved"
  pass "keepawake: a worktree no task records refuses before running the command"
}

test_refuses_without_a_state_directory() {
  local dir rc=0 out
  dir=$(make_task nohome)
  out=$(cd "$dir/wt" && FM_HOME="$dir/missing" "$KEEPAWAKE" -- touch "$dir/ran" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "a home without state/ should refuse with exit 2, got $rc"
  assert_contains "$out" "no state directory" "the refusal should name the missing state directory"
  [ ! -e "$dir/ran" ] || fail "the command must not run when the home cannot be resolved"
  pass "keepawake: a home with no state directory refuses before running the command"
}

test_refuses_without_a_command() {
  local rc=0
  "$KEEPAWAKE" -- >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "no command after -- should refuse with exit 2, got $rc"
  rc=0
  "$KEEPAWAKE" true >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a command without the -- separator should refuse with exit 2, got $rc"
  pass "keepawake: a missing command or separator refuses"
}

test_term_reaches_background_job_and_lease_stops_after_it_exits || exit $?
test_lease_is_held_while_the_command_runs_and_status_passes_through
test_lease_is_refreshed_until_the_command_exits
test_resolves_the_task_from_a_subdirectory
test_refuses_outside_a_registered_worktree
test_refuses_without_a_state_directory
test_refuses_without_a_command
