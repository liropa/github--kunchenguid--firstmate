#!/usr/bin/env bash
# Contract tests for bin/fm-parked-decision.sh - the "is a live worker still
# sitting on an unanswered decision?" predicate the sbx keep-alive's fifth arm
# runs inside the guest (docs/sbx-backend.md "Parked-decision arm").
#
# The property that matters in both directions: a parked worker must be
# reported, and a finished, resolved, or torn-down one must not - the second
# half is what keeps an idle guest auto-stopping.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARKED="$ROOT/bin/fm-parked-decision.sh"
TMP_ROOT=$(fm_test_tmproot fm-parked-decision)

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

test_parked_worker_is_reported() {
  local home
  home=$(make_home parked)
  register "$home" w1
  say "$home" w1 'working: implementing the fix'
  say "$home" w1 'needs-decision: ship the rename now or behind a flag'

  out=$("$PARKED" "$home") \
    || fail "a worker parked on an unanswered decision must be reported"
  assert_contains "$out" "w1" "the report names the parked task"
  pass "parked-decision: an open decision on a live task is reported"
}

test_resolved_decision_is_not_parked() {
  local home
  home=$(make_home resolved)
  register "$home" w1
  say "$home" w1 'needs-decision: ship the rename now or behind a flag'
  say "$home" w1 'resolved: behind a flag'

  ! "$PARKED" "$home" >/dev/null \
    || fail "an answered decision must clear the parked report"
  pass "parked-decision: an answered decision no longer reads as parked"
}

test_keyed_decisions_close_independently() {
  local home out
  home=$(make_home keyed)
  register "$home" w1
  say "$home" w1 'needs-decision [key=api-shape]: one call or two'
  say "$home" w1 'needs-decision [key=rollout]: flag or straight ship'
  say "$home" w1 'resolved [key=api-shape]: one call'

  out=$("$PARKED" "$home") || fail "the still-open key must keep the task parked"
  assert_contains "$out" "rollout" "the unanswered key is still reported"
  assert_not_contains "$out" "api-shape" "the answered key is not reported"

  say "$home" w1 'resolved [key=rollout]: straight ship'
  ! "$PARKED" "$home" >/dev/null \
    || fail "closing the last open key must clear the parked report"
  pass "parked-decision: keyed decisions open and close independently"
}

test_captain_held_transfer_closes_the_park() {
  local home
  home=$(make_home held)
  register "$home" w1
  say "$home" w1 'needs-decision [key=api-shape]: one call or two'
  say "$home" w1 'captain-held [key=api-shape]: tracked by w1-decision-api-shape'

  ! "$PARKED" "$home" >/dev/null \
    || fail "a decision transferred to a durable captain hold is no longer a live park"
  pass "parked-decision: a captain-hold transfer closes the park"
}

test_finished_worker_is_not_parked() {
  # THE INVARIANT the keep-alive contract refuses to give up: a finished worker
  # awaiting cleanup must still let the VM stop, even if it left a decision line
  # behind that nothing ever explicitly resolved.
  local home
  home=$(make_home finished)
  register "$home" w1
  say "$home" w1 'needs-decision: ship the rename now or behind a flag'
  say "$home" w1 'done: PR https://example.invalid/pr/1 checks green'

  ! "$PARKED" "$home" >/dev/null \
    || fail "a finished worker must not read as parked"
  pass "parked-decision: a finished worker awaiting cleanup is not parked"
}

test_failed_worker_is_not_parked() {
  local home
  home=$(make_home failed)
  register "$home" w1
  say "$home" w1 'blocked: the upstream API is gone'
  say "$home" w1 'failed: could not reach the upstream API'

  ! "$PARKED" "$home" >/dev/null \
    || fail "a failed worker must not read as parked"
  pass "parked-decision: a failed worker is not parked"
}

test_secondmate_decision_survives_a_terminal_line() {
  # A secondmate never reaches a terminal event of its own, so its decisions
  # stay open past one - the same exemption bin/fm-decision-hold.sh applies.
  local home
  home=$(make_home secondmate)
  register "$home" s1 secondmate
  say "$home" s1 'needs-decision: which project owns the migration'
  say "$home" s1 'done: routed batch landed'

  "$PARKED" "$home" >/dev/null \
    || fail "a secondmate's open decision must survive a later terminal line"
  pass "parked-decision: a secondmate's decision outlives a terminal line"
}

test_unregistered_task_is_not_parked() {
  # No meta means torn down (bin/fm-teardown.sh removes meta and status
  # together), so a leftover status file can never pin anything.
  local home
  home=$(make_home unregistered)
  mkdir -p "$home/state"
  printf 'needs-decision: ship the rename now or behind a flag\n' > "$home/state/w1.status"

  ! "$PARKED" "$home" >/dev/null \
    || fail "a task with no meta must not read as parked"
  pass "parked-decision: an unregistered task is not parked"
}

test_quiet_home_is_not_parked() {
  local home
  home=$(make_home quiet)
  register "$home" w1
  say "$home" w1 'working: implementing the fix'

  ! "$PARKED" "$home" >/dev/null \
    || fail "an ordinary working task must not read as parked"
  pass "parked-decision: a home with no open decision reports nothing"
}

test_unreadable_home_is_not_parked() {
  # Fail closed: an absent home is "nothing parked", never a pin.
  ! "$PARKED" "$TMP_ROOT/no-such-home" >/dev/null \
    || fail "an absent home must not read as parked"
  pass "parked-decision: an absent home is not parked"
}

test_parked_worker_is_reported
test_resolved_decision_is_not_parked
test_keyed_decisions_close_independently
test_captain_held_transfer_closes_the_park
test_finished_worker_is_not_parked
test_failed_worker_is_not_parked
test_secondmate_decision_survives_a_terminal_line
test_unregistered_task_is_not_parked
test_quiet_home_is_not_parked
test_unreadable_home_is_not_parked

echo "# all fm-parked-decision tests passed"
