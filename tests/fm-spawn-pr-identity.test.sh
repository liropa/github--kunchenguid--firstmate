#!/usr/bin/env bash
# Regression test for the PR identity a task is watching surviving a respawn.
#
# bin/fm-spawn.sh rewrites state/<id>.meta wholesale from a fixed field list and
# redirects it with `>`, which truncates. pr= was never in that list, so every
# respawn silently disarmed the task's merge poll: the check script, sidecar, and
# registration all stayed on disk looking armed, and only
# fm_pr_poll_artifacts_valid's metadata leg disagreed. The task then watched
# nothing until someone noticed and re-armed it by hand.
#
# The carry-forward has to re-emit those lines LAST. bin/fm-pr-lib.sh rejects the
# whole record when any ordinary field follows pr=, so preserving them in their
# original position would leave the poll just as disarmed. The counterfactual
# table below pins that ordering rule, because nothing else in the tree states it
# and any future field appended after the carry-forward would re-break this.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pr-identity)
PR_URL=https://github.com/o/r/pull/10
PR_HEAD=0123456789abcdef0123456789abcdef01234567

# make_case <name> <id>: a home, a project with a real worktree, and the fakes a
# spawn plus an arming run need. Echoes the case directory.
make_case() {
  local name=$1 id=$2 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data/$id" "$dir/home/projects" "$dir/home/state" \
    "$dir/home/config" "$dir/root/bin"
  fakebin=$(fm_fakebin "$dir")
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$dir/home/data/$id/brief.md"
  touch "$dir/home/state/.last-watcher-beat"
  fm_git_worktree "$dir/project" "$dir/wt" "wt-$name"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" headRefOid "*) printf '%s\n' "$PR_HEAD" ;;
esac
exit 0
SH
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/gh" "$dir/root/bin/fm-guard.sh"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$dir"
}

run_spawn() {  # <dir> <id>
  local dir=$1 id=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$dir/wt" \
    PATH="$dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$dir/project"
}

arm_poll() {  # <dir> <id>
  local dir=$1 id=$2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$id" "$PR_URL"
}

# The whole point: the PR belongs to the task, not to the worker process, so
# replacing the worker must not stop the task's merge poll from watching it.
test_respawn_preserves_the_watched_pr_identity() {
  local dir id state out expected
  id=respawn-keeps-pr
  dir=$(make_case respawn-keeps-pr "$id")
  state="$dir/home/state"

  out=$(run_spawn "$dir" "$id" 2>&1) || fail "initial spawn failed: $out"
  arm_poll "$dir" "$id" >/dev/null || fail "fixture could not arm the merge poll"
  fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "fixture poll was not armed"

  out=$(run_spawn "$dir" "$id" 2>&1) || fail "respawn failed: $out"

  assert_grep "pr=$PR_URL" "$state/$id.meta" "respawn dropped the recorded PR"
  assert_grep "pr_head=$PR_HEAD" "$state/$id.meta" "respawn dropped the recorded PR head"
  expected=$(printf 'pr=%s\npr_head=%s' "$PR_URL" "$PR_HEAD")
  [ "$(tail -2 "$state/$id.meta")" = "$expected" ] \
    || fail "respawn did not emit the PR identity as the last metadata lines"
  fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "the merge poll was disarmed by a respawn"
  pass "a respawn carries the watched PR identity forward as the last metadata lines"
}

# The ordering rule the carry-forward depends on, stated as behavior. Each row is
# a single-variable change to an otherwise untouched armed poll.
test_metadata_pr_identity_ordering_counterfactuals() {
  local dir id state respawn_fields
  id=pr-order-counterfactual
  dir=$(make_case pr-order-counterfactual "$id")
  state="$dir/home/state"
  run_spawn "$dir" "$id" >/dev/null 2>&1 || fail "spawn failed"
  # Exactly what the old wholesale rewrite left behind: the spawn field list with
  # no PR identity carried across it.
  respawn_fields=$(grep -v '^pr=' "$state/$id.meta" | grep -v '^pr_head=')
  arm_poll "$dir" "$id" >/dev/null || fail "fixture could not arm the merge poll"

  fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "baseline: a freshly armed poll with pr= last did not validate"

  printf '%s\n' "$respawn_fields" > "$state/$id.meta"
  ! fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "respawn-shaped rewrite: a poll with no recorded PR identity still validated"

  printf '%s\npr=%s\n' "$respawn_fields" "$PR_URL" > "$state/$id.meta"
  fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "restoring pr= as the last line did not re-validate the poll"

  printf '%s\npr=%s\nwindow=stale-after-pr\n' "$respawn_fields" "$PR_URL" > "$state/$id.meta"
  ! fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "an ordinary field after pr= still validated; the carry-forward could be emitted in place"

  printf '%s\npr=%s\npr_head=%s\n' "$respawn_fields" "$PR_URL" "$PR_HEAD" > "$state/$id.meta"
  fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "pr= followed by pr_head= did not validate"
  pass "a recorded PR identity validates only as the last ordinary metadata field"
}

# The carry-forward removes one spurious input to the guard; it must not soften
# the guard. A record the guard already refuses stays refused across a respawn
# rather than being quietly rewritten into a valid one.
test_respawn_does_not_repair_an_unusable_pr_identity() {
  local dir id state
  id=respawn-refuses-corrupt-pr
  dir=$(make_case respawn-refuses-corrupt-pr "$id")
  state="$dir/home/state"
  run_spawn "$dir" "$id" >/dev/null 2>&1 || fail "spawn failed"
  arm_poll "$dir" "$id" >/dev/null || fail "fixture could not arm the merge poll"

  printf 'window=stale-after-pr\n' >> "$state/$id.meta"
  ! fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "fixture did not actually invalidate the recorded identity"

  run_spawn "$dir" "$id" >/dev/null 2>&1 || fail "respawn failed"
  ! grep -q '^pr=' "$state/$id.meta" \
    || fail "respawn silently repaired a PR identity the guard had already refused"
  ! fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" \
    || fail "respawn re-armed a poll whose metadata the guard refuses"
  pass "a respawn leaves an unusable recorded PR identity behind instead of repairing it"
}

test_respawn_preserves_the_watched_pr_identity
test_metadata_pr_identity_ordering_counterfactuals
test_respawn_does_not_repair_an_unusable_pr_identity

echo "# all fm-spawn-pr-identity tests passed"
