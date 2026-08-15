#!/usr/bin/env bash
# tests/fake-launch-ack.sh - stand in for the shell behind a fake pane.
#
# bin/fm-spawn.sh no longer believes a launch landed just because a send
# returned: it types one `&&` chain whose first command stamps a nonce into a
# sentinel file, and waits for that nonce before recording a started task (see
# that script's launch-delivery section for why). A fake pane that swallows
# every keystroke is, to that check, indistinguishable from a real pane sitting
# at an unanswered startup prompt - which is exactly the failure the check
# exists to catch.
#
# So a fake pane that means to model a WORKING shell must run the line it was
# handed. It runs only the sentinel-claiming head of the chain - everything
# before the `cd` into the worktree - so the fixture still never launches a real
# agent. That cut point is the one thing here coupled to fm-spawn.sh's chain; if
# the chain's shape changes, this changes with it.
#
# Fakes call it with their whole argument list:
#   [ -z "${FM_TEST_LAUNCH_ACK:-}" ] || "$FM_TEST_LAUNCH_ACK" "$@"
#
# A fixture that deliberately models a pane which does NOT run what it is given
# (tests/fm-spawn-launch-delivery.test.sh) must not call this.
set -u

for arg in "$@"; do
  case "$arg" in
    'test ! -s '*' && printf %s '*' && ( cd '*)
      sh -c "${arg%% && ( cd *}"
      exit 0
      ;;
  esac
done
exit 0
