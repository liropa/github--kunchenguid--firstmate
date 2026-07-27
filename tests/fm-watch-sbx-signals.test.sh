#!/usr/bin/env bash
# tests/fm-watch-sbx-signals.test.sh - the sbx signal bridge's consumer half:
# bin/fm-watch.sh's scan_signals running UNCHANGED over the state/<id>.status
# and state/<id>.turn-ended symlinks that fm-spawn.sh's sbx branch points at
# the bind-mounted signal directory (agent-dotfiles design doc
# firstmate-sbx-secondmate-event-bridge.md §5, §12; docs/sbx-backend.md).
#
# The guarantees under test:
#   - A guest write landing in the mount file is picked up through the
#     state/ symlink and surfaced exactly like a native status write - no
#     watcher edits, no new transport.
#   - A DANGLING symlink (mount unavailable, sandbox gone) is quiescent: the
#     watcher skips it without crashing, exiting, or enqueuing anything -
#     liveness, not the scan, is the authority on dead-vs-idle.
#   - The symlink set is the id allowlist: a file a guest invents for ANOTHER
#     id inside its mount directory is invisible to the scan (no symlink ->
#     no wake), so a compromised guest cannot signal as a different crew.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# Consumed by wake-helpers.sh's make_case (which builds each case under it),
# so it reads as "unused" here - the same pattern as lib.sh's ROOT.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-watch-sbx-signals)

WATCH="$ROOT/bin/fm-watch.sh"

watch_bg() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

wait_live() {  # <pid> [ticks]
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

test_mount_write_surfaces_through_symlink() {
  local dir state mount out pid
  dir=$(make_case symlink-pickup); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  # Wire the symlinks exactly as fm-spawn.sh's sbx branch does; the mount
  # files do not exist yet (a freshly provisioned secondmate that has not
  # signaled), so both start DANGLING.
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  # A couple of polls over the dangling symlinks: quiescent, not dead.
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher crashed or surfaced on dangling signal symlinks: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "dangling symlinks enqueued a wake"; }

  # The guest's status append lands in the MOUNT file; the scan must surface
  # it through the state/ symlink like any native captain-relevant write.
  printf 'needs-decision: merge order for the two PRs?\n' >> "$mount/x.status"
  wait_for_exit "$pid" 40 || fail "watcher did not surface a captain-relevant mount write through the symlink"
  grep -F "signal: $state/x.status" "$out" >/dev/null \
    || fail "the surfaced wake should reference the scanned state/ path: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "the surfaced mount write should have enqueued a durable wake"

  pass "a guest mount write surfaces through the state/ symlink; dangling symlinks stay quiescent"
}

test_second_mount_write_surfaces_again() {
  # The regression that motivated stat -L (fm-watch.sh): BSD stat without -L
  # signs the SYMLINK itself - target-path length as size, spawn time as
  # mtime, both immutable - so the first surfaced wake froze the .seen
  # marker at that signature forever and every later guest write was
  # invisible on macOS (found live: a resumed secondmate's done: line never
  # woke the watcher). A second append through the same symlink must fire a
  # second wake.
  local dir state mount out pid
  dir=$(make_case second-write); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  printf 'needs-decision: first write\n' >> "$mount/x.status"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the first mount write"

  printf 'needs-decision: second write\n' >> "$mount/x.status"
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 \
    || fail "watcher did not surface a SECOND write through the symlink - the .seen signature must track the TARGET file, not the link"
  grep -F "signal: $state/x.status" "$out" >/dev/null \
    || fail "the second wake should reference the scanned state/ path: $(cat "$out")"

  pass "a second mount write through the same symlink surfaces again (signatures follow the target)"
}

test_foreign_id_file_is_invisible() {
  local dir state mount out pid
  dir=$(make_case foreign-id); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"

  # A (compromised) guest invents ANOTHER id's signal file inside its own
  # mount directory. The host never symlinked that name, so the scan must not
  # see it - the symlink set is the authorization boundary.
  printf 'done: PR https://example.invalid/pr/1 checks green\n' > "$mount/other.status"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "watcher surfaced a foreign-id mount file that was never symlinked: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a foreign-id mount file enqueued a wake"; }
  reap "$pid"
  pass "a foreign-id file inside the mount is invisible to the scan (no symlink -> no wake)"
}

test_mount_vanished_fires_mount_alarm() {
  # The beat-beacon's mount-health consumer (design doc open question 6;
  # docs/sbx-backend.md "Beat-beacon alarms"): scan_signals' [ -e ] skip stays
  # quiet on a vanished mount, so scan_sbx_beacon must name the outage.
  # A dangling symlink whose target DIRECTORY exists is a fresh spawn
  # (quiescent, tested above); a dangling symlink whose target directory is
  # GONE is a vanished mount and must raise one check wake.
  local dir state mount out pid
  dir=$(make_case mount-vanished); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  # Mount dir present, files not yet written: healthy fresh spawn, no alarm.
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited on a healthy fresh-spawn mount: $(cat "$out")"; }

  rmdir "$mount"
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on a vanished signal mount"
  grep -F "sbx signal mount missing for x" "$out" >/dev/null \
    || fail "the mount alarm should name the id and the missing mount: $(cat "$out")"
  grep -F "sbx-mount:x" "$state/.wake-queue" >/dev/null \
    || fail "the mount alarm should enqueue a durable check wake keyed sbx-mount:x: $(cat "$state/.wake-queue" 2>/dev/null)"

  pass "a vanished mount directory raises a captain-facing check wake"
}

test_mount_alarm_fires_once_and_rearms() {
  # One check wake per outage: a watcher restart while the mount is still gone
  # must NOT re-alarm (the captain already knows), and the mount returning
  # re-arms the alarm so a SECOND outage alarms again.
  local dir state mount out pid
  dir=$(make_case mount-alarm-rearm); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  rmdir "$mount"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on the first outage"

  # Still gone: a restarted watcher stays quiet - no repeat alarm.
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher re-alarmed on an already-alarmed outage: $(cat "$out")"; }
  reap "$pid"
  [ "$(grep -c "sbx-mount:x" "$state/.wake-queue")" = 1 ] \
    || fail "a persisting outage should hold at ONE queued mount alarm: $(cat "$state/.wake-queue")"

  # Mount returns: the alarm re-arms; a second outage alarms again.
  mkdir -p "$mount"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  i=0
  while [ -e "$state/.sbx-mount-alarmed-x" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ ! -e "$state/.sbx-mount-alarmed-x" ] || { reap "$pid"; fail "the restored mount should clear the alarmed marker"; }
  rmdir "$mount"
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on a second outage after the mount had returned"
  [ "$(grep -c "sbx-mount:x" "$state/.wake-queue")" = 2 ] \
    || fail "the second outage should enqueue a SECOND mount alarm: $(cat "$state/.wake-queue")"

  pass "the mount alarm fires once per outage and re-arms when the mount returns"
}

test_no_progress_turns_fire_stranding_alarm() {
  # The beat-beacon's second consumer: a stranded guest TUI (observed live: an
  # auth-dead claude after a host OAuth rotation) keeps firing its turn-end
  # hook on every steer while the status file never progresses. Each bare
  # turn-end surfaces as a generic signal wake, but nothing NAMES the pattern.
  # After FM_SBX_NOPROGRESS_TURNS consecutive turn-ends with zero status
  # progress the beacon must raise one named check wake.
  local dir state mount out pid i
  dir=$(make_case stranded); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  # Three steers of a stranded guest: turn-ended advances, status never does.
  # Each turn-end is itself an actionable signal wake (the watcher exits), so
  # the no-progress counter must persist across watcher runs.
  for i in 1 2 3; do
    printf 't%s\n' "$i" >> "$mount/x.turn-ended"
    : > "$out"
    watch_bg "$state" "$dir/fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not exit on stranded turn-end $i: $(cat "$out")"
  done
  grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "3 consecutive no-progress turn-ends should enqueue a named stranding check wake: $(cat "$state/.wake-queue")"
  grep -F "no status progress" "$state/.wake-queue" >/dev/null \
    || fail "the stranding alarm should describe the no-progress pattern: $(cat "$state/.wake-queue")"

  pass "consecutive no-progress turn-ends raise a named stranding alarm"
}

test_status_progress_resets_stranding_counter() {
  # A healthy secondmate writes status every turn; that progress must reset
  # the no-progress counter so ordinary supervision NEVER trips the alarm,
  # and a post-alarm status write re-arms the alarm for the next episode.
  local dir state mount out pid i
  dir=$(make_case healthy-turns); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  # Four healthy turns: a captain-relevant status write + the same turn's
  # turn-end, coalesced by the grace into one wake per turn.
  for i in 1 2 3 4; do
    printf 'needs-decision: turn %s\n' "$i" >> "$mount/x.status"
    printf 't%s\n' "$i" >> "$mount/x.turn-ended"
    : > "$out"
    watch_bg "$state" "$dir/fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not surface healthy turn $i: $(cat "$out")"
  done
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "healthy turns (status progress every turn) must never trip the stranding alarm: $(cat "$state/.wake-queue")"

  pass "status progress resets the no-progress counter; healthy turns never alarm"
}

test_midtask_stop_marker_fires_named_alarm() {
  # The mid-task-stop consumer (fork issue #12): the keep-alive wrapper
  # (bin/backends/sbx.sh) records state/.sbx-midtask-stop-<id> when the VM
  # stopped while in-guest work was active. A stopped VM fires no turn-ends,
  # so the stranding counter is structurally blind to this failure - the
  # beacon must surface the marker as ONE named check wake and consume it.
  local dir state mount out pid
  dir=$(make_case midtask-stop); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  printf 'the keep-alive cap (60s) expired while in-guest work was still active\n' \
    > "$state/.sbx-midtask-stop-x"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on a mid-task-stop marker: $(cat "$out")"
  grep -F "sbx-midtask-stop:x" "$state/.wake-queue" >/dev/null \
    || fail "the mid-task stop should enqueue a named check wake keyed sbx-midtask-stop:x: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F "stopped mid-task" "$state/.wake-queue" >/dev/null \
    || fail "the alarm should name the mid-task stop pattern: $(cat "$state/.wake-queue")"
  grep -F "expired while in-guest work" "$state/.wake-queue" >/dev/null \
    || fail "the alarm should carry the wrapper's recorded reason: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.sbx-midtask-stop-x" ] || fail "the surfaced marker should be consumed"

  # Marker consumed: a restarted watcher must not re-alarm.
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher re-alarmed on an already-surfaced mid-task stop: $(cat "$out")"; }
  reap "$pid"
  [ "$(grep -c "sbx-midtask-stop:x" "$state/.wake-queue")" = 1 ] \
    || fail "one mid-task stop should hold at ONE queued alarm: $(cat "$state/.wake-queue")"

  pass "a mid-task-stop marker raises one named check wake and is consumed"
}

test_inguest_activity_suppresses_stranding() {
  # Issue #13's false positive: supervision turns during a long in-guest
  # pipeline are legitimately status-sparse, so bare turn-ends alone must not
  # count toward stranding while the keep-alive's guest-active breadcrumb
  # proves live in-guest work. Once the breadcrumb goes stale, uncounted
  # turn-ends resume counting and the real stranding alarm still fires.
  local dir state mount out pid i
  dir=$(make_case active-suppress); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  # Three bare turn-ends, each with a FRESH breadcrumb: healthy supervision
  # of live in-guest work, never a stranding candidate.
  for i in 1 2 3; do
    touch "$mount/x.guest-active"
    printf 't%s\n' "$i" >> "$mount/x.turn-ended"
    : > "$out"
    watch_bg "$state" "$dir/fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not exit on supervised turn-end $i: $(cat "$out")"
  done
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "turn-ends with a fresh guest-active breadcrumb must not trip the stranding alarm: $(cat "$state/.wake-queue")"

  # Breadcrumb stale: the same pattern is now stranding evidence again.
  touch -t 202001010000 "$mount/x.guest-active"
  for i in 4 5 6; do
    printf 't%s\n' "$i" >> "$mount/x.turn-ended"
    : > "$out"
    watch_bg "$state" "$dir/fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not exit on stranded turn-end $i: $(cat "$out")"
  done
  grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "no-progress turn-ends after the breadcrumb went stale should still alarm: $(cat "$state/.wake-queue")"

  pass "a fresh guest-active breadcrumb suppresses the stranding count; a stale one re-enables it"
}

test_healthy_idle_secondmate_never_alarms() {
  # Over-alarming is as harmful as under-alarming (issue #13: two false alarms,
  # zero true ones, in one night). A persistent secondmate with an empty queue
  # is HEALTHY - for sbx a stopped VM with no signals at all is its normal
  # resting state - so with no outstanding delivery the beacon must stay
  # completely silent no matter how long it sits there.
  local dir state mount out pid
  dir=$(make_case healthy-idle); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "an idle secondmate with no delivery woke the watcher: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$state/.wake-queue" ] 2>/dev/null \
    || ! grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "a healthy idle secondmate must never raise a stranding alarm: $(cat "$state/.wake-queue")"

  pass "a healthy idle secondmate with no outstanding delivery never alarms"
}

test_unacked_delivery_fires_stranding_alarm() {
  # Issue #13's structural blind spot: the no-progress counter can only count
  # turn-ends that HAPPEN, so an agent that cannot process AT ALL (the observed
  # auth-dead claude TUI: the beat directory stayed EMPTY from creation, zero
  # turn-ends ever) never advances it. This case reproduces exactly that shape
  # - a delivered steer, then permanent silence with no turn-ended file at all
  # - and the beacon must still name it.
  local dir state mount out pid
  dir=$(make_case unacked); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  # The host spoke to the guest long ago; nothing in the mount ever moved.
  touch -t 202001010000 "$state/.sbx-delivered-x"
  [ ! -e "$mount/x.turn-ended" ] || fail "fixture bug: the beat file must not exist"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on an unacknowledged delivery: $(cat "$out")"
  grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "a delivery with zero turn-ends must still raise the stranding alarm: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F "nothing has come back" "$state/.wake-queue" >/dev/null \
    || fail "the alarm should name the unacknowledged-delivery pattern: $(cat "$state/.wake-queue")"

  # One alarm per episode, durable across the restart the wake itself caused.
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher re-alarmed on an already-alarmed stranding: $(cat "$out")"; }
  reap "$pid"
  [ "$(grep -c "sbx-stranded:x" "$state/.wake-queue")" = 1 ] \
    || fail "one stranding episode should hold at ONE queued alarm: $(cat "$state/.wake-queue")"

  pass "an unacknowledged delivery alarms once even with zero turn-ends"
}

test_turnend_acknowledgement_silences_and_rearms() {
  # The acknowledgement rule, first signal: a turn end at or after the delivery
  # proves the guest processed it, so the arm stays silent however old the
  # delivery gets - and a LATER unacknowledged delivery alarms again, so one
  # recovered episode never disarms the next.
  local dir state mount out pid
  dir=$(make_case acked-turnend); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  touch -t 202001010000 "$state/.sbx-delivered-x"
  # The guest answered that steer: its beat is newer than the delivery.
  printf 't1\n' >> "$mount/x.turn-ended"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  # The turn-end is itself an ordinary signal wake; it must NOT be a stranding.
  wait_for_exit "$pid" 40 || fail "watcher did not surface the acknowledging turn-end: $(cat "$out")"
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "a turn end after the delivery must acknowledge it: $(cat "$state/.wake-queue")"
  # Quiet from here: the signal is consumed, so nothing at all should wake.
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "an acknowledged delivery woke the watcher: $(cat "$out")"; }
  reap "$pid"
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "an acknowledged delivery must never alarm later: $(cat "$state/.wake-queue")"

  # A NEW steer that the guest never answers is a fresh episode: the delivery
  # now postdates the last beat, which is what "unacknowledged" means.
  touch -t 202001010000 "$mount/x.turn-ended"
  touch -t 202001020000 "$state/.sbx-delivered-x"
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on the next unacknowledged delivery: $(cat "$out")"
  grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "a delivery newer than the last beat should alarm again: $(cat "$state/.wake-queue")"

  pass "a turn end acknowledges its delivery; a later unanswered one re-alarms"
}

test_status_only_acknowledgement_silences() {
  # The beacon must not rest on turn-ends EXCLUSIVELY (issue #13's doc
  # correction): a guest that reports through its status file but whose
  # turn-end hook never fires is working, not stranded.
  local dir state mount out pid
  dir=$(make_case acked-status); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  touch -t 202001010000 "$state/.sbx-delivered-x"
  printf 'working: on it\n' >> "$mount/x.status"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the status write: $(cat "$out")"
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "a status line after the delivery must acknowledge it: $(cat "$state/.wake-queue")"

  pass "a status line acknowledges a delivery with no turn-end at all"
}

test_inguest_work_acknowledges_delivery() {
  # Issue #13's false-positive shape, seen by the second arm: the secondmate is
  # healthily supervising a long in-guest pipeline, so it is status-sparse AND
  # its own turn has not ended. The keep-alive's guest-active breadcrumb is the
  # only thing moving, and it must be enough to keep the beacon quiet.
  local dir state mount out pid
  dir=$(make_case acked-inguest); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  touch -t 202001010000 "$state/.sbx-delivered-x"
  touch "$mount/x.guest-active"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "live in-guest work woke the watcher: $(cat "$out")"; }
  reap "$pid"
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" 2>/dev/null >/dev/null \
    || fail "verifiable in-guest work must acknowledge the delivery: $(cat "$state/.wake-queue")"

  # The pipeline ends and the guest goes silent without ever answering: the
  # same delivery is now unacknowledged evidence again.
  touch -t 201901010000 "$mount/x.guest-active"
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm once in-guest work predated the delivery: $(cat "$out")"
  grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "work older than the delivery is not acknowledgement: $(cat "$state/.wake-queue")"

  pass "live in-guest work acknowledges a delivery; stale work does not"
}

test_recent_delivery_is_not_yet_stranding() {
  # The window is a grace, not a trigger: an ordinary steer the guest is still
  # thinking about must never alarm.
  local dir state mount out pid
  dir=$(make_case fresh-delivery); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  touch "$state/.sbx-delivered-x"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "a just-delivered steer woke the watcher: $(cat "$out")"; }
  reap "$pid"
  ! grep -F "sbx-stranded:x" "$state/.wake-queue" 2>/dev/null >/dev/null \
    || fail "a delivery inside the acknowledgement window must not alarm: $(cat "$state/.wake-queue")"

  pass "a delivery still inside the acknowledgement window never alarms"
}

test_same_timestamp_signal_does_not_ack_delivery() {
  local dir state mount out pid
  dir=$(make_case equal-time-pre-signal); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  printf 'working: older signal\n' > "$mount/x.status"
  touch -t 202001010000 "$state/.sbx-delivered-x"
  touch -r "$state/.sbx-delivered-x" "$mount/x.status"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 \
    || fail "watcher did not alarm when only a same-timestamp pre-delivery signal existed: $(cat "$out")"
  grep -F "sbx-stranded:x" "$state/.wake-queue" >/dev/null \
    || fail "a signal with the delivery's exact timestamp must not acknowledge it: $(cat "$state/.wake-queue" 2>/dev/null)"

  pass "a same-timestamp signal does not acknowledge a later delivery"
}

test_acknowledgement_never_rearms_a_standing_alarm() {
  # The two arms share one alarmed marker, and only STATUS PROGRESS may clear
  # it. Acknowledgement must not: a guest that answers every steer with a bare
  # turn-end while never progressing would otherwise clear the marker on each
  # steer and alarm again on the next one - one episode becoming an alarm per
  # steer, the same over-alarming this beacon was fixed for.
  local dir state mount out pid i
  dir=$(make_case ack-no-rearm); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"

  # Drive the counter arm to its one alarm.
  for i in 1 2 3; do
    printf 't%s\n' "$i" >> "$mount/x.turn-ended"
    : > "$out"
    watch_bg "$state" "$dir/fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not exit on stranded turn-end $i: $(cat "$out")"
  done
  [ "$(grep -c "sbx-stranded:x" "$state/.wake-queue")" = 1 ] \
    || fail "setup: the counter arm should have alarmed exactly once: $(cat "$state/.wake-queue")"

  # Two more steers, each ANSWERED by a bare turn-end and each still making no
  # progress. Every one of them acknowledges its delivery; none may re-alarm.
  for i in 4 5; do
    touch "$state/.sbx-delivered-x"
    printf 't%s\n' "$i" >> "$mount/x.turn-ended"
    : > "$out"
    watch_bg "$state" "$dir/fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not exit on answered steer $i: $(cat "$out")"
  done
  [ "$(grep -c "sbx-stranded:x" "$state/.wake-queue")" = 1 ] \
    || fail "acknowledged steers must not re-arm a standing alarm: $(cat "$state/.wake-queue")"

  pass "acknowledging a delivery never re-arms an alarm that already stands"
}

test_status_progress_rearms_without_any_turn_end() {
  # The re-arm must not sit behind a turn-end gate. A guest recovering from the
  # zero-turn-end variant can write status again before it ever produces
  # another turn-end, and gating the re-arm on a turn-ended file would latch
  # the alarm forever for exactly the secondmate that just came back.
  local dir state mount out pid
  dir=$(make_case rearm-no-turnend); state="$dir/state"; out="$dir/watch.out"
  mount="$dir/mount"
  mkdir -p "$mount"
  ln -s "$mount/x.status" "$state/x.status"
  ln -s "$mount/x.turn-ended" "$state/x.turn-ended"
  touch -t 202001010000 "$state/.sbx-delivered-x"

  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on the first stranding: $(cat "$out")"
  [ "$(grep -c "sbx-stranded:x" "$state/.wake-queue")" = 1 ] \
    || fail "setup: expected exactly one alarm: $(cat "$state/.wake-queue")"
  [ -e "$state/.sbx-stranded-alarmed-x" ] || fail "setup: the alarm should have latched"

  # Recovery: the guest reports again. No turn-ended file has EVER existed.
  printf 'working: back on deck\n' >> "$mount/x.status"
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the recovery status write: $(cat "$out")"
  [ ! -e "$mount/x.turn-ended" ] || fail "fixture bug: this case must never produce a turn-end"
  [ ! -e "$state/.sbx-stranded-alarmed-x" ] \
    || fail "status progress must re-arm the alarm even with no turn-ended file at all"

  # A later unanswered steer is a fresh episode and must alarm again.
  touch -t 202001030000 "$mount/x.status"
  touch -t 202001040000 "$state/.sbx-delivered-x"
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not alarm on the next stranding episode: $(cat "$out")"
  [ "$(grep -c "sbx-stranded:x" "$state/.wake-queue")" = 2 ] \
    || fail "a re-armed beacon should alarm on the next episode: $(cat "$state/.wake-queue")"

  pass "status progress re-arms the alarm with no turn-end in the whole episode"
}

test_mount_write_surfaces_through_symlink
test_second_mount_write_surfaces_again
test_foreign_id_file_is_invisible
test_mount_vanished_fires_mount_alarm
test_mount_alarm_fires_once_and_rearms
test_no_progress_turns_fire_stranding_alarm
test_status_progress_resets_stranding_counter
test_midtask_stop_marker_fires_named_alarm
test_inguest_activity_suppresses_stranding
test_healthy_idle_secondmate_never_alarms
test_recent_delivery_is_not_yet_stranding
test_same_timestamp_signal_does_not_ack_delivery
test_unacked_delivery_fires_stranding_alarm
test_turnend_acknowledgement_silences_and_rearms
test_status_only_acknowledgement_silences
test_inguest_work_acknowledges_delivery
test_acknowledgement_never_rearms_a_standing_alarm
test_status_progress_rearms_without_any_turn_end

echo "# all fm-watch-sbx-signals tests passed"
