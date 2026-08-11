#!/usr/bin/env bash
# Contract tests for bin/fm-tasks-finished.sh - the "has every live worker in
# this home finished?" predicate the sbx keep-alive runs inside the guest to
# classify why a screen was static (docs/sbx-backend.md "Static-screen
# classification").
#
# The property that matters is that it only ever claims what the durable record
# supports: a home whose every registered task ended done or failed is accounted
# for, and ANY other shape - one task still running, a task that never reported,
# no task at all, an unreadable home - is "cannot say", never a claim. A wrong
# "finished" reads as "the stop was correct" for a worker that was in fact stuck.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FINISHED="$ROOT/bin/fm-tasks-finished.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-finished)

# make_home <name>: a firstmate home with an empty state/.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# register <home> <id> [kind]: a live task - meta present, so not torn down.
register() {  # <home> <id> [kind]
  printf 'kind=%s\n' "${3:-ship}" > "$1/state/$2.meta"
  : > "$1/state/$2.status"
}

say() {  # <home> <id> <status-line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

test_a_done_worker_is_finished() {
  local home out
  home=$(make_home done-worker)
  register "$home" w1
  say "$home" w1 'working: implementing the fix'
  say "$home" w1 'done: PR https://example.invalid/pr/1 checks green'

  out=$("$FINISHED" "$home") \
    || fail "a worker whose newest event is done must read as finished"
  assert_contains "$out" "w1" "the report names the finished task"
  assert_contains "$out" "done" "the report carries the terminal verb"
  pass "tasks-finished: a done worker reads as finished"
}

test_a_failed_worker_is_finished() {
  # Failed is finished too: the worker will not advance on its own, so a stop on
  # top of it destroys nothing that was still running.
  local home
  home=$(make_home failed-worker)
  register "$home" w1
  say "$home" w1 'failed: the migration cannot be reproduced'

  "$FINISHED" "$home" >/dev/null \
    || fail "a worker whose newest event is failed must read as finished"
  pass "tasks-finished: a failed worker reads as finished"
}

test_a_working_worker_is_not_finished() {
  local home
  home=$(make_home working-worker)
  register "$home" w1
  say "$home" w1 'working: implementing the fix'

  ! "$FINISHED" "$home" >/dev/null \
    || fail "a worker still working must never read as finished"
  pass "tasks-finished: a working worker is not finished"
}

test_a_parked_worker_is_not_finished() {
  # The case this predicate exists to separate from a finished one: a worker
  # waiting on a human ended its turn, but it has NOT finished.
  local home
  home=$(make_home parked-worker)
  register "$home" w1
  say "$home" w1 'needs-decision: ship the rename now or behind a flag'

  ! "$FINISHED" "$home" >/dev/null \
    || fail "a worker parked on a decision must never read as finished"
  pass "tasks-finished: a worker waiting on a human is not finished"
}

test_awaiting_validation_is_not_finished() {
  # awaiting-validation is terminal-and-unfinished by design (AGENTS.md section
  # 7): the worker committed and is owed a trigger. Reading it as finished would
  # record "nothing was lost" for a task still waiting on firstmate.
  local home
  home=$(make_home awaiting-worker)
  register "$home" w1
  say "$home" w1 'awaiting-validation: implementation committed on the branch'

  ! "$FINISHED" "$home" >/dev/null \
    || fail "an awaiting-validation worker must never read as finished"
  pass "tasks-finished: an awaiting-validation worker is not finished"
}

test_every_task_must_be_finished() {
  # EVERY, not ANY. One live worker means the home is not accounted for, however
  # many of its siblings are done.
  local home
  home=$(make_home mixed)
  register "$home" w1
  say "$home" w1 'done: PR https://example.invalid/pr/1 checks green'
  register "$home" w2
  say "$home" w2 'working: running the suite'

  ! "$FINISHED" "$home" >/dev/null \
    || fail "one still-working task must stop the whole home reading as finished"

  say "$home" w2 'done: PR https://example.invalid/pr/2 checks green'
  "$FINISHED" "$home" >/dev/null \
    || fail "every task finished must read as finished"
  pass "tasks-finished: one unfinished task is enough to withhold the claim"
}

test_a_secondmate_is_never_finished() {
  # A secondmate is persistent and never reaches a terminal event of its own,
  # so "finished" cannot be asserted about it.
  local home
  home=$(make_home secondmate)
  register "$home" s1 secondmate
  say "$home" s1 'done: routed item merged'

  ! "$FINISHED" "$home" >/dev/null \
    || fail "a secondmate must never read as finished"
  pass "tasks-finished: a secondmate is never finished"
}

test_a_task_with_no_status_is_not_finished() {
  # A registered task that never reported is exactly the silent worker this
  # classification must not paper over.
  local home
  home=$(make_home silent)
  printf 'kind=ship\n' > "$home/state/w1.meta"

  ! "$FINISHED" "$home" >/dev/null \
    || fail "a registered task with no status file must not read as finished"
  pass "tasks-finished: a task that never reported is not finished"
}

test_a_quiet_home_is_not_finished() {
  # No registered task is "nothing to say", not "everything finished".
  local home
  home=$(make_home quiet)

  ! "$FINISHED" "$home" >/dev/null \
    || fail "a home with no registered task must not claim finished"
  pass "tasks-finished: a home with no registered task claims nothing"
}

test_an_unreadable_home_is_not_finished() {
  ! "$FINISHED" "$TMP_ROOT/no-such-home" >/dev/null \
    || fail "an absent home must not claim finished"
  pass "tasks-finished: an absent home claims nothing"
}

test_a_done_worker_is_finished
test_a_failed_worker_is_finished
test_a_working_worker_is_not_finished
test_a_parked_worker_is_not_finished
test_awaiting_validation_is_not_finished
test_every_task_must_be_finished
test_a_secondmate_is_never_finished
test_a_task_with_no_status_is_not_finished
test_a_quiet_home_is_not_finished
test_an_unreadable_home_is_not_finished

echo "# all fm-tasks-finished tests passed"
