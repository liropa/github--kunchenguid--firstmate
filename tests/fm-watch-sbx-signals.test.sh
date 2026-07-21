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
  # docs/sbx-backend.md "Remaining gaps"): scan_signals' [ -e ] skip makes a
  # vanished mount SILENT - the watcher goes blind to the secondmate with no
  # captain-facing alarm. A dangling symlink whose target DIRECTORY exists is
  # a fresh spawn (quiescent, tested above); a dangling symlink whose target
  # directory is GONE is a vanished mount and must raise one check wake.
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

test_mount_write_surfaces_through_symlink
test_second_mount_write_surfaces_again
test_foreign_id_file_is_invisible
test_mount_vanished_fires_mount_alarm
test_mount_alarm_fires_once_and_rearms
test_no_progress_turns_fire_stranding_alarm
test_status_progress_resets_stranding_counter

echo "# all fm-watch-sbx-signals tests passed"
