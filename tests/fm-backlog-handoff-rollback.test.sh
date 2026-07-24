#!/usr/bin/env bash
# tests/fm-backlog-handoff-rollback.test.sh - bin/fm-backlog-handoff-rollback.sh:
# the operator recovery path for an sbx backlog-handoff batch that will never
# be ingested (GitHub issue #11) - reclaims a still-pending batch's items
# back into the main backlog, atomically, and refuses (rather than silently
# no-op-ing or duplicating) for an already-ingested, already-rolled-back, or
# unknown batch.
set -u

# shellcheck source=tests/backlog-handoff-sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/backlog-handoff-sbx-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated rollback path)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backlog-handoff-rollback)

count_files() {  # <glob-dir>
  local dir=$1 n=0 f
  [ -d "$dir" ] || { echo 0; return 0; }
  for f in "$dir"/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

test_rollback_reclaims_pending_batch_into_main_backlog() {
  local w id sig pending rolled_back out
  w="$TMP_ROOT/basic"; id=basic-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  : > "$w/main/data/backlog.md"
  pending="$sig/backlog-handoff/pending"
  mkdir -p "$pending"
  printf '## In flight\n\n## Queued\n- [ ] stuck-item - never ingested (repo: alpha)\n\n## Done\n' \
    > "$pending/stuck-batch.md"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" stuck-batch 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "rolling back a genuinely pending batch should succeed: $out"
  assert_contains "$out" "reclaimed 1 item(s)" "the reclaim should be reported"

  assert_grep 'stuck-item' "$w/main/data/backlog.md" "the item should return to the main backlog"
  [ ! -f "$pending/stuck-batch.md" ] || fail "a rolled-back batch must leave pending/"
  rolled_back="$sig/backlog-handoff/rolled-back/stuck-batch.md"
  [ -f "$rolled_back" ] || fail "a rolled-back batch should be archived to rolled-back/"
  assert_no_grep 'stuck-item' "$rolled_back" \
    "tasks-axi mv should have removed the reclaimed item from the archived batch"

  pass "rollback: a pending batch's item is reclaimed into the main backlog and archived"
}

test_rollback_refuses_already_ingested_batch() {
  local w id sig ingested_dir out rc=0 main_before
  w="$TMP_ROOT/already-ingested"; id=ingested-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  : > "$w/main/data/backlog.md"
  main_before=$(cat "$w/main/data/backlog.md")
  ingested_dir="$sig/backlog-handoff/ingested"
  mkdir -p "$ingested_dir"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$ingested_dir/done-batch.md"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" done-batch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "rolling back an already-ingested batch must be refused (would duplicate the item)"
  assert_contains "$out" "already ingested" "the refusal should name the reason"
  [ "$main_before" = "$(cat "$w/main/data/backlog.md")" ] \
    || fail "a refused rollback must not mutate the main backlog"

  pass "rollback: refuses an already-ingested batch, no mutation"
}

test_rollback_refuses_already_rolled_back_batch() {
  local w id sig rb_dir out rc=0
  w="$TMP_ROOT/already-rolled-back"; id=rb-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  rb_dir="$sig/backlog-handoff/rolled-back"
  mkdir -p "$rb_dir"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$rb_dir/again-batch.md"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" again-batch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "rolling back an already-rolled-back batch must be refused"
  assert_contains "$out" "already rolled back" "the refusal should name the reason"

  pass "rollback: refuses a batch that was already rolled back"
}

test_rollback_refuses_unknown_batch() {
  local w id out rc=0
  w="$TMP_ROOT/unknown"; id=unknown-sm
  new_sbx_handoff_world "$w" "$id"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" never-existed 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "rolling back an unknown batch id must be refused"
  assert_contains "$out" "no pending batch named" "the refusal should name the reason"

  pass "rollback: refuses an unknown batch id"
}

test_rollback_refuses_drained_pending_batch() {
  local w id sig pending out rc=0
  w="$TMP_ROOT/drained"; id=drained-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  pending="$sig/backlog-handoff/pending"
  mkdir -p "$pending"
  # A pending batch file with a scaffold but zero item keys (e.g. observed
  # mid-race with the guest's own ingest, which has not yet archived it).
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$pending/empty-batch.md"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" empty-batch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "rolling back a batch with no remaining keys must be refused, not a silent no-op"
  assert_contains "$out" "no items to reclaim" "the refusal should explain the batch is already drained"
  [ -f "$pending/empty-batch.md" ] || fail "a refused rollback must not touch the batch file"

  pass "rollback: refuses a drained pending batch rather than claiming an ambiguous success"
}

test_rollback_refuses_invalid_batch_id_without_mutation() {
  local w id sig pending out rc=0 main_before
  w="$TMP_ROOT/invalid-id"; id=invalid-id-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  pending="$sig/backlog-handoff/pending"
  mkdir -p "$pending" "$sig/backlog-handoff/rolled-back"
  : > "$w/main/data/backlog.md"
  printf '## In flight\n\n## Queued\n- [ ] stuck-item - never ingested (repo: alpha)\n\n## Done\n' \
    > "$pending/stuck-batch.md"
  main_before=$(cat "$w/main/data/backlog.md")

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" ../stuck-batch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "rollback must refuse a batch id containing '..' and '/'"
  assert_contains "$out" "invalid batch id" "the refusal should name invalid batch-id syntax"
  [ "$main_before" = "$(cat "$w/main/data/backlog.md")" ] \
    || fail "an invalid batch id must not mutate the main backlog"
  [ -f "$pending/stuck-batch.md" ] || fail "an invalid batch id must not move pending batches"
  [ "$(count_files "$sig/backlog-handoff/rolled-back")" -eq 0 ] \
    || fail "an invalid batch id must not archive anything"

  rc=0
  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-rollback.sh" "$id" "bad id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "rollback must refuse a batch id containing disallowed characters"
  assert_contains "$out" "invalid batch id" "the refusal should happen before path construction"

  pass "rollback: refuses path-like or malformed batch ids without mutation"
}

test_rollback_reclaims_pending_batch_into_main_backlog
test_rollback_refuses_already_ingested_batch
test_rollback_refuses_already_rolled_back_batch
test_rollback_refuses_unknown_batch
test_rollback_refuses_drained_pending_batch
test_rollback_refuses_invalid_batch_id_without_mutation

echo "ALL TESTS PASSED"
