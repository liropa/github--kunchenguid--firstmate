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

test_mount_write_surfaces_through_symlink
test_foreign_id_file_is_invisible

echo "# all fm-watch-sbx-signals tests passed"
