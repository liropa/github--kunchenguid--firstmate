#!/usr/bin/env bash
# Tests for bin/fm-promote.sh: the in-place scout -> ship contract flip.
#
# The load-bearing case is the metadata rewrite. A task's state/<id>.meta is
# also the merge-poll identity record validated by fm_pr_metadata_identity_parse
# (bin/fm-pr-lib.sh), and a rewrite that puts an ordinary field in the wrong
# place makes that predicate refuse the whole record. Nothing else notices: the
# poll script, sidecar, and registration all stay on disk looking armed while
# merge monitoring is dead. Promotion cannot reach a task that already has a
# recorded PR today (it only accepts kind=scout), so these tests construct the
# metadata directly rather than changing what promotion accepts.
#
# Matrix:
#   (a) a promoted record carrying a PR identity still passes the parse
#   (b) negative control: the old rewrite shape fails that same parse
#   (c) the ordinary no-PR promotion flips kind= and preserves other fields
#   (d) x_* link fields survive promotion and keep the record valid
#   (e) a non-scout task is still refused (accepted-kind behavior is unchanged)
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote)

PR_URL=https://github.com/example-owner/example-repo/pull/7
PR_HEAD=1111111111111111111111111111111111111111

# make_case <name> <meta line>...: build a home with state/<TASK_ID>.meta holding
# the given lines. Echoes the home dir.
TASK_ID=sample-task
make_case() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  shift
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$TASK_ID.meta" "$@"
  printf '%s\n' "$home"
}

# run_promote <home> [id]: run promotion against that home only. Output is
# captured so the guard banner does not drown the test log; it is printed only
# when an assertion fails. Sets RC and OUT.
run_promote() {
  local home=$1 id=${2:-$TASK_ID}
  set +e
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" "$id" 2>&1)
  RC=$?
  set -e
}

# assert_identity_parses <meta> <msg>: the enforcing owner must accept the record.
assert_identity_parses() {
  # shellcheck disable=SC1091
  ( . "$ROOT/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$1" ) \
    || fail "$2"$'\n'"--- meta ---"$'\n'"$(cat "$1")"
}

# assert_identity_refused <meta> <msg>: the enforcing owner must reject the record.
assert_identity_refused() {
  # shellcheck disable=SC1091
  if ( . "$ROOT/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$1" ); then
    fail "$2"$'\n'"--- meta ---"$'\n'"$(cat "$1")"
  fi
}

# (a) A scout record that already carries a PR identity survives promotion as a
# record the merge poll's own validation still accepts.
test_promotion_keeps_pr_identity_valid() {
  local home meta
  home=$(make_case pr-identity \
    "window=fm-$TASK_ID" \
    "worktree=$TMP_ROOT/wt" \
    "project=$TMP_ROOT/project" \
    "kind=scout" \
    "mode=no-mistakes" \
    "pr=$PR_URL" \
    "pr_head=$PR_HEAD")
  meta="$home/state/$TASK_ID.meta"
  run_promote "$home"
  expect_code 0 "$RC" "promotion of a PR-carrying record"
  assert_grep "kind=ship" "$meta" "promotion did not record kind=ship"
  assert_no_grep "kind=scout" "$meta" "promotion left the scout kind behind"
  assert_grep "pr=$PR_URL" "$meta" "promotion dropped the recorded PR"
  assert_grep "pr_head=$PR_HEAD" "$meta" "promotion dropped the recorded PR head"
  assert_identity_parses "$meta" "promoted record no longer validates as a merge-poll identity"
  pass "promotion keeps a recorded PR identity valid"
}

# (b) Negative control for (a): the rewrite shape promotion used before - copy
# every non-kind line, then append kind= to the end - produces a record the same
# predicate refuses. Without this, (a) could pass against a predicate that
# accepts anything.
test_appending_kind_last_is_refused() {
  local home meta
  home=$(make_case old-shape \
    "window=fm-$TASK_ID" \
    "kind=scout" \
    "pr=$PR_URL" \
    "pr_head=$PR_HEAD")
  meta="$home/state/$TASK_ID.meta"
  {
    grep -v '^kind=' "$meta"
    echo "kind=ship"
  } > "$meta.old-shape"
  assert_identity_refused "$meta.old-shape" \
    "an ordinary field written past the PR identity was accepted; this test cannot catch the regression"
  pass "the superseded rewrite shape is refused by the enforcing owner"
}

# (c) The ordinary path: an investigation task has no PR at all, and promotion
# must still flip the kind and leave every other field intact.
test_promotion_without_pr_preserves_fields() {
  local home meta
  home=$(make_case no-pr \
    "window=fm-$TASK_ID" \
    "worktree=$TMP_ROOT/wt" \
    "project=$TMP_ROOT/project" \
    "harness=claude" \
    "kind=scout" \
    "mode=local-only" \
    "yolo=off")
  meta="$home/state/$TASK_ID.meta"
  run_promote "$home"
  expect_code 0 "$RC" "promotion of a record with no PR"
  assert_grep "kind=ship" "$meta" "promotion did not record kind=ship"
  assert_grep "window=fm-$TASK_ID" "$meta" "promotion dropped window="
  assert_grep "harness=claude" "$meta" "promotion dropped harness="
  assert_grep "mode=local-only" "$meta" "promotion dropped mode="
  assert_grep "yolo=off" "$meta" "promotion dropped yolo="
  assert_no_grep "pr=" "$meta" "promotion invented a PR reference"
  pass "promotion without a PR flips the kind and preserves the other fields"
}

# (d) X-mode link fields ride along on the same record; promotion must keep them
# and must not make the record invalid by moving the identity past them.
test_promotion_keeps_x_link_fields() {
  local home meta
  home=$(make_case x-linked \
    "window=fm-$TASK_ID" \
    "kind=scout" \
    "x_request=req-123" \
    "x_followups=1" \
    "pr=$PR_URL")
  meta="$home/state/$TASK_ID.meta"
  run_promote "$home"
  expect_code 0 "$RC" "promotion of an X-linked record"
  assert_grep "x_request=req-123" "$meta" "promotion dropped the X request link"
  assert_grep "x_followups=1" "$meta" "promotion dropped the X follow-up count"
  assert_identity_parses "$meta" "promoted X-linked record no longer validates"
  pass "promotion keeps the X link fields and a valid record"
}

# (e) Promotion still only accepts a scout task. This fix must not widen what it
# takes, and a ship task must not be rewritten at all.
test_non_scout_is_refused() {
  local home meta before
  home=$(make_case already-ship \
    "window=fm-$TASK_ID" \
    "kind=ship" \
    "pr=$PR_URL")
  meta="$home/state/$TASK_ID.meta"
  before=$(cat "$meta")
  run_promote "$home"
  expect_code 1 "$RC" "promotion of a non-scout task"
  assert_contains "$OUT" "not a scout task" "refusal did not name the reason"
  [ "$(cat "$meta")" = "$before" ] || fail "a refused promotion still rewrote the record"

  home=$(make_case missing-meta)
  run_promote "$home" no-such-task
  expect_code 1 "$RC" "promotion of a task with no record"
  assert_contains "$OUT" "no meta for task" "missing-record refusal did not name the reason"
  pass "promotion still refuses anything that is not a scout task"
}

test_promotion_keeps_pr_identity_valid
test_appending_kind_last_is_refused
test_promotion_without_pr_preserves_fields
test_promotion_keeps_x_link_fields
test_non_scout_is_refused
