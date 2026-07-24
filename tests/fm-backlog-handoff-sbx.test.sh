#!/usr/bin/env bash
# tests/fm-backlog-handoff-sbx.test.sh - bin/fm-backlog-handoff.sh's sbx
# delivery path (GitHub issue #11).
#
# A destination detected as backend=sbx must never write into the
# secondmate's host clone (a point-in-time snapshot the guest never
# re-reads); the moved item instead lands in a durable batch artifact on the
# signal bridge, and the secondmate is nudged to ingest it. Covers detection,
# atomic batch-artifact creation (success and tasks-axi-mv-failure cleanup),
# idempotent re-handoff of an already-queued key, missing-signals-dir
# refusal, and honest non-claiming success/failure reporting through a real
# nudge send (bin/fm-send.sh).
#
# The guest-side merge (bin/fm-backlog-ingest.sh) and host recovery tooling
# (bin/fm-backlog-handoff-status.sh, bin/fm-backlog-handoff-rollback.sh) have
# their own dedicated suites; the delegated non-sbx move and registry-parsing
# edge cases stay in tests/fm-backlog-handoff.test.sh.
set -u

# shellcheck source=tests/backlog-handoff-sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/backlog-handoff-sbx-helpers.sh"
# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated handoff path)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the sbx adapter's state probe)"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# tasks-axi's real directory, so a PATH built for "no live sbx must be
# reachable" (a real `sbx` binary may be installed ambiently, e.g. via
# Homebrew, and must never actually be invoked by these tests) still finds
# the real tasks-axi the delegated move needs.
TAXI_DIR=$(dirname "$(command -v tasks-axi)")
NO_SBX_PATH="$TAXI_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-backlog-handoff-sbx)

pending_dir_of() { printf '%s/backlog-handoff/pending' "$1"; }
ingested_dir_of() { printf '%s/backlog-handoff/ingested' "$1"; }

count_files() {  # <glob-dir>
  local dir=$1 n=0 f
  [ -d "$dir" ] || { echo 0; return 0; }
  for f in "$dir"/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

test_sbx_destination_queues_batch_never_touches_host_clone() {
  local w id sig out rc=0
  w="$TMP_ROOT/basic"; id=basic-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  cat > "$w/main/data/backlog.md" <<'EOF'
## Queued
- [ ] widget-a - do the thing (repo: alpha)

## Done
EOF

  # No sbx/jq fake wired for the nudge on purpose: the nudge is expected to
  # fail (no live sandbox), which must NOT affect the durable, already-atomic
  # artifact write that happened before it.
  out=$(PATH="$NO_SBX_PATH" FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" widget-a 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed nudge should still exit non-zero (never silently claim success)"

  assert_not_contains "$out" "handed off" \
    "sbx delivery must never use the non-sbx 'handed off' success phrasing"
  assert_contains "$out" "queued 1 item(s) for $id via the signal bridge" \
    "sbx delivery should report a queued (not handed-off) outcome"
  assert_contains "$out" "NOT yet confirmed in $id's own backlog" \
    "sbx delivery must explicitly disclaim guest-side confirmation"
  assert_contains "$out" "safely queued (no data lost)" \
    "a failed nudge must reassure that the durable artifact is unaffected"
  assert_contains "$out" "fm-backlog-handoff-rollback.sh $id" \
    "a failed nudge should point at the rollback recovery path"

  assert_no_grep 'widget-a' "$w/main/data/backlog.md" "the item must leave the main backlog"
  [ ! -f "$w/sub/data/backlog.md" ] \
    || fail "sbx delivery must never write into the secondmate's host clone backlog.md"

  local pending
  pending=$(pending_dir_of "$sig")
  [ "$(count_files "$pending")" -eq 1 ] || fail "exactly one batch artifact should exist under $pending"
  assert_grep 'widget-a' "$pending"/*.md "the batch artifact should carry the moved item"

  pass "sbx destination: item queued via the signal bridge, host clone untouched, failure reported honestly"
}

test_sbx_multi_key_connected_set_lands_in_one_batch() {
  local w id sig out
  w="$TMP_ROOT/multi"; id=multi-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  cat > "$w/main/data/backlog.md" <<'EOF'
## Queued
- [ ] item-one - first (repo: alpha)
- [ ] item-two - second (repo: alpha)

## Done
EOF

  out=$(PATH="$NO_SBX_PATH" FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" item-one item-two 2>&1) || true
  assert_contains "$out" "queued 2 item(s)" "both keys should be reported as queued together"

  local pending
  pending=$(pending_dir_of "$sig")
  [ "$(count_files "$pending")" -eq 1 ] || fail "a multi-key handoff should land in exactly one batch artifact"
  assert_grep 'item-one' "$pending"/*.md "item-one should be in the batch"
  assert_grep 'item-two' "$pending"/*.md "item-two should be in the batch"
  assert_no_grep 'item-one' "$w/main/data/backlog.md" "item-one should leave the main backlog"
  assert_no_grep 'item-two' "$w/main/data/backlog.md" "item-two should leave the main backlog"

  pass "sbx destination: a multi-key connected set lands in one batch artifact"
}

test_sbx_rehandoff_of_pending_key_is_idempotent() {
  local w id sig out main_before pending
  w="$TMP_ROOT/idem"; id=idem-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  cat > "$w/main/data/backlog.md" <<'EOF'
## Queued
- [ ] repeat-me - queue then re-handoff (repo: alpha)

## Done
EOF

  PATH="$NO_SBX_PATH" FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" repeat-me >/dev/null 2>&1 || true
  pending=$(pending_dir_of "$sig")
  [ "$(count_files "$pending")" -eq 1 ] || fail "setup: exactly one batch should exist before the re-run"
  main_before=$(cat "$w/main/data/backlog.md")

  out=$(PATH="$NO_SBX_PATH" FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" repeat-me 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "re-handoff of an already-queued sbx key must succeed cleanly, got rc=$rc: $out"
  assert_contains "$out" "already queued or ingested via the signal bridge" \
    "re-handoff of a pending sbx key must be reported as already queued, not missing"

  [ "$main_before" = "$(cat "$w/main/data/backlog.md")" ] \
    || fail "idempotent re-handoff must not mutate the main backlog"
  [ "$(count_files "$pending")" -eq 1 ] \
    || fail "idempotent re-handoff must not create a second batch artifact"

  pass "sbx destination: re-handoff of an already-pending key is idempotent, not 'missing'"
}

test_sbx_missing_signals_dir_refuses_without_mutation() {
  local w id out rc=0
  w="$TMP_ROOT/missing-sig"; id=missing-sig-sm
  new_sbx_handoff_world "$w" "$id"
  # Point the recorded signals dir at a path that was never created.
  rm -rf "$w/signals/$id"
  cat > "$w/main/data/backlog.md" <<'EOF'
## Queued
- [ ] stray-item - should stay put (repo: alpha)

## Done
EOF

  out=$(PATH="$NO_SBX_PATH" FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" stray-item 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a recorded but nonexistent signal-bridge dir must refuse loudly"
  assert_contains "$out" "does not exist" "the refusal should name the missing signal-bridge dir"
  assert_grep 'stray-item' "$w/main/data/backlog.md" \
    "nothing should move when the recorded signal-bridge dir is missing"
  [ ! -e "$w/signals/$id" ] || fail "a missing signals dir must not be silently created"

  pass "sbx destination: a recorded-but-missing signal-bridge dir refuses loudly with no mutation"
}

test_sbx_stranded_dependency_leaves_nothing_moved() {
  local w id sig out rc=0 main_before pending
  w="$TMP_ROOT/stranded"; id=stranded-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  : > "$w/main/data/backlog.md"
  tasks-axi add blocker-a "blocker item" --file "$w/main/data/backlog.md" >/dev/null
  tasks-axi add dep-b "dependent item" --file "$w/main/data/backlog.md" >/dev/null
  tasks-axi block dep-b --by blocker-a --file "$w/main/data/backlog.md" >/dev/null
  main_before=$(cat "$w/main/data/backlog.md")

  out=$(PATH="$NO_SBX_PATH" FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" dep-b 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "moving a dependent without its blocker must fail (tasks-axi's stranding refusal)"
  assert_contains "$out" "tasks-axi mv failed" "the stranding refusal should be surfaced"

  [ "$main_before" = "$(cat "$w/main/data/backlog.md")" ] \
    || fail "a stranding refusal must leave the main backlog byte-identical"
  pending=$(pending_dir_of "$sig")
  [ "$(count_files "$pending")" -eq 0 ] \
    || fail "a failed tasks-axi mv must remove the freshly-created batch artifact (nothing moved)"

  pass "sbx destination: a stranded-dependency tasks-axi mv failure leaves nothing moved, batch cleaned up"
}

test_non_sbx_meta_leaves_old_path_unchanged() {
  local w id out
  w="$TMP_ROOT/non-sbx"; id=tmux-sm
  mkdir -p "$w/main/data" "$w/main/state"
  local home="$w/sub"
  seed_secondmate_home_marker "$home" "$id"
  local sub_abs
  sub_abs=$(cd "$home" && pwd -P)
  printf -- '- %s - tmux domain (home: %s; scope: tmux domain; projects: alpha; added 2026-07-23)\n' \
    "$id" "$sub_abs" > "$w/main/data/secondmates.md"
  # A meta exists, but names a non-sbx backend - detection must fall through.
  fm_write_meta "$w/main/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home" "project=$home" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$home" "projects=alpha"
  cat > "$w/main/data/backlog.md" <<'EOF'
## Queued
- [ ] plain-item - normal delegated move (repo: alpha)

## Done
EOF

  out=$(FM_HOME="$w/main" "$ROOT/bin/fm-backlog-handoff.sh" "$id" plain-item 2>&1) \
    || fail "a non-sbx destination with unrelated meta present should use the unchanged delegated path: $out"
  assert_contains "$out" "handed off 1 item(s) to $id" \
    "a non-sbx destination must keep the original success phrasing"
  assert_grep 'plain-item' "$home/data/backlog.md" \
    "a non-sbx destination should still receive the item in its host clone backlog"

  pass "non-sbx destination with an unrelated recorded backend: delegated path unchanged"
}

test_sbx_nudge_success_reports_delivery_not_ingestion() {
  local w id sig fb out rc=0
  w="$TMP_ROOT/nudge-ok"; id=nudge-ok-sm
  new_sbx_handoff_world "$w" "$id"
  sig="$w/signals/$id"
  cat > "$w/main/data/backlog.md" <<'EOF'
## Queued
- [ ] ping-item - nudge should reach a live guest (repo: alpha)

## Done
EOF

  fb=$(make_fake_sbx "$w")
  sbx_ls_json "fm-$id" running > "$w/ls.json"
  printf 'idle notice line\n' > "$w/pane.txt"

  out=$(PATH="$fb:$TAXI_DIR:$BASE_PATH" FM_HOME="$w/main" FM_STATE_OVERRIDE="$w/main/state" \
    FM_FAKE_SBX_LS_FILE="$w/ls.json" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_TYPE_ECHO=1 FM_FAKE_SBX_ENTER_BUSY=1 \
    FM_SBX_KEEPALIVE_MAX=0 FM_SEND_SETTLE=0 FM_SBX_RESURRECT_READY_TRIES=0 \
    "$ROOT/bin/fm-backlog-handoff.sh" "$id" ping-item 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a nudge that reaches a live sandbox pane should exit 0: $out"

  assert_contains "$out" "nudged $id to ingest it" \
    "a successful nudge send should be reported"
  assert_not_contains "$out" "handed off" \
    "even a successful nudge must not claim the old direct-handoff success phrasing"
  assert_contains "$out" "NOT yet confirmed in $id's own backlog" \
    "delivering the nudge is not the same as the guest having ingested the batch"
  [ ! -f "$w/sub/data/backlog.md" ] \
    || fail "sbx delivery must never write into the secondmate's host clone backlog.md"

  pass "sbx destination: a nudge that reaches a live guest still reports queued, not delivered"
}

test_sbx_destination_queues_batch_never_touches_host_clone
test_sbx_multi_key_connected_set_lands_in_one_batch
test_sbx_rehandoff_of_pending_key_is_idempotent
test_sbx_missing_signals_dir_refuses_without_mutation
test_sbx_stranded_dependency_leaves_nothing_moved
test_non_sbx_meta_leaves_old_path_unchanged
test_sbx_nudge_success_reports_delivery_not_ingestion

echo "ALL TESTS PASSED"
