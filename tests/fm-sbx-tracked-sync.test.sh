#!/usr/bin/env bash
# tests/fm-sbx-tracked-sync.test.sh - the sbx guest-clone tracked-file sync
# (fork issue #20): bin/backends/sbx.sh's fm_backend_sbx_tracked_sync, its
# resurrect-time hook in fm_backend_sbx_ensure_stack, and the per-guest
# outcome reporting in bin/fm-update.sh and bin/fm-bootstrap.sh.
#
# The guarantees under test (docs/sbx-backend.md "Tracked-file sync"):
#   - A stale guest clone fast-forwards to the host clone's default-branch
#     tip via a bundle on the signal bridge, using only plain git in-guest -
#     including a PRE-FIX guest whose snapshot predates this mechanism (its
#     seeded markers are untracked because its old .gitignore never listed
#     them, and it lacks bin/fm-backlog-ingest.sh entirely).
#   - ff_target's guards hold in-guest: a dirty, diverged, or wrong-branch
#     guest is skipped with an honest reason and its work is untouched; the
#     advance is a single-parent fast-forward; gitignored operational dirs
#     are never touched.
#   - The sbx_guest_synced= meta cache makes a current guest cost ZERO sbx
#     CLI calls, and is only ever recorded from the guest's own report.
#   - sweep mode never syncs a running VM (mid-turn safety) and skips an
#     absent sandbox; resurrect mode owns the pre-agent-relaunch safe point.
#   - fm-update.sh prints one guest outcome line per sbx-backed secondmate;
#     the bootstrap sweep classifies updated as BOOTSTRAP_INFO, current as
#     silence, and every skip as an actionable SECONDMATE_SYNC line.
set -u

# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the sbx adapter's state probe)"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-sbx-tracked-sync)

# new_sync_world <name>: an origin repo whose history models the real
# chicken-and-egg shape, a host-side secondmate home clone at the tip, a
# guest-clone fixture (reset behind per test), a signal-bridge dir, and a live
# kind=secondmate meta with backend=sbx.
#   c1 (pre-fix):  .gitignore does NOT list .fm-sbx-signals-dir, and
#                  bin/fm-backlog-ingest.sh does not exist yet.
#   c2 (current):  ignores both seeded markers, ships bin/fm-backlog-ingest.sh,
#                  and bumps the instruction surface.
new_sync_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/signals/sm"
  touch "$w/home/state/.last-watcher-beat"

  git init -q -b main "$w/origin"
  printf 'projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n.fm-secondmate-home\n' > "$w/origin/.gitignore"
  printf 'v1\n' > "$w/origin/AGENTS.md"
  mkdir -p "$w/origin/bin" "$w/origin/.agents/skills"
  printf 'echo a\n' > "$w/origin/bin/tool.sh"
  printf 's1\n' > "$w/origin/.agents/skills/note.md"
  git -C "$w/origin" add -A
  git -C "$w/origin" commit -qm c1
  printf '.fm-sbx-signals-dir\n' >> "$w/origin/.gitignore"
  printf 'echo ingest\n' > "$w/origin/bin/fm-backlog-ingest.sh"
  printf 'v2\n' > "$w/origin/AGENTS.md"
  git -C "$w/origin" add -A
  git -C "$w/origin" commit -qm c2

  git clone -q "$w/origin" "$w/host"
  git -C "$w/host" remote set-head origin main >/dev/null 2>&1 || true
  git clone -q "$w/host" "$w/guest"
  printf 'sm\n' > "$w/host/.fm-secondmate-home"
  printf 'sm\n' > "$w/guest/.fm-secondmate-home"
  printf '%s\n' "$w/signals/sm" > "$w/guest/.fm-sbx-signals-dir"
  {
    printf 'window=sbx:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'backend=sbx\n'
    printf 'harness=claude\n'
    printf 'home=%s\n' "$w/host"
    printf 'sbx_signals_dir=%s\n' "$w/signals/sm"
  } > "$w/home/state/sm.meta"
  sbx_ls_json fm-sm stopped > "$w/ls.json"
  : > "$w/sbx.log"
  printf '%s\n' "$w"
}

host_tip() { git -C "$1/host" rev-parse HEAD; }
guest_head() { git -C "$1/guest" rev-parse HEAD; }

# run_sync <world> <mode> [env k=v...]: drive fm_backend_sbx_tracked_sync in a
# bash that sourced fm-backend.sh + the sbx adapter, fake sbx first in PATH,
# the guest fixture wired through the remap. Echoes the one outcome line.
run_sync() {
  local w=$1 mode=$2 fb
  shift 2
  fb=$(make_fake_sbx "$w")
  # shellcheck disable=SC2016  # single quotes deliberate: $0/$1.. expand in the inner bash
  PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_GUEST_HOME="$w/guest" FM_SBX_SIGNALS_ROOT="$w/signals" \
    env "$@" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source sbx; fm_backend_sbx_tracked_sync "secondmate sm guest" fm-sm sm "$1" "$2" "$3"' \
    "$ROOT" "$w/host" "$w/home/state/sm.meta" "$mode"
}

# --- T1: a stale PRE-FIX guest fast-forwards to the host tip -----------------
test_stale_prefix_guest_updates() {
  local w tip out before_status tracked_mode bundle_mode old_umask
  w=$(new_sync_world stale-updates)
  git -C "$w/guest" reset -q --hard HEAD~1
  tip=$(host_tip "$w")

  # Prove the pre-fix shape is real: the old snapshot lacks the ingest script
  # and its .gitignore leaves the seeded signals marker visibly untracked.
  [ ! -e "$w/guest/bin/fm-backlog-ingest.sh" ] || fail "fixture: pre-fix guest should lack bin/fm-backlog-ingest.sh"
  before_status=$(git -C "$w/guest" status --porcelain)
  assert_contains "$before_status" "?? .fm-sbx-signals-dir" "fixture: pre-fix guest sees the signals marker as untracked"

  # Operational-dir canaries: a tracked-files fast-forward must not touch them.
  mkdir -p "$w/guest/data" "$w/guest/state" "$w/guest/config"
  printf 'backlog\n' > "$w/guest/data/backlog.md"
  printf 'sig\n' > "$w/guest/state/probe"
  printf 'cfg\n' > "$w/guest/config/probe"

  old_umask=$(umask)
  umask 077
  out=$(run_sync "$w" sweep)
  umask "$old_umask"

  assert_contains "$out" "secondmate sm guest: updated " "stale guest reports an advance"
  [ "$(guest_head "$w")" = "$tip" ] || fail "guest did not advance to the host tip"
  [ -f "$w/guest/bin/fm-backlog-ingest.sh" ] || fail "the update did not deliver bin/fm-backlog-ingest.sh to the guest"
  # Single-parent fast-forward, never a merge commit.
  [ "$(git -C "$w/guest" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "guest tip is not a single-parent fast-forward"
  # Markers survive and are ignored once the new .gitignore lands.
  [ "$(cat "$w/guest/.fm-sbx-signals-dir")" = "$w/signals/sm" ] || fail "signals marker content changed"
  [ -z "$(git -C "$w/guest" status --porcelain)" ] || fail "guest should be status-clean after syncing past the marker-ignore commit"
  # Operational dirs untouched.
  [ "$(cat "$w/guest/data/backlog.md")" = "backlog" ] || fail "data/ canary changed"
  [ "$(cat "$w/guest/state/probe")" = "sig" ] || fail "state/ canary changed"
  [ "$(cat "$w/guest/config/probe")" = "cfg" ] || fail "config/ canary changed"
  # The verified guest HEAD is recorded, and the bundle rode the signal bridge.
  assert_grep "sbx_guest_synced=$tip" "$w/home/state/sm.meta" "meta records the guest's new HEAD"
  assert_present "$w/signals/sm/tracked-sync/host-$tip.bundle" "update bundle published on the signal bridge"
  tracked_mode=$(stat -f '%Lp' "$w/signals/sm/tracked-sync" 2>/dev/null || stat -c '%a' "$w/signals/sm/tracked-sync")
  bundle_mode=$(stat -f '%Lp' "$w/signals/sm/tracked-sync/host-$tip.bundle" 2>/dev/null || stat -c '%a' "$w/signals/sm/tracked-sync/host-$tip.bundle")
  [ "$tracked_mode" = 755 ] || fail "tracked-sync dir should be guest-traversable under restrictive umask, got $tracked_mode"
  [ "$bundle_mode" = 644 ] || fail "bundle should be guest-readable under restrictive umask, got $bundle_mode"
  pass "T1 stale pre-fix guest fast-forwards to the host tip with only host scripts + guest git"
}

# --- T2: cache hit reports current with ZERO sbx CLI calls -------------------
test_cache_hit_costs_no_sbx_calls() {
  local w tip out
  w=$(new_sync_world cache-hit)
  tip=$(host_tip "$w")
  printf 'sbx_guest_synced=%s\n' "$tip" >> "$w/home/state/sm.meta"

  out=$(run_sync "$w" sweep)

  assert_contains "$out" "secondmate sm guest: already current" "cache hit reports already current"
  [ ! -s "$w/sbx.log" ] || fail "a cache-hit verdict must not spend any sbx CLI call: $(cat "$w/sbx.log")"
  pass "T2 sbx_guest_synced cache hit is zero-cost (no state probe, no exec, no VM churn)"
}

# --- T3: no cache + actually-current guest verifies in-guest, then caches ----
test_uncached_current_verifies_then_caches() {
  local w tip out lines_after_first
  w=$(new_sync_world uncached-current)
  tip=$(host_tip "$w")

  out=$(run_sync "$w" sweep)
  assert_contains "$out" "secondmate sm guest: already current" "verified-current guest reports already current"
  assert_grep "sbx_guest_synced=$tip" "$w/home/state/sm.meta" "verification recorded the guest HEAD"
  lines_after_first=$(wc -l < "$w/sbx.log" | tr -d ' ')
  [ "$lines_after_first" -gt 0 ] || fail "the uncached pass should have consulted the guest"

  out=$(run_sync "$w" sweep)
  assert_contains "$out" "secondmate sm guest: already current" "second pass stays current"
  [ "$(wc -l < "$w/sbx.log" | tr -d ' ')" -eq "$lines_after_first" ] \
    || fail "the cached second pass must not spend further sbx CLI calls"
  pass "T3 an uncached current guest is verified in-guest once, then served from the cache"
}

# --- T4: dirty guest is skipped, its work untouched ---------------------------
test_dirty_guest_skipped() {
  local w before out
  w=$(new_sync_world dirty-skip)
  git -C "$w/guest" reset -q --hard HEAD~1
  printf 'uncommitted guest edit\n' >> "$w/guest/AGENTS.md"
  before=$(guest_head "$w")

  out=$(run_sync "$w" sweep)

  assert_contains "$out" "secondmate sm guest: skipped: dirty guest working tree" "dirty guest is skipped with the honest reason"
  [ "$(guest_head "$w")" = "$before" ] || fail "dirty guest HEAD moved"
  grep -q 'uncommitted guest edit' "$w/guest/AGENTS.md" || fail "dirty guest edit was discarded"
  assert_no_grep "sbx_guest_synced=" "$w/home/state/sm.meta" "a skipped guest must not be recorded as synced"
  pass "T4 dirty guest is skipped, its uncommitted work preserved"
}

# --- T5: diverged guest is skipped, its commit preserved ----------------------
test_diverged_guest_skipped() {
  local w before out
  w=$(new_sync_world diverged-skip)
  git -C "$w/guest" reset -q --hard HEAD~1
  printf 'guest-only work\n' > "$w/guest/guest-only.md"
  git -C "$w/guest" add guest-only.md
  git -C "$w/guest" commit -qm guest-only
  before=$(guest_head "$w")

  out=$(run_sync "$w" sweep)

  assert_contains "$out" "secondmate sm guest: skipped: guest clone diverged from the host clone" "diverged guest is skipped"
  [ "$(guest_head "$w")" = "$before" ] || fail "diverged guest HEAD moved"
  git -C "$w/guest" cat-file -e HEAD:guest-only.md || fail "guest-only commit was lost"
  pass "T5 diverged guest (unique commits) is skipped, its commit preserved"
}

# --- T6: wrong-branch guest is skipped ----------------------------------------
test_wrong_branch_guest_skipped() {
  local w before out
  w=$(new_sync_world branch-skip)
  git -C "$w/guest" checkout -q -b feature HEAD~1
  before=$(guest_head "$w")

  out=$(run_sync "$w" sweep)

  assert_contains "$out" "secondmate sm guest: skipped: guest clone is on feature, expected main" "wrong-branch guest is skipped"
  [ "$(guest_head "$w")" = "$before" ] || fail "wrong-branch guest HEAD moved"
  pass "T6 wrong-branch guest is skipped, never switched or advanced"
}

# --- T7: sweep mode never syncs a running VM (mid-turn safety) ----------------
test_sweep_skips_running_vm() {
  local w before out
  w=$(new_sync_world running-skip)
  git -C "$w/guest" reset -q --hard HEAD~1
  sbx_ls_json fm-sm running > "$w/ls.json"
  before=$(guest_head "$w")

  out=$(run_sync "$w" sweep)

  assert_contains "$out" "secondmate sm guest: skipped: guest VM is running" "running VM is skipped, never synced mid-turn"
  [ "$(guest_head "$w")" = "$before" ] || fail "running-VM guest HEAD moved"
  [ ! -d "$w/signals/sm/tracked-sync" ] || fail "a skipped running VM must not even stage a bundle"
  pass "T7 sweep mode defers a running VM to its next restart"
}

# --- T8: sweep mode skips absent sandbox / missing bridge / failed exec -------
test_sweep_skips_absent_and_broken() {
  local w out
  w=$(new_sync_world absent-skip)
  git -C "$w/guest" reset -q --hard HEAD~1

  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  out=$(run_sync "$w" sweep)
  assert_contains "$out" "secondmate sm guest: skipped: sandbox is absent" "absent sandbox is skipped"

  sbx_ls_json fm-sm stopped > "$w/ls.json"
  rm -rf "$w/signals/sm"
  out=$(run_sync "$w" sweep)
  assert_contains "$out" "secondmate sm guest: skipped: signal-bridge dir is missing" "missing bridge dir is an honest skip"

  mkdir -p "$w/signals/sm"
  out=$(run_sync "$w" sweep FM_FAKE_SBX_SYNC_RC=1)
  assert_contains "$out" "secondmate sm guest: skipped: no verdict from the guest" "a failed guest exec never claims success"
  pass "T8 absent sandbox, missing bridge dir, and failed exec all skip honestly"
}

# --- T9: resurrect mode owns the pre-agent safe point (no state gate) ---------
test_resurrect_mode_syncs_running_vm() {
  local w tip out
  w=$(new_sync_world resurrect-mode)
  git -C "$w/guest" reset -q --hard HEAD~1
  sbx_ls_json fm-sm running > "$w/ls.json"
  tip=$(host_tip "$w")

  out=$(run_sync "$w" resurrect)

  assert_contains "$out" "secondmate sm guest: updated " "resurrect mode syncs regardless of VM state"
  [ "$(guest_head "$w")" = "$tip" ] || fail "resurrect-mode guest did not advance"
  pass "T9 resurrect mode syncs at the caller-held safe point without a state gate"
}

# --- T10: ensure_stack resurrection syncs the guest before relaunch -----------
test_ensure_stack_resurrection_syncs() {
  local w tip fb err
  w=$(new_sync_world ensure-stack)
  git -C "$w/guest" reset -q --hard HEAD~1
  sbx_ls_json fm-sm running > "$w/ls.json"
  tip=$(host_tip "$w")
  fb=$(make_fake_sbx "$w")

  # No guest tmux server (TMUX_HAS_RC=1) forces the rebuild path; the fake's
  # display-message reports a live claude pane so delivery is allowed.
  # shellcheck disable=SC2016  # single quotes deliberate: $0 expands in the inner bash
  err=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_GUEST_HOME="$w/guest" FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_FAKE_SBX_TMUX_HAS_RC=1 FM_FAKE_SBX_FG=claude \
    FM_SBX_RESURRECT_SETTLE=0 FM_SBX_RESURRECT_READY_TRIES=0 FM_SBX_KEEPALIVE_MAX=0 \
    FM_STATE_OVERRIDE="$w/home/state" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source sbx; fm_backend_sbx_ensure_stack sbx:fm-sm' \
    "$ROOT" 2>&1) || fail "ensure_stack failed: $err"

  assert_contains "$err" "sandbox fm-sm guest: updated " "resurrection reports the guest sync"
  [ "$(guest_head "$w")" = "$tip" ] || fail "resurrection did not sync the guest clone"
  grep -q "tmux new-session" "$w/sbx.log" || fail "resurrection did not rebuild the guest stack after the sync"
  pass "T10 ensure_stack resurrection syncs the guest clone before relaunching the agent"
}

# --- T11: fm-update.sh prints a per-guest outcome line ------------------------
test_fm_update_reports_guest_outcome() {
  local w tip fb out
  w=$(new_sync_world fm-update)
  git -C "$w/guest" reset -q --hard HEAD~1
  tip=$(host_tip "$w")
  fb=$(make_fake_sbx "$w")
  # A separate FM_ROOT clone so the firstmate line does not touch the home.
  git clone -q "$w/origin" "$w/root"
  git -C "$w/root" remote set-head origin main >/dev/null 2>&1 || true

  out=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_GUEST_HOME="$w/guest" FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/root" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null)

  assert_contains "$out" "secondmate sm: already current" "host home line still reports the HOST clone"
  assert_contains "$out" "secondmate sm guest: updated " "guest line reports the guest's own advance"
  [ "$(guest_head "$w")" = "$tip" ] || fail "fm-update did not sync the guest"

  out=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_GUEST_HOME="$w/guest" FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/root" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null)
  assert_contains "$out" "secondmate sm guest: already current" "a synced guest reports already current on the next run"
  pass "T11 fm-update.sh reports the guest outcome for every sbx-backed secondmate"
}

# --- T12: the bootstrap sweep surfaces guest staleness honestly ---------------
test_bootstrap_classifies_guest_outcomes() {
  local w tip fb out
  w=$(new_sync_world bootstrap-info)
  git -C "$w/guest" reset -q --hard HEAD~1
  tip=$(host_tip "$w")
  fb=$(make_fake_sbx "$w")
  git clone -q "$w/origin" "$w/root"
  git -C "$w/root" remote set-head origin main >/dev/null 2>&1 || true

  out=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_GUEST_HOME="$w/guest" FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/root" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm guest: updated " "a completed guest sync is a BOOTSTRAP_INFO fact"
  assert_not_contains "$out" "SECONDMATE_SYNC: secondmate sm guest" "a completed guest sync is not an actionable skip"
  [ "$(guest_head "$w")" = "$tip" ] || fail "bootstrap did not sync the stopped stale guest"

  # A running stale guest is surfaced as an actionable skip, never synced.
  w=$(new_sync_world bootstrap-skip)
  git -C "$w/guest" reset -q --hard HEAD~1
  sbx_ls_json fm-sm running > "$w/ls.json"
  fb=$(make_fake_sbx "$w")
  git clone -q "$w/origin" "$w/root"
  git -C "$w/root" remote set-head origin main >/dev/null 2>&1 || true

  out=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_GUEST_HOME="$w/guest" FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/root" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "SECONDMATE_SYNC: secondmate sm guest: skipped: guest VM is running" \
    "a running stale guest is an actionable SECONDMATE_SYNC line"
  pass "T12 bootstrap surfaces guest staleness instead of stopping silently at the host clone"
}

test_stale_prefix_guest_updates
test_cache_hit_costs_no_sbx_calls
test_uncached_current_verifies_then_caches
test_dirty_guest_skipped
test_diverged_guest_skipped
test_wrong_branch_guest_skipped
test_sweep_skips_running_vm
test_sweep_skips_absent_and_broken
test_resurrect_mode_syncs_running_vm
test_ensure_stack_resurrection_syncs
test_fm_update_reports_guest_outcome
test_bootstrap_classifies_guest_outcomes

echo "all fm-sbx-tracked-sync tests passed"
