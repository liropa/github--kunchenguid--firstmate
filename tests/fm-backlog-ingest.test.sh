#!/usr/bin/env bash
# tests/fm-backlog-ingest.test.sh - bin/fm-backlog-ingest.sh: the guest-side
# counterpart to fm-backlog-handoff.sh's sbx delivery path (GitHub issue #11).
#
# Runs as if inside the secondmate's own in-guest home: reads its own
# .fm-secondmate-home / .fm-sbx-signals-dir markers, merges every pending
# signal-bridge batch into its own data/backlog.md idempotently (per-key
# skip, not per-batch skip - a batch with SOME already-present keys still
# merges the rest), and archives a fully-drained batch (whether via its own
# merge or because it arrived already empty, e.g. a race with an operator
# rollback) without ever touching tasks-axi for a no-op batch.
set -u

# shellcheck source=tests/backlog-handoff-sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/backlog-handoff-sbx-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated ingest path)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backlog-ingest)

seed_batch() {  # <pending-dir> <name> <content>
  local dir=$1 name=$2 content=$3
  mkdir -p "$dir"
  printf '%s' "$content" > "$dir/$name"
}

test_ingest_merges_pending_batch_and_archives_it() {
  local w home sig pending ingested out
  w="$TMP_ROOT/basic"; home="$w/home"; sig="$w/signals"
  make_guest_home "$home" sm "$sig"
  pending="$sig/backlog-handoff/pending"
  ingested="$sig/backlog-handoff/ingested"
  seed_batch "$pending" batch-1.md \
    "## In flight

## Queued
- [ ] widget-a - do the thing (repo: alpha)

## Done
"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "ingest of a clean pending batch should succeed: $out"
  assert_contains "$out" "ingested batch-1.md: widget-a" "the merge should be reported"

  assert_grep 'widget-a' "$home/data/backlog.md" "the item should land in the guest's own backlog"
  [ ! -f "$pending/batch-1.md" ] || fail "a merged batch must leave pending/"
  [ -f "$ingested/batch-1.md" ] || fail "a merged batch should be archived to ingested/"
  assert_no_grep 'widget-a' "$ingested/batch-1.md" \
    "tasks-axi mv should have removed the merged item from the archived batch"

  pass "ingest: a clean pending batch merges into the guest's own backlog and is archived"
}

test_ingest_is_idempotent_on_rerun() {
  local w home sig pending backlog_before out
  w="$TMP_ROOT/idem"; home="$w/home"; sig="$w/signals"
  make_guest_home "$home" sm "$sig"
  pending="$sig/backlog-handoff/pending"
  seed_batch "$pending" batch-1.md \
    "## In flight

## Queued
- [ ] widget-b - already-run item (repo: alpha)

## Done
"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" >/dev/null 2>&1 \
    || fail "setup: the first ingest run should merge the seeded batch"
  backlog_before=$(cat "$home/data/backlog.md")

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "a re-run with nothing pending should still succeed: $out"
  assert_contains "$out" "nothing to ingest" "a re-run with no pending batches should report a clean no-op"

  [ "$backlog_before" = "$(cat "$home/data/backlog.md")" ] \
    || fail "a re-run must not mutate the already-merged backlog"
  local count
  count=$(grep -cF -- 'widget-b' "$home/data/backlog.md")
  [ "$count" -eq 1 ] || fail "the item must not be duplicated across runs (count=$count)"

  pass "ingest: re-running after everything is merged is a clean no-op"
}

test_ingest_skips_per_key_not_per_batch() {
  local w home sig pending out
  w="$TMP_ROOT/partial"; home="$w/home"; sig="$w/signals"
  make_guest_home "$home" sm "$sig"
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] already-here - pre-existing local item (repo: alpha)

## Done
EOF
  pending="$sig/backlog-handoff/pending"
  seed_batch "$pending" batch-1.md \
    "## In flight

## Queued
- [ ] already-here - duplicate of a local item (repo: alpha)
- [ ] fresh-one - genuinely new item (repo: alpha)

## Done
"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1) \
    || fail "a batch with one already-present key and one new key should still succeed: $out"

  assert_grep 'fresh-one' "$home/data/backlog.md" "the genuinely new key should be merged"
  local count
  count=$(grep -cF -- '- [ ] already-here' "$home/data/backlog.md")
  [ "$count" -eq 1 ] || fail "the already-present key must not be duplicated (count=$count)"
  [ -f "$sig/backlog-handoff/ingested/batch-1.md" ] \
    || fail "a batch with a mix of already-present and new keys should still be archived once merged"

  pass "ingest: a batch mixing already-present and new keys skips per-key, merges the rest"
}

test_ingest_archives_fully_drained_batch_without_tasks_axi() {
  local w home sig pending out
  w="$TMP_ROOT/drained"; home="$w/home"; sig="$w/signals"
  make_guest_home "$home" sm "$sig"
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] already-drained - already merged or rolled back (repo: alpha)

## Done
EOF
  pending="$sig/backlog-handoff/pending"
  seed_batch "$pending" batch-1.md \
    "## In flight

## Queued
- [ ] already-drained - fully consumed already (repo: alpha)

## Done
"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1) \
    || fail "a fully-drained batch should archive cleanly: $out"
  assert_contains "$out" "ingested (already present): batch-1.md" \
    "a fully-drained batch should be reported distinctly from a real merge"
  [ -f "$sig/backlog-handoff/ingested/batch-1.md" ] \
    || fail "a fully-drained batch should be archived"

  pass "ingest: a batch whose only key is already present archives without needing tasks-axi"
}

test_ingest_noop_without_markers() {
  local w home out
  w="$TMP_ROOT/no-markers"; home="$w/home"
  mkdir -p "$home/data"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1) \
    || fail "a home with no secondmate marker should be a clean no-op: $out"
  assert_contains "$out" "not a seeded secondmate home" "the reason should be named"

  printf 'sm\n' > "$home/.fm-secondmate-home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1) \
    || fail "a secondmate home with no signals-dir marker should be a clean no-op: $out"
  assert_contains "$out" "not an sbx clone-mode guest" "the reason should be named"

  pass "ingest: a non-secondmate or non-sbx home is a clean no-op, never an error"
}

test_ingest_leaves_failed_batch_in_pending_for_retry() {
  local w home sig pending out
  w="$TMP_ROOT/failure"; home="$w/home"; sig="$w/signals"
  make_guest_home "$home" sm "$sig"
  pending="$sig/backlog-handoff/pending"
  # A malformed batch: dep-b is blocked-by blocker-a, but blocker-a is present
  # in neither this batch nor the guest's own backlog - tasks-axi mv must
  # refuse the stranding. Real handoffs never produce this shape (the host
  # always moves a whole connected set together); this models the defensive
  # path if one somehow arrived malformed.
  seed_batch "$pending" batch-1.md \
    "## In flight

## Queued
- [ ] dep-b - dependent item blocked-by: blocker-a (since 2026-07-23)

## Done
"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-ingest.sh" 2>&1)
  local rc=$?
  [ "$rc" -ne 0 ] || fail "a batch whose tasks-axi mv fails must not report overall success"
  assert_contains "$out" "failed to ingest batch-1.md" "the failure should name the batch"

  [ -f "$pending/batch-1.md" ] || fail "a failed batch must remain in pending/ for a later retry"
  [ ! -f "$sig/backlog-handoff/ingested/batch-1.md" ] \
    || fail "a failed batch must not be archived as if it succeeded"
  [ ! -f "$home/data/backlog.md" ] || assert_no_grep 'dep-b' "$home/data/backlog.md" \
    "a failed merge must not have partially written into the guest's own backlog"

  pass "ingest: a batch whose tasks-axi mv fails is left in pending/ for retry, never lost or falsely archived"
}

test_ingest_merges_pending_batch_and_archives_it
test_ingest_is_idempotent_on_rerun
test_ingest_skips_per_key_not_per_batch
test_ingest_archives_fully_drained_batch_without_tasks_axi
test_ingest_noop_without_markers
test_ingest_leaves_failed_batch_in_pending_for_retry

echo "ALL TESTS PASSED"
