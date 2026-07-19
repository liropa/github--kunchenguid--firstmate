#!/usr/bin/env bash
# tests/fm-spawn-sbx.test.sh - bin/fm-spawn.sh's sbx secondmate branch: the
# signal-bridge wiring that keeps fm-watch.sh's scan unchanged for VM-hosted
# secondmates (agent-dotfiles design doc firstmate-sbx-secondmate-event-bridge.md
# §5-§6; docs/sbx-backend.md).
#
# The guarantees under test:
#   - sbx is secondmate-only: ship/scout sbx spawns are refused before any
#     sandbox is created.
#   - A harness without a verified sbx launch+resume shape (anything but
#     claude/codex) is refused BEFORE any sandbox is created, so meta can only
#     record an in-VM harness the liveness sweep's verified list accepts.
#   - A successful spawn creates the per-id signal directory, passes it as the
#     sandbox's RW mount, and turns state/<id>.status + state/<id>.turn-ended
#     into symlinks onto the mount files (the watcher's scan surface AND the
#     id allowlist).
#   - A pre-existing REGULAR status file is folded into the mount file first,
#     so a host->sbx migration keeps its history.
#   - The guest brief copy lands at the same absolute path with the primary's
#     status path rewritten to the mount file (the host symlink makes both
#     names converge), and claude's Stop hook / codex's notify= hook touch the
#     mount's turn-ended AND beat files.
#   - Meta records backend=sbx, window=sbx:fm-<id>, sbx_signals_dir=, and the
#     actual in-VM harness.
set -u

# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the sbx adapter's state probe)"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

# Create the temp root with mktemp directly and canonicalize it BEFORE
# registering it for cleanup (the same trap-in-command-substitution dodge
# tests/wake-helpers.sh documents): fm-spawn resolves the secondmate home
# physically (pwd -P), so assertions on logged paths need the same resolved
# form (macOS mktemp yields /var/folders/..., a symlink to /private/var/...).
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-sbx.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then trap fm_test_cleanup EXIT; fi
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")

# new_world <name>: a primary home plus a seeded secondmate home whose charter
# carries the primary's shell-quoted status path (exactly what fm-brief.sh's
# secondmate scaffold embeds), so the guest-copy substitution has a real
# occurrence to rewrite.
new_world() {
  local name=$1 w home
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data" "$w/signals"
  : > "$w/sbx.log"
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  home="$w/sm"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'smx\n' > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  {
    printf 'Charter body.\n'
    printf 'Report by appending one line:\n'
    printf "   \`echo \"{state}: {note}\" >> '%s/home/state/smx.status'\`\n" "$w"
  } > "$home/data/charter.md"
  printf '%s\n' "$w"
}

run_spawn() {  # <world> <fakebin> <args...> -> stdout+stderr; rc preserved
  local w=$1 fb=$2
  shift 2
  PATH="$fb:$BASE_PATH" FM_SPAWN_NO_GUARD=1 TMUX='' HERDR_ENV='' FM_BACKEND=sbx \
    FM_HOME="$w/home" FM_SBX_SIGNALS_ROOT="$w/signals" FM_SBX_RESURRECT_SETTLE=0 \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_FAKE_SBX_CREATE_JSON="$(sbx_ls_json fm-smx running)" \
    FM_FAKE_SBX_WRITE_DIR="$w/guest-writes" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

guest_write_file() {  # <world> <guest-path>
  printf '%s/guest-writes/%s' "$1" "$(printf '%s' "$2" | tr '/' '_')"
}

test_refuses_non_secondmate_spawn() {
  local w fb out rc=0
  w=$(new_world refuse-ship); fb=$(make_fake_sbx "$w")
  out=$(run_spawn "$w" "$fb" tid projects/alpha --backend sbx) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ship spawn on sbx must be refused"
  assert_contains "$out" "backend=sbx only supports --secondmate spawns" \
    "the refusal should name the secondmate-only constraint"
  [ ! -s "$w/sbx.log" ] || fail "a refused spawn must not have touched sbx: $(cat "$w/sbx.log")"
  pass "spawn: ship/scout sbx spawns are refused before any sandbox exists"
}

test_refuses_unverified_harness() {
  local w fb out rc=0
  w=$(new_world refuse-harness); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/guest-writes"
  out=$(run_spawn "$w" "$fb" smx "$w/sm" pi --secondmate) || rc=$?
  [ "$rc" -ne 0 ] || fail "an sbx spawn on an unverified harness must be refused"
  assert_contains "$out" "not verified on the sbx backend (supported: claude codex)" \
    "the refusal should name the supported harness set"
  assert_not_contains "$(cat "$w/sbx.log")" "create" \
    "the refusal must land before any sandbox is created"
  pass "spawn: an unverified harness (pi) is refused before sandbox creation"
}

test_claude_spawn_wires_signal_bridge() {
  local w fb out sig meta brief_copy hook_copy
  w=$(new_world claude-wiring); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/guest-writes"

  out=$(run_spawn "$w" "$fb" smx "$w/sm" claude --secondmate) \
    || fail "claude sbx secondmate spawn failed: $out"
  assert_contains "$out" "spawned smx harness=claude kind=secondmate" \
    "the spawn should report success: $out"
  assert_contains "$out" "window=sbx:fm-smx" \
    "the spawn should report the sbx:<name> backend target"

  sig="$w/signals/smx"
  [ -d "$sig" ] || fail "the per-id signal directory should exist at $sig"
  assert_contains "$(cat "$w/sbx.log")" "create --clone --name fm-smx claude $w/sm $sig" \
    "sbx create should clone the home with the signal dir as the extra RW mount"

  [ -L "$w/home/state/smx.status" ] || fail "state/smx.status should be a symlink"
  [ "$(readlink "$w/home/state/smx.status")" = "$sig/smx.status" ] \
    || fail "state/smx.status should point at the mount's status file"
  [ -L "$w/home/state/smx.turn-ended" ] || fail "state/smx.turn-ended should be a symlink"
  [ "$(readlink "$w/home/state/smx.turn-ended")" = "$sig/smx.turn-ended" ] \
    || fail "state/smx.turn-ended should point at the mount's turn-ended file"

  meta=$(cat "$w/home/state/smx.meta")
  assert_contains "$meta" "backend=sbx" "meta should record backend=sbx"
  assert_contains "$meta" "window=sbx:fm-smx" "meta should record the sbx target"
  assert_contains "$meta" "harness=claude" "meta should record the in-VM harness"
  assert_contains "$meta" "sbx_signals_dir=$sig" "meta should record the signal dir for teardown"

  brief_copy=$(guest_write_file "$w" "$w/sm/data/charter.md")
  [ -f "$brief_copy" ] || fail "the brief should have been seeded into the guest at its own path"
  # Exact-line assert, not a bare substring: macOS's bash 3.2 patsub bug
  # scrambled the rewrite into 'smx.status//<mount>/smx.status/smx.status',
  # which still CONTAINED the mount path as a substring and slipped past the
  # original looser assertion (found live; see fm-spawn.sh's replace_all).
  assert_contains "$(cat "$brief_copy")" ">> '$sig/smx.status'" \
    "the guest brief's status path must be rewritten to the mount file INTACT"
  assert_not_contains "$(cat "$brief_copy")" "$w/home/state/smx.status" \
    "the guest brief must not name the primary's state path (unreachable from the VM)"
  assert_not_contains "$(cat "$brief_copy")" "smx.status//" \
    "the rewrite must not scramble the path (bash-3.2 quoted-patsub regression shape)"
  [ ! -e "$w/guest-writes/codex-config.toml" ] \
    || fail "a claude spawn must not seed codex project trust"

  hook_copy=$(guest_write_file "$w" "$w/sm/.claude/settings.local.json")
  [ -f "$hook_copy" ] || fail "claude's Stop hook should have been written into the guest clone"
  assert_contains "$(cat "$hook_copy")" "touch '$sig/smx.turn-ended' '$sig/smx.beat'" \
    "the Stop hook must touch the mount's turn-ended AND beat files"

  assert_contains "$(cat "$w/sbx.log")" "claude --dangerously-skip-permissions" \
    "the launch command should have been delivered into the guest pane"

  pass "spawn: claude sbx secondmate gets mount, symlinks, rewritten brief, and guest Stop hook"
}

test_codex_launch_carries_mount_notify() {
  local w fb out sig
  w=$(new_world codex-notify); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/guest-writes"

  out=$(run_spawn "$w" "$fb" smx "$w/sm" codex --secondmate) \
    || fail "codex sbx secondmate spawn failed: $out"
  sig="$w/signals/smx"
  assert_contains "$(cat "$w/sbx.log")" "notify=" \
    "the codex launch should carry the notify= turn-end hook"
  assert_contains "$(cat "$w/sbx.log")" "touch '$sig/smx.turn-ended' '$sig/smx.beat'" \
    "codex's notify hook must touch the mount's turn-ended AND beat files"
  assert_contains "$(cat "$w/sbx.log")" "--dangerously-bypass-hook-trust" \
    "the codex launch must bypass the hook-trust TUI gate (no one is in the pane to answer it)"
  [ ! -e "$(guest_write_file "$w" "$w/sm/.claude/settings.local.json")" ] \
    || fail "a codex spawn must not install a claude hook file"
  [ -f "$w/guest-writes/codex-config.toml" ] \
    || fail "a codex spawn must seed the guest's project-trust config (the directory-trust dialog blocks the launch otherwise)"
  assert_contains "$(cat "$w/guest-writes/codex-config.toml")" "[projects.\"$w/sm\"]" \
    "the seeded trust entry must name the secondmate home"
  assert_contains "$(cat "$w/guest-writes/codex-config.toml")" 'trust_level = "trusted"' \
    "the seeded trust entry must mark the home trusted"
  pass "spawn: codex sbx secondmate's launch carries the mount-path notify hook, hook-trust bypass, and seeded project trust"
}

test_refuses_worktree_home() {
  local w fb out rc=0
  w=$(new_world refuse-worktree); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/guest-writes"
  # A linked git worktree's .git is a FILE (gitdir pointer). sbx clone mode
  # refuses that shape, so the spawn must refuse it first, before any sandbox
  # or signal wiring exists.
  printf 'gitdir: /somewhere/.git/worktrees/sm\n' > "$w/sm/.git"
  out=$(run_spawn "$w" "$fb" smx "$w/sm" codex --secondmate) || rc=$?
  [ "$rc" -ne 0 ] || fail "an sbx spawn over a linked-worktree home must be refused"
  assert_contains "$out" "plain-clone home" \
    "the refusal should state the plain-clone requirement"
  assert_not_contains "$(cat "$w/sbx.log")" "create" \
    "the refusal must land before any sandbox is created"
  pass "spawn: a linked-worktree home is refused before sandbox creation"
}

test_preexisting_status_history_is_folded() {
  local w fb out sig
  w=$(new_world fold-history); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/guest-writes" "$w/signals/smx"
  printf 'done: earlier host-side outcome\n' > "$w/home/state/smx.status"

  out=$(run_spawn "$w" "$fb" smx "$w/sm" claude --secondmate) \
    || fail "spawn over a pre-existing status file failed: $out"
  sig="$w/signals/smx"
  [ -L "$w/home/state/smx.status" ] || fail "the regular status file should have become a symlink"
  assert_grep "done: earlier host-side outcome" "$sig/smx.status" \
    "the pre-existing status history must survive inside the mount file"
  pass "spawn: a pre-existing regular status file's history is folded into the mount"
}

test_refuses_non_secondmate_spawn
test_refuses_unverified_harness
test_claude_spawn_wires_signal_bridge
test_codex_launch_carries_mount_notify
test_refuses_worktree_home
test_preexisting_status_history_is_folded

echo "# all fm-spawn-sbx tests passed"
