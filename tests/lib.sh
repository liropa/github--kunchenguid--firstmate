#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The shell a fake pane stands in for, so fm-spawn.sh's launch-delivery check
# sees the acknowledgement a live shell would give. tests/fake-launch-ack.sh
# owns what it does and which fixtures must NOT call it.
export FM_TEST_LAUNCH_ACK="$ROOT/tests/fake-launch-ack.sh"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_LAUNCH_ACK:-}" ] || "$FM_TEST_LAUNCH_ACK" "$@"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_treehouse <fakebin>: stub the worktree pool. `treehouse get --lease`
# is how bin/fm-spawn.sh acquires a ship/scout worktree - in its own process,
# answering on stdout - so the stub echoes $FM_FAKE_WORKTREE, the worktree the
# fixture wants that task to land in. Every other subcommand is an exit-0 no-op.
#
# REQUIRED by any fixture that drives a ship/scout spawn. That acquire is a real
# subprocess, not a command typed into a fake pane, so a fixture that leaves the
# host's own treehouse first on PATH would run it against the captain's live
# pool. Same obligation the fm-home-seed fixtures already carry.
fm_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" != get ] || printf '%s\n' "${FM_FAKE_WORKTREE:-}"
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# bin/fm-bootstrap.sh runs its five mutating sweeps only for the session holding
# the home's lock, so a fixture that exercises a sweep has to hold that lock
# first. Ownership is bin/fm-lock.sh's own decision, and it identifies a session
# by walking process ancestry for a harness command name - a test runner has
# none - so these helpers stand up a process that answers that description, then
# ask the real fm-lock.sh which identity it settles on. Guessing a pid instead
# would guess wrong whenever the suite runs from inside a real harness session,
# where the ancestry walk answers first.
#
# Two steps, because the answer has to be resolved ONCE in the test file's own
# shell: fm_test_session_lock_init exports FM_HARNESS_PID for every later child,
# which is lost if it runs inside a command substitution.
# fm_test_hold_session_lock only writes a file, so a fixture may call it from
# anywhere, including a $(...) capture.

FM_TEST_SESSION_LOCK_PID=

# fm_test_session_lock_init: call once, in the test file's own shell, before any
# fixture that needs a held lock.
fm_test_session_lock_init() {
  local scratch
  [ -z "$FM_TEST_SESSION_LOCK_PID" ] || return 0
  # A live process fm-lock.sh will accept as a harness: "claude" lands in its
  # argv, which is half of what that check reads. It watches the pid this shell
  # had when it started and exits once that is gone, so it needs no cleanup hook
  # - and must not have one, because fm_test_cleanup also runs when a $(...)
  # capture of fm_test_tmproot exits, which would kill it mid-suite.
  bash -c 'p=$PPID; while kill -0 "$p" 2>/dev/null; do sleep 2; done' claude \
    >/dev/null 2>&1 &
  export FM_HARNESS_PID=$!
  scratch=$(fm_test_tmproot fm-session-lock-probe)
  FM_HOME="$scratch" "$ROOT/bin/fm-lock.sh" >/dev/null \
    || fail "fixture could not resolve this session's lock identity"
  FM_TEST_SESSION_LOCK_PID=$(cat "$scratch/state/.lock")
  # Pin the answer for every later child. A suite whose ancestry really does
  # reach a harness resolves that pid here, but a case running on a stripped PATH
  # cannot walk ancestry at all and would otherwise fall back to the seeded pid
  # and read itself as a non-holder. Naming the resolved pid as the fallback
  # makes both routes agree.
  export FM_HARNESS_PID=$FM_TEST_SESSION_LOCK_PID
}

# fm_test_hold_session_lock <home> [state-dir]: put <home>'s session lock in this
# test process's name, so bootstrap sweeps run against <home>. Pass <state-dir>
# for a case that runs under FM_STATE_OVERRIDE, where the lock lives in the
# effective state dir rather than <home>/state.
fm_test_hold_session_lock() {
  local state=${2:-$1/state}
  [ -n "$FM_TEST_SESSION_LOCK_PID" ] || fail "fm_test_session_lock_init must run in the test file's own shell first"
  mkdir -p "$state"
  printf '%s\n' "$FM_TEST_SESSION_LOCK_PID" > "$state/.lock"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
