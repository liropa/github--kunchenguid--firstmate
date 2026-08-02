#!/usr/bin/env bash
# tests/fm-sbx-gate-vendor.test.sh - the sbx guest cross-vendor gate assertion:
# bin/backends/sbx.sh's fm_backend_sbx_gate_vendor_check, its hard refusal in
# fm_backend_sbx_create_task, its never-blocking re-assert in
# fm_backend_sbx_ensure_stack, and the session-start backstop in
# bin/fm-bootstrap.sh.
#
# The defect this closes ran 26 consecutive gate runs on a live
# firstmate-created guest with claude reviewing claude's own work: the guest
# carried no gate config, no-mistakes wrote its own `agent: auto` default,
# `auto` resolved to claude, nothing errored, and nothing exited non-zero.
#
# The guarantees under test (docs/sbx-backend.md "Guest gate-vendor assertion"):
#   - The vendor is read from the RESOLVED `gate validation` line, so a guest
#     whose config file SAYS codex while its gate resolves to claude is caught.
#   - `no-mistakes doctor`'s exit status is never consulted: it exits 0 even
#     when gate validation reports no runnable agent at all, and that case must
#     not read as a cross-vendor pass.
#   - No arm turns a failure into a pass. A missing gate binary, an unparseable
#     report, and a failed exec each get their own non-zero outcome and their
#     own printed reason.
#   - Failure direction is scaled to blast radius: create REFUSES a proven
#     match and reports an unprovable one, resurrection reports and delivers
#     anyway, and the session-start sweep emits one actionable GATE_VENDOR line
#     while staying silent on a cross-vendor guest.
#   - The sweep never wakes a stopped VM just to re-read the vendor.
set -u

# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the sbx adapter's state probe)"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-sbx-gate-vendor)

# new_gate_world <name> [vm-state]: an sbx world with a fake sbx, a fake
# no-mistakes, a guest-user $HOME carrying a gate root, and a secondmate home.
# Echoes "<world> <fakebin> <nmbin> <guest-user-home>".
new_gate_world() {  # <name> [running|stopped]
  local w fb nmbin guest_user
  w="$TMP_ROOT/$1"
  mkdir -p "$w/signals" "$w/state" "$w/sm/config" "$w/sm/data"
  fb=$(make_fake_sbx "$w"); nmbin=$(make_fake_no_mistakes "$w")
  guest_user="$w/guest-user-home"
  mkdir -p "$guest_user/.no-mistakes"
  : > "$w/sbx.log"
  : > "$w/nm.log"
  sbx_ls_json fm-x "${2:-running}" > "$w/ls.json"
  printf '%s %s %s %s\n' "$w" "$fb" "$nmbin" "$guest_user"
}

# run_check <world> <fakebin> <nmbin> <guest-user-home> <harness> <mode>
# [env k=v...]: drive fm_backend_sbx_gate_vendor_check against fm-x. Echoes its
# outcome line; the caller reads $? for the verdict.
run_check() {
  local w=$1 fb=$2 nmbin=$3 guest_user=$4 harness=$5 mode=$6
  shift 6
  # shellcheck disable=SC2016  # single quotes deliberate: $0/$1.. expand in the inner bash
  PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    FM_FAKE_NM_LOG="$w/nm.log" \
    env "$@" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source sbx; fm_backend_sbx_gate_vendor_check "guest gate" fm-x "$1" "$2"' \
    "$ROOT" "$harness" "$mode" 2>/dev/null
}

# run_create <world> <fakebin> <nmbin> <guest-user-home> [env k=v...]: drive
# fm_backend_sbx_create_task for a claude-driven guest, under `set -e` like
# fm-spawn.sh's own shell. Echoes stdout+stderr; the caller reads $?.
run_create() {
  local w=$1 fb=$2 nmbin=$3 guest_user=$4
  shift 4
  # shellcheck disable=SC2016  # single quotes deliberate: $0/$1.. expand in the inner bash
  PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_CREATE_JSON="$(sbx_ls_json fm-x running)" \
    FM_SBX_SIGNALS_ROOT="$w/signals" \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    env "$@" bash -c 'set -eu; . "$0/bin/fm-backend.sh"; fm_backend_source sbx; fm_backend_sbx_create_task fm-x "$1" claude "$2"' \
    "$ROOT" "$w/sm" "$w/signals/x" 2>&1
}

# --- T1: the reported defect - the gate reviews on the author's vendor -------
test_same_vendor_gate_is_caught() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world same-vendor)"

  # `agent: auto` resolving to claude on a claude-driven guest IS the live
  # 26-of-26 failure, seen at the layer that decides it: the resolved vendor.
  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_NM_GATE=claude) && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "a gate reviewing on the worker's own vendor must return 1 (same vendor), got $rc"
  assert_contains "$out" "guest gate: same vendor: the gate would review on claude" \
    "the outcome line must name the vendor the review would run on"
  pass "T1 a gate that would review with the worker's own vendor is caught, not passed"
}

# --- T2: a genuinely cross-vendor guest passes and says so ------------------
test_cross_vendor_gate_passes() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world cross-vendor)"

  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_NM_GATE=codex) && rc=0 || rc=$?

  [ "$rc" -eq 0 ] || fail "a codex gate reviewing claude's work is the intended shape and must return 0, got $rc"
  assert_contains "$out" "guest gate: cross-vendor ok: gate codex, worker claude" \
    "a passing outcome must still state which vendors it compared"
  pass "T2 an independent reviewer vendor passes with both vendors named"
}

# --- T3: the RESOLVED vendor wins over what the config file claims ----------
test_resolved_vendor_beats_the_config_file() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world resolved-wins)"

  # The exact artifact the investigation rejected as proof: a config that says
  # codex. The gate still resolves to claude, so a check that read the file
  # would clear a claude-reviews-claude guest.
  printf 'agent: codex\n' > "$guest_user/.no-mistakes/config.yaml"

  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_NM_GATE=claude) && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "a config claiming codex must not clear a gate that RESOLVES to claude, got $rc"
  assert_contains "$out" "same vendor" "the resolved vendor, not the config file, decides the verdict"
  pass "T3 the assertion reads the resolved vendor, so a config file cannot vouch for a gate"
}

# --- T4: doctor's exit status is worthless and is never trusted -------------
test_zero_exit_with_unvalidatable_gate_is_not_a_pass() {
  local w fb nmbin guest_user out rc doctor_rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world unrunnable)"

  # Fixture guard: prove the fake reproduces the measured lie before asserting
  # anything about the classifier. If doctor ever stopped exiting 0 here, this
  # test would pass for the wrong reason.
  PATH="$nmbin:$BASE_PATH" HOME="$guest_user" FM_FAKE_NM_GATE=unrunnable \
    no-mistakes doctor >/dev/null 2>&1 && doctor_rc=0 || doctor_rc=$?
  [ "$doctor_rc" -eq 0 ] \
    || fail "fixture: doctor must exit 0 even when gate validation fails (v1.40.2), got $doctor_rc"

  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_NM_GATE=unrunnable) && rc=0 || rc=$?

  [ "$rc" -eq 2 ] || fail "a gate that cannot validate at all is indeterminate, not a pass; got $rc"
  assert_contains "$out" "guest gate: skipped: the guest's gate reported no resolved vendor" \
    "the outcome must name that no vendor was resolved"
  pass "T4 a zero exit with an unvalidatable gate is reported, never counted as cross-vendor"
}

# --- T5: every unreadable shape gets its own non-zero outcome ---------------
test_unreadable_shapes_never_pass() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world unreadable)"

  # (a) doctor prints a report with no gate-validation line at all.
  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_NM_GATE=none) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a report with no gate-validation line must not pass, got $rc"
  assert_contains "$out" "doctor-printed-no-gate-validation-line" "the honest reason rides the outcome line"

  # (b) the guest has no gate binary at all, so there is no vendor to read.
  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_SBX_NM_BIN=/nonexistent) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a guest with no no-mistakes must not pass, got $rc"
  assert_contains "$out" "no no-mistakes on its exec PATH" "a missing gate binary is named as the reason"

  # (c) the exec itself fails - a transport problem, not a verdict.
  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude now FM_FAKE_SBX_DOCTOR_RC=1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a failed probe exec must not pass, got $rc"
  assert_contains "$out" "the guest gate-vendor probe could not be run" "a failed exec is reported as such"

  # (d) no harness recorded - nothing to compare against.
  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" "" now FM_FAKE_NM_GATE=codex) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown worker vendor must not pass, got $rc"
  assert_contains "$out" "no worker harness is recorded" "a missing worker vendor is named"
  pass "T5 every shape that cannot prove the invariant returns non-zero with its own reason"
}

# --- T6: vendor tokens compare on identity, not on spelling -----------------
test_vendor_comparison_normalizes() {
  local w fb nmbin guest_user rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world normalize)"

  # Case differences are spelling, not independence.
  run_check "$w" "$fb" "$nmbin" "$guest_user" codex now FM_FAKE_NM_GATE=Codex >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a differently-cased vendor name is still the same vendor, got $rc"

  # `acp:<target>` is a transport for the same vendor (the wording doctor's own
  # remediation hint uses), so it must not launder a same-vendor review.
  run_check "$w" "$fb" "$nmbin" "$guest_user" codex now FM_FAKE_NM_GATE=acp:codex >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "acp:codex reviewing codex's work is still self-review, got $rc"

  # ...and normalization must not collapse genuinely different vendors.
  run_check "$w" "$fb" "$nmbin" "$guest_user" codex now FM_FAKE_NM_GATE=acp:claude >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "acp:claude reviewing codex's work is cross-vendor, got $rc"
  pass "T6 vendor comparison normalizes case and acp: transport without merging distinct vendors"
}

# --- T7: sweep mode never wakes a stopped guest to re-read the vendor -------
test_sweep_does_not_wake_a_stopped_guest() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world sweep-stopped stopped)"

  out=$(run_check "$w" "$fb" "$nmbin" "$guest_user" claude sweep FM_FAKE_NM_GATE=claude) && rc=0 || rc=$?

  [ "$rc" -eq 2 ] || fail "a stopped guest cannot be read, so sweep mode must report indeterminate, got $rc"
  assert_contains "$out" "guest VM is stopped" "the skip names why, and that the assertion runs again at the next start"
  # `sbx exec` auto-starts a stopped sandbox. Asserting on the log rather than
  # the line is what keeps this honest: a regression that probed anyway would
  # boot every sbx guest on every session start.
  assert_not_contains "$(cat "$w/sbx.log")" "exec" "sweep mode must not exec into a stopped guest"

  # The same guest, running, is read normally.
  sbx_ls_json fm-x running > "$w/ls.json"
  run_check "$w" "$fb" "$nmbin" "$guest_user" claude sweep FM_FAKE_NM_GATE=claude >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "sweep mode must read a RUNNING guest, got $rc"
  pass "T7 sweep mode reads a running guest and never boots a stopped one"
}

# --- T8: create hard-refuses before the guest stack exists ------------------
test_create_refuses_same_vendor_guest() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world create-refuse)"
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"

  out=$(run_create "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_NM_GATE=claude) && rc=0 || rc=$?

  [ "$rc" -ne 0 ] || fail "create must refuse a guest whose gate would review with the worker's own vendor"
  assert_contains "$out" "refusing to finish creating fm-x" "the refusal must say what it refused and why"
  assert_contains "$out" "FM_SBX_TEMPLATE" "the refusal must be actionable, not just a verdict"
  # Half-provisioned is worse than no sandbox: the guest stack must not come up.
  assert_not_contains "$(cat "$w/sbx.log")" "tmux new-session" \
    "a refused create must not leave a running guest stack behind"
  pass "T8 create refuses a same-vendor guest before its stack is started"
}

test_create_proceeds_on_cross_vendor_guest() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world create-ok)"
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"

  out=$(run_create "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_NM_GATE=codex) && rc=0 || rc=$?

  [ "$rc" -eq 0 ] || fail "a cross-vendor guest must create normally, got $rc"
  assert_contains "$(cat "$w/sbx.log")" "tmux new-session" "a passing create still brings the guest stack up"
  assert_not_contains "$out" "firstmate sbx:" "a proven cross-vendor create says nothing extra"
  pass "T9 a cross-vendor guest creates normally"
}

# --- T9b: an UNPROVABLE gate is loud at create, but never fatal -------------
#
# The refusal is scoped to a proven match. Refusing here instead would make
# firstmate an enforcer of what the guest image ships - the other half of this
# split, and not firstmate's to own - and would refuse guests that carry no
# gate at all, which have no gate that could review on the wrong vendor. It is
# still never swallowed: the reason is printed, and resurrection plus the
# session-start sweep re-assert, so a guest that later gains a gate is caught.
test_create_reports_but_allows_unprovable_gate() {
  local w fb nmbin guest_user out rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world create-unprovable)"
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"

  out=$(run_create "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_SBX_NM_BIN=/nonexistent) && rc=0 || rc=$?

  [ "$rc" -eq 0 ] || fail "a guest with no gate at all has no same-vendor risk and must still create, got $rc"
  assert_contains "$out" "no no-mistakes on its exec PATH" "the unprovable reason must be printed, never swallowed"
  assert_contains "$out" "nothing here proved its gate would review on a different vendor" \
    "the operator must be told the assertion did not apply, not left to assume it passed"
  pass "T9b an unprovable gate is reported loudly at create without blocking the sandbox"
}

# --- T10: resurrection reports the drift but never strands the secondmate ---
test_resurrection_reports_without_blocking() {
  local w fb nmbin guest_user err rc
  read -r w fb nmbin guest_user <<<"$(new_gate_world resurrect)"
  printf 'running\n' > "$w/nm.state"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$w/sm" "project=$w/sm" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$w/sm" "sbx_signals_dir=$w/signals/x"

  # No guest tmux server forces the rebuild path, which is where the re-assert
  # sits. A hard refusal here would strand a live secondmate mid-task, so the
  # test asserts BOTH that the drift was reported and that delivery survived.
  # shellcheck disable=SC2016  # single quotes deliberate: $0 expands in the inner bash
  err=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" FM_STATE_OVERRIDE="$w/state" \
    FM_FAKE_SBX_TMUX_HAS_RC=1 FM_FAKE_SBX_FG=codex \
    FM_SBX_RESURRECT_SETTLE=0 FM_SBX_RESURRECT_READY_TRIES=0 FM_SBX_KEEPALIVE_MAX=0 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    FM_FAKE_NM_STATE_FILE="$w/nm.state" FM_FAKE_NM_LOG="$w/nm.log" \
    FM_FAKE_NM_GATE=codex \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source sbx; fm_backend_sbx_ensure_stack sbx:fm-x' \
    "$ROOT" 2>&1) && rc=0 || rc=$?

  [ "$rc" -eq 0 ] || fail "resurrection must not be blocked by a same-vendor gate: $err"
  assert_contains "$err" "sandbox fm-x guest gate: same vendor" \
    "resurrection must still report the drift as a supervisor-actionable line"
  assert_contains "$(cat "$w/sbx.log")" "tmux new-session" \
    "resurrection must still rebuild the guest stack after reporting"
  pass "T10 resurrection reports a same-vendor gate and delivers anyway"
}

# --- T11: the session-start sweep is the backstop, and stays quiet when ok --
test_bootstrap_sweep_classifies() {
  local w fb nmbin guest_user out
  read -r w fb nmbin guest_user <<<"$(new_gate_world bootstrap)"
  mkdir -p "$w/home/state" "$w/home/data" "$w/signals/x"
  touch "$w/home/state/.last-watcher-beat"
  git init -q -b main "$w/sm"
  printf 'v1\n' > "$w/sm/AGENTS.md"
  mkdir -p "$w/sm/bin"
  printf 'echo a\n' > "$w/sm/bin/tool.sh"
  git -C "$w/sm" add -A
  git -C "$w/sm" commit -qm c1
  printf 'x\n' > "$w/sm/.fm-secondmate-home"
  {
    printf 'window=sbx:fm-x\n'
    printf 'kind=secondmate\n'
    printf 'backend=sbx\n'
    printf 'harness=claude\n'
    printf 'home=%s\n' "$w/sm"
    printf 'sbx_signals_dir=%s\n' "$w/signals/x"
  } > "$w/home/state/x.meta"

  # (a) a guest whose gate would review on the author's vendor: one actionable
  # line, from a sweep that needs no resurrection to find it. The live guest
  # ran 26 same-vendor reviews across 26 hours without resurrecting once.
  out=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" FM_HOME="$w/home" FM_SEND_SETTLE=0 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    FM_FAKE_NM_GATE=claude \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "GATE_VENDOR: secondmate x guest: same vendor: the gate would review on claude" \
    "a same-vendor guest must surface as one actionable GATE_VENDOR line at session start"

  # (b) the same guest with an independent reviewer: routine silence.
  out=$(PATH="$fb:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" FM_HOME="$w/home" FM_SEND_SETTLE=0 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    FM_FAKE_NM_GATE=codex \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_not_contains "$out" "GATE_VENDOR:" "a cross-vendor guest is routine silence, not a diagnostic"
  pass "T11 the session-start sweep surfaces a same-vendor guest and stays quiet on a healthy one"
}

test_same_vendor_gate_is_caught
test_cross_vendor_gate_passes
test_resolved_vendor_beats_the_config_file
test_zero_exit_with_unvalidatable_gate_is_not_a_pass
test_unreadable_shapes_never_pass
test_vendor_comparison_normalizes
test_sweep_does_not_wake_a_stopped_guest
test_create_refuses_same_vendor_guest
test_create_proceeds_on_cross_vendor_guest
test_create_reports_but_allows_unprovable_gate
test_resurrection_reports_without_blocking
test_bootstrap_sweep_classifies

echo "all fm-sbx-gate-vendor tests passed"
