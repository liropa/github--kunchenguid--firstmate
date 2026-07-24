#!/usr/bin/env bash
# tests/fm-backlog-handoff-status.test.sh - bin/fm-backlog-handoff-status.sh:
# the ground-truth confirmation tool for an sbx backlog-handoff delivery
# (GitHub issue #11) - reports a batch's location on the signal bridge
# (pending / ingested / rolled-back), never the secondmate's own status
# replies.
set -u

# shellcheck source=tests/backlog-handoff-sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/backlog-handoff-sbx-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-handoff-status)

test_status_refuses_non_sbx_secondmate() {
  local w id out rc=0
  w="$TMP_ROOT/non-sbx"; id=plain-sm
  mkdir -p "$w/main/state"
  fm_write_secondmate_meta "$w/main/state/$id.meta" "$w/sub"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-status.sh" "$id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "status must refuse a secondmate with no recorded sbx backend"
  assert_contains "$out" "not a recorded sbx-backed secondmate" "the refusal reason should be named"

  pass "status: refuses a non-sbx secondmate loudly"
}

test_status_lists_pending_and_ingested_and_rolled_back() {
  local w id sig out
  w="$TMP_ROOT/listing"; id=list-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  mkdir -p "$sig/backlog-handoff/pending" "$sig/backlog-handoff/ingested" "$sig/backlog-handoff/rolled-back"
  printf '## Queued\n- [ ] pending-item - waiting (repo: alpha)\n\n## Done\n' \
    > "$sig/backlog-handoff/pending/batch-p.md"
  printf '## Queued\n\n## Done\n' > "$sig/backlog-handoff/ingested/batch-i.md"
  printf '## Queued\n\n## Done\n' > "$sig/backlog-handoff/rolled-back/batch-r.md"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-status.sh" "$id" 2>&1) \
    || fail "listing status for a recorded sbx secondmate should succeed: $out"
  assert_contains "$out" "pending	batch-p.md	pending-item" "the pending batch and its key should be listed"
  assert_contains "$out" "ingested	batch-i.md" "the ingested batch should be listed"
  assert_contains "$out" "rolled-back	batch-r.md" "the rolled-back batch should be listed"
  assert_contains "$out" "1 pending batch(es), 1 ingested batch(es), 1 rolled-back batch(es)" \
    "the summary counts should be exact"

  pass "status: lists pending, ingested, and rolled-back batches with their keys"
}

test_status_reports_a_named_batch_by_id() {
  local w id sig out
  w="$TMP_ROOT/named"; id=named-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  mkdir -p "$sig/backlog-handoff/pending"
  printf '## Queued\n- [ ] solo-item - one item (repo: alpha)\n\n## Done\n' \
    > "$sig/backlog-handoff/pending/solo-batch.md"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-status.sh" "$id" solo-batch 2>&1) \
    || fail "reporting a known batch id should succeed: $out"
  assert_contains "$out" "pending: $id has not yet ingested this batch" "the batch's status should be named"
  assert_contains "$out" "solo-item" "the batch's keys should be reported"

  # The .md suffix is optional - bare batch ids (as printed by
  # fm-backlog-handoff.sh's own summary) must resolve the same way.
  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-status.sh" "$id" solo-batch.md 2>&1)
  assert_contains "$out" "pending:" "a .md-suffixed batch id should resolve identically"

  pass "status: a named batch id (with or without .md) reports its own status"
}

test_status_unknown_batch_id_refuses() {
  local w id out rc=0
  w="$TMP_ROOT/unknown"; id=unknown-sm
  new_sbx_handoff_world "$w" "$id"

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff-status.sh" "$id" never-existed 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown batch id must refuse, not silently report nothing"
  assert_contains "$out" "unknown:" "the refusal should say the batch id is unknown"

  pass "status: an unknown batch id refuses loudly"
}

test_status_refuses_non_sbx_secondmate
test_status_lists_pending_and_ingested_and_rolled_back
test_status_reports_a_named_batch_by_id
test_status_unknown_batch_id_refuses

echo "ALL TESTS PASSED"
