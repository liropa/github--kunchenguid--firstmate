#!/usr/bin/env bash
# Behavior tests for primary-authoritative shared captain-preference inheritance.
#
# The narrow shared surface is exactly data/captain-shared.md.
# data/captain.md and data/learnings.md remain domain-local in every home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-shared-captain)

fm_git_identity fmtest fmtest@example.invalid

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

shared_header() {
  cat <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
EOF
}

write_shared() {
  local path=$1 body=$2
  shared_header > "$path"
  printf '%s\n' "$body" >> "$path"
}

new_home_pair() {
  local name=$1 base primary second
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  second="$base/second"
  mkdir -p "$primary/data" "$primary/config" "$second/data" "$second/config"
  printf '%s\n' "primary local captain" > "$primary/data/captain.md"
  printf '%s\n' "second local captain" > "$second/data/captain.md"
  printf '%s\n' "primary local learning" > "$primary/data/learnings.md"
  printf '%s\n' "second local learning" > "$second/data/learnings.md"
  printf '%s\n' "$primary|$second"
}

assert_shared_readonly() {
  local path=$1
  [ "$(file_mode "$path")" = "$FM_SHARED_CAPTAIN_MODE" ] \
    || fail "$path mode should be $FM_SHARED_CAPTAIN_MODE, got $(file_mode "$path")"
}

assert_secondmate_write_fails() {
  local path=$1
  if ( printf '%s\n' "secondmate edit" >> "$path" ) 2>/dev/null; then
    fail "ordinary write unexpectedly succeeded for read-only shared captain file"
  fi
}

test_first_copy_readonly_and_local_files_preserved() {
  local rec primary second report out
  rec=$(new_home_pair first-copy)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/captain-shared.md" "shared v1"
  report="$TMP_ROOT/first-copy.report"

  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")

  [ -z "$out" ] || fail "first copy should not emit a quarantine diagnostic: $out"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "first copy did not converge secondmate shared preferences"
  assert_shared_readonly "$second/data/captain-shared.md"
  assert_secondmate_write_fails "$second/data/captain-shared.md"
  assert_grep $'data/captain-shared.md\tpushed\t' "$report" "first copy should report pushed"
  assert_grep "second local captain" "$second/data/captain.md" "domain-local captain.md was changed"
  assert_grep "second local learning" "$second/data/learnings.md" "domain-local learnings.md was changed"

  : > "$report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "unchanged convergence should stay quiet: $out"
  assert_grep $'data/captain-shared.md\tunchanged\t' "$report" "unchanged bytes should report unchanged"
  assert_shared_readonly "$second/data/captain-shared.md"
  pass "shared captain first copy converges, is read-only, and preserves local captain/learnings files"
}

test_drift_quarantine_collision_and_repeated_convergence() {
  local rec primary second fakebin hash collision report out diag qpath qcount
  rec=$(new_home_pair drift)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/captain-shared.md" "shared v2"
  write_shared "$second/data/captain-shared.md" "local drift"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"
  hash=$(fm_inherit_sha256 "$second/data/captain-shared.md")
  collision="$second/data/.captain-shared.md.quarantine.20260102T030405Z.$hash"
  printf '%s\n' "preexisting different artifact" > "$collision"
  chmod 0600 "$collision"

  fakebin="$TMP_ROOT/fake-date"
  mkdir -p "$fakebin"
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 20260102T030405Z
SH
  chmod +x "$fakebin/date"
  report="$TMP_ROOT/drift.report"

  out=$(PATH="$fakebin:$BASE_PATH" FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_secondmate_inheritance "$primary" "$second")

  diag=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate home ' || true)
  [ -n "$diag" ] || fail "drift quarantine should emit a SECONDMATE_SYNC diagnostic"
  qpath=${diag##* at }
  [ "$qpath" = "$collision.1" ] || fail "collision-safe quarantine name should use .1, got $qpath"
  assert_grep "local drift" "$qpath" "quarantine artifact lost the secondmate-local bytes"
  assert_grep $'data/captain-shared.md\tpushed\tquarantined local drift at '"$qpath" "$report" \
    "drift push should name the quarantine artifact in the report"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "drift convergence did not install primary bytes"
  assert_shared_readonly "$second/data/captain-shared.md"

  : > "$report"
  out=$(PATH="$fakebin:$BASE_PATH" FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "repeated convergence should not quarantine again: $out"
  qcount=$(find "$second/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 2 ] || fail "repeated convergence created extra quarantine artifacts"
  assert_grep $'data/captain-shared.md\tunchanged\t' "$report" "repeated convergence should report unchanged"
  pass "shared captain drift is quarantined collision-safely and repeated convergence is idempotent"
}

test_missing_source_mirrors_absence_without_losing_local_bytes() {
  local rec primary second out diag qpath
  rec=$(new_home_pair missing-source)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$second/data/captain-shared.md" "orphaned local shared file"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"

  out=$(propagate_secondmate_inheritance "$primary" "$second")

  diag=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate home ' || true)
  [ -n "$diag" ] || fail "primary absence with a local copy should quarantine before removal"
  qpath=${diag##* at }
  assert_absent "$second/data/captain-shared.md" "primary absence should converge destination to absence"
  assert_grep "orphaned local shared file" "$qpath" "missing-source quarantine lost local bytes"
  assert_grep "second local captain" "$second/data/captain.md" "missing-source changed local captain.md"
  assert_grep "second local learning" "$second/data/learnings.md" "missing-source changed local learnings.md"
  pass "missing primary shared file mirrors absence only after quarantining a local copy"
}

test_unsafe_artifacts_and_failure_restore_readonly_mode() {
  local rec primary second other err before_mode rc
  rec=$(new_home_pair unsafe)
  primary=${rec%%|*}
  second=${rec#*|}

  ln -s "$primary/data/captain.md" "$primary/data/captain-shared.md"
  err="$TMP_ROOT/unsafe-source.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked primary source should be rejected"
  assert_grep "unsafe primary source" "$err" "unsafe source error should be explicit"
  rm -f "$primary/data/captain-shared.md"
  write_shared "$primary/data/captain-shared.md" "safe source"

  ln -s "$second/data/captain.md" "$second/data/captain-shared.md"
  err="$TMP_ROOT/unsafe-dest-symlink.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked destination should be rejected"
  assert_grep "unsafe destination" "$err" "unsafe destination symlink error should be explicit"
  rm -f "$second/data/captain-shared.md"

  write_shared "$second/data/captain-shared.md" "hardlinked local drift"
  other="$second/data/hardlink-copy"
  ln "$second/data/captain-shared.md" "$other"
  err="$TMP_ROOT/unsafe-dest-hardlink.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked destination should be rejected"
  assert_grep "unsafe destination" "$err" "unsafe destination hardlink error should be explicit"
  rm -f "$second/data/captain-shared.md" "$other"

  write_shared "$second/data/captain-shared.md" "permission drift"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"
  before_mode=$(file_mode "$second/data/captain-shared.md")
  chmod 500 "$second/data"
  err="$TMP_ROOT/restore-readonly.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  chmod 700 "$second/data"
  [ "$rc" -ne 0 ] || fail "unwritable destination directory should make quarantine fail"
  [ "$(file_mode "$second/data/captain-shared.md")" = "$before_mode" ] \
    || fail "failed quarantine did not restore read-only mode"
  assert_grep "failed to quarantine divergent destination" "$err" \
    "recoverable failure should explain quarantine failure"
  pass "unsafe shared captain artifacts are rejected and failure restores read-only mode"
}

make_fake_spawn_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

new_git_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  {
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'data/'
    printf '%s\n' 'state/'
    printf '%s\n' 'config/'
    printf '%s\n' 'projects/'
  } > "$root/.gitignore"
  printf '%s\n' "instructions" > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' "echo spawn" > "$root/bin/fm-spawn.sh"
  printf '%s\n' "skill" > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/sm" "$c1"
  printf '%s\n' sm > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf '%s\n' "charter" > "$w/sm/data/charter.md"
  write_shared "$home/data/captain-shared.md" "shared from primary"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/sm"
}

test_spawn_convergence_point_copies_shared_file() {
  local rec w root home sm fakebin data_override
  rec=$(new_git_world spawn-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  write_shared "$data_override/captain-shared.md" "shared from override"
  fakebin=$(make_fake_spawn_toolchain "$w")

  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data_override" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$sm" codex --secondmate >/dev/null 2>&1 || true

  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "spawn convergence point did not copy shared captain preferences from FM_DATA_OVERRIDE"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "spawn convergence point propagates data/captain-shared.md from FM_DATA_OVERRIDE"
}

test_bootstrap_convergence_point_copies_shared_file() {
  local rec w root home sm fakebin data_override out
  rec=$(new_git_world bootstrap-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  write_shared "$data_override/captain-shared.md" "shared from bootstrap override"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
  } > "$home/state/sm.meta"
  printf -- '- sm - fixture secondmate (home: %s; scope: fixture; projects: sample; added 2026-07-16)\n' "$sm" \
    > "$data_override/secondmates.md"
  fakebin=$(make_fake_spawn_toolchain "$w")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi gh treehouse no-mistakes tasks-axi quota-axi

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_not_contains "$out" "SECONDMATE_SYNC: secondmate sm: skipped: inheritance failed" \
    "bootstrap inheritance should succeed"
  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "bootstrap convergence point did not copy shared captain preferences from FM_DATA_OVERRIDE"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "bootstrap convergence point propagates data/captain-shared.md from FM_DATA_OVERRIDE"
}

test_config_push_convergence_point_updates_changed_source() {
  local rec w root home sm data_override out
  rec=$(new_git_world config-push-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  write_shared "$sm/data/captain-shared.md" "old shared bytes"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$sm/data/captain-shared.md"
  write_shared "$data_override/captain-shared.md" "changed override shared bytes"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/fm-config-push.sh" 2>/dev/null)

  assert_contains "$out" "data/captain-shared.md: pushed - quarantined local drift at" \
    "config-push should report the shared file update and quarantine"
  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "config-push convergence point did not update shared captain preferences from FM_DATA_OVERRIDE"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "fm-config-push convergence point updates changed shared captain source bytes from FM_DATA_OVERRIDE"
}

test_session_start_digest_labels_shared_file_and_read_once_rule() {
  local rec w root home _sm fakebin out
  rec=$(new_git_world session-start-label)
  IFS='|' read -r w root home _sm <<EOF
$rec
EOF
  fakebin=$(make_fake_spawn_toolchain "$w")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi gh treehouse no-mistakes tasks-axi quota-axi pgrep

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-session-start.sh")

  assert_contains "$out" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)" \
    "session-start digest should label the shared captain file unmistakably"
  assert_contains "$out" "shared from primary" "session-start digest should render the shared file"
  assert_contains "$out" "data/captain-shared.md, data/learnings.md" \
    "read-once reminder should include captain-shared.md"
  pass "session-start digest renders data/captain-shared.md with the shared read-only label"
}

# --- sbx guest read-through -------------------------------------------------
#
# An sbx secondmate's guest home does NOT receive a second copy: the host home
# gets the copy above, and the guest reaches it through a symlink onto clone
# mode's RO source mount (docs/sbx-backend.md "Guest-home provisioning"). The
# host home and the guest clone sit at the SAME absolute path on different
# disks, which is what FM_FAKE_SBX_GUEST_HOME models, and FM_SBX_SOURCE_MOUNT
# points the fixture at a directory standing in for the mount - so a mount that
# does not carry what the host home has is expressible, which is the whole
# point: that shape was measured live on 2026-07-23 and is why the read path is
# an inheritance channel rather than a delivery one.

# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

# new_sbx_readthrough_world <name> <mount-has-file> <host-has-file> [mount-bytes]:
# a fixture host home, guest clone, and stand-in source mount. Echoes
# "host|guest|mount".
new_sbx_readthrough_world() {  # <name> <mount-has-file> <host-has-file> [mount-bytes]
  local name=$1 mount_has=$2 host_has=$3 mount_bytes=${4:-shared from primary} w host guest mount
  w="$TMP_ROOT/$name"
  host="$w/sm"; guest="$w/guest-clone"; mount="$w/source-mount"
  mkdir -p "$host/data" "$host/config" "$guest" "$mount/data" "$mount/config"
  [ "$host_has" = yes ] && write_shared "$host/data/captain-shared.md" "shared from primary"
  [ "$mount_has" = yes ] && write_shared "$mount/data/captain-shared.md" "$mount_bytes"
  printf '%s|%s|%s\n' "$host" "$guest" "$mount"
}

# run_provision <world-dir> <host> <guest> <mount>: run the real provisioning
# pass against the fixture. Echoes stderr; returns the pass's own rc.
run_provision() {  # <world-dir> <host> <guest> <mount>
  local w=$1 host=$2 guest=$3 mount=$4 fakebin
  fakebin=$(make_fake_sbx "$w")
  # Only the pass's stderr is the subject here; its stdout is noise.
  # shellcheck disable=SC2016  # single quotes deliberate: $0 expands in the inner bash
  { PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_GUEST_HOME="$guest" \
    FM_FAKE_SBX_GUEST_USER_HOME="$w/guest-user-home" \
    FM_SBX_SOURCE_MOUNT="$mount" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source sbx; fm_backend_sbx_provision_guest_home fm-x "$1" x "$2"' \
    "$ROOT" "$host" "$w/signals/x" >/dev/null; } 2>&1
}

test_sbx_guest_link_is_the_absence_convergence_when_primary_never_published() {
  local rec host guest mount err rc
  rec=$(new_sbx_readthrough_world sbx-absent no no)
  IFS='|' read -r host guest mount <<EOF
$rec
EOF

  err=$(run_provision "$TMP_ROOT/sbx-absent" "$host" "$guest" "$mount"); rc=$?

  [ "$rc" = 0 ] || fail "provisioning should succeed with no shared file anywhere, got rc $rc"
  [ -L "$guest/data/captain-shared.md" ] \
    || fail "the guest read path must be a symlink even with nothing to read"
  [ "$(readlink "$guest/data/captain-shared.md")" = "$mount/data/captain-shared.md" ] \
    || fail "the guest link must point at the source mount"
  [ ! -f "$guest/data/captain-shared.md" ] \
    || fail "a dangling link must read as absent, the way the session digest's [ -f ] test does"
  [ -z "$err" ] || fail "a designed absence must stay silent, got: $err"
  pass "sbx guest: an unpublished shared file leaves a dangling link that reads ABSENT, silently"
}

test_sbx_guest_reads_a_published_shared_file_through_the_mount() {
  local rec host guest mount err rc
  rec=$(new_sbx_readthrough_world sbx-published yes yes)
  IFS='|' read -r host guest mount <<EOF
$rec
EOF

  err=$(run_provision "$TMP_ROOT/sbx-published" "$host" "$guest" "$mount"); rc=$?

  [ "$rc" = 0 ] || fail "provisioning should succeed when the read path resolves, got rc $rc"
  [ -f "$guest/data/captain-shared.md" ] \
    || fail "a mount carrying the file must make the guest link resolve"
  cmp -s "$mount/data/captain-shared.md" "$guest/data/captain-shared.md" \
    || fail "the guest must read the mount's bytes, not a copy of its own"
  [ -z "$err" ] || fail "a working read path must stay silent, got: $err"
  pass "sbx guest: a published shared file is read through the link, with no second copy"
}

test_sbx_guest_reports_a_published_shared_file_the_mount_does_not_carry() {
  local rec host guest mount err rc
  # The measured 2026-07-23 shape: the host home has the file, the mount does
  # not carry it. Re-asserting the link cannot fix this, so the pass says so.
  rec=$(new_sbx_readthrough_world sbx-stale no yes)
  IFS='|' read -r host guest mount <<EOF
$rec
EOF

  err=$(run_provision "$TMP_ROOT/sbx-stale" "$host" "$guest" "$mount"); rc=$?

  [ "$rc" = 0 ] || fail "an unreadable shared file must warn, never fail the spawn or the steer"
  [ -L "$guest/data/captain-shared.md" ] || fail "the link must still be asserted"
  assert_contains "$err" "cannot read data/captain-shared.md through its guest link" \
    "the warning must name the file the guest cannot read"
  assert_contains "$err" "$mount" "the warning must name the mount that is not carrying it"
  pass "sbx guest: a published shared file the mount does not carry is reported, not silently absent"
}

test_sbx_guest_reports_still_reading_a_shared_file_the_primary_cleared() {
  local rec host guest mount err rc
  # The opposite direction, same cause: the primary cleared the file and the
  # host home mirrored that absence, but the mount still carries the old bytes.
  rec=$(new_sbx_readthrough_world sbx-retracted yes no)
  IFS='|' read -r host guest mount <<EOF
$rec
EOF

  err=$(run_provision "$TMP_ROOT/sbx-retracted" "$host" "$guest" "$mount"); rc=$?

  [ "$rc" = 0 ] || fail "a retracted-but-readable shared file must warn, never fail"
  assert_contains "$err" "still reads data/captain-shared.md through its guest link" \
    "the warning must say the guest is acting on retracted preferences"
  pass "sbx guest: still reading a shared file the primary cleared is reported"
}

test_sbx_guest_reports_outdated_shared_bytes_in_the_mount() {
  local rec host guest mount err rc
  rec=$(new_sbx_readthrough_world sbx-outdated yes yes "superseded shared preferences")
  IFS='|' read -r host guest mount <<EOF
$rec
EOF

  err=$(run_provision "$TMP_ROOT/sbx-outdated" "$host" "$guest" "$mount"); rc=$?

  [ "$rc" = 0 ] || fail "outdated shared bytes must warn, never fail"
  assert_contains "$err" "outdated data/captain-shared.md through its guest link" \
    "the warning must name the outdated file the guest reads"
  pass "sbx guest: outdated shared bytes in the mount are reported"
}

test_sbx_provisioning_sends_no_empty_guest_argument() {
  local rec host guest mount err rc
  # The 2026-08-08 outage: with no shared captain file published, the host had
  # no hash to send, sent "" for it, and sbx refused the whole exec with
  # `400 Bad Request: cmd element 10 is empty` - so EVERY resurrection of a
  # secondmate without the file failed, and absent is the default state.
  # Absent-everywhere is deliberately the fixture, because that is the shape
  # that broke. tests/sbx-helpers.sh refuses an empty element on every exec,
  # so a regression fails the run; this case additionally pins the vector so
  # the failure names the cause instead of only the symptom.
  rec=$(new_sbx_readthrough_world sbx-no-empty-arg no no)
  IFS='|' read -r host guest mount <<EOF
$rec
EOF

  err=$(run_provision "$TMP_ROOT/sbx-no-empty-arg" "$host" "$guest" "$mount"); rc=$?

  # rc 0 IS the empty-element assertion: tests/sbx-helpers.sh refuses any exec
  # whose vector carries one, so this fails the moment the regression returns.
  # It cannot be asserted from the log, because the log joins the vector with
  # spaces and an empty element leaves no trace there - which is exactly how
  # the old `$sig 0  crew-dispatch.json` assertion passed over the defect.
  [ "$rc" = 0 ] \
    || fail "provisioning with no shared captain file must succeed, got rc $rc: $err"
  assert_grep "data/captain-shared.md $TMP_ROOT/sbx-no-empty-arg/signals/x 0 -" \
    "$TMP_ROOT/sbx-no-empty-arg/sbx.log" \
    "no published file should send want=0 plus the no-value token, never an empty element"
  pass "sbx guest: provisioning with no shared captain file sends no empty guest argument"
}

test_first_copy_readonly_and_local_files_preserved
test_drift_quarantine_collision_and_repeated_convergence
test_missing_source_mirrors_absence_without_losing_local_bytes
test_unsafe_artifacts_and_failure_restore_readonly_mode
test_spawn_convergence_point_copies_shared_file
test_bootstrap_convergence_point_copies_shared_file
test_config_push_convergence_point_updates_changed_source
test_session_start_digest_labels_shared_file_and_read_once_rule
test_sbx_guest_link_is_the_absence_convergence_when_primary_never_published
test_sbx_guest_reads_a_published_shared_file_through_the_mount
test_sbx_guest_reports_a_published_shared_file_the_mount_does_not_carry
test_sbx_guest_reports_outdated_shared_bytes_in_the_mount
test_sbx_guest_reports_still_reading_a_shared_file_the_primary_cleared
test_sbx_provisioning_sends_no_empty_guest_argument

echo "# all fm-shared-captain-inheritance tests passed"
