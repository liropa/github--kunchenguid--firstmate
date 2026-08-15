#!/usr/bin/env bash
# Regression test for spawn-time command delivery into a task pane
# (bin/fm-spawn.sh's worktree acquisition and its verified launch delivery).
#
# The live failure this reproduces: a freshly created window runs the captain's
# INTERACTIVE login shell, and anything that shell asks before the first send
# lands eats the leading characters of that send. Measured 2026-08-13 on the
# reference tmux backend, oh-my-zsh's auto-update prompt sat at
# "[oh-my-zsh] Would you like to update? [Y/n]" in every fresh window, ate the
# "t" of `treehouse get`, and the spawn died on the bounded worktree wait.
#
# The fixture models exactly that: a fake tmux whose pane is backed by a REAL
# shell, in front of which a configurable number of typed lines lose their
# first character. Nothing here simulates the fix - the pane executes whatever
# bytes reach it, so a command that arrives mangled genuinely does not run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-delivery)
# A TMPDIR with a trailing slash (macOS ships one) leaves a doubled separator in
# the temp root, which the pane's own `cd` normalizes away - so collapse it here
# too, or every path comparison against what the pane reports is off by a slash.
TMP_ROOT=$(printf '%s' "$TMP_ROOT" | sed 's|//*|/|g')

# make_pane_fakebin <dir> builds the fixture's fake tmux, treehouse, and
# harness binary.
#
# The fake tmux keeps a typed-byte buffer per pane and, on Enter, runs the
# accumulated line through a real `bash -c` in the pane's recorded cwd. The
# character-eating prompt is modelled at the buffer's edge: while fewer than
# FM_FAKE_EAT_LINES lines have been started, the first character typed into an
# empty buffer is swallowed, exactly as a `read -k 1` prompt swallows it.
make_pane_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
BUF=${FM_FAKE_BUF:?FM_FAKE_BUF unset}
CWDF=${FM_FAKE_PANE_CWD_FILE:?FM_FAKE_PANE_CWD_FILE unset}
FG=${FM_FAKE_FG:?FM_FAKE_FG unset}
EATN=${FM_FAKE_EAT_COUNT:?FM_FAKE_EAT_COUNT unset}
LINES=${FM_FAKE_LINES:?FM_FAKE_LINES unset}
CWDN=${FM_FAKE_CWD_COUNT:?FM_FAKE_CWD_COUNT unset}
DROPN=${FM_FAKE_DROP_COUNT:?FM_FAKE_DROP_COUNT unset}
ENTERN=${FM_FAKE_ENTER_COUNT:?FM_FAKE_ENTER_COUNT unset}
QUEUEN=${FM_FAKE_QUEUE_COUNT:?FM_FAKE_QUEUE_COUNT unset}
QUEUE=${FM_FAKE_QUEUE:?FM_FAKE_QUEUE unset}

bump() {  # <counter-file> -> echoes the new count
  local f=$1 n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1))
  printf '%s\n' "$n" > "$f"
  printf '%s' "$n"
}

append() {  # <text>
  local text=$1 cur="" n=0
  # A pane with no shell yet swallows keystrokes whole, leaving no trace.
  if [ "$(bump "$DROPN")" -le "${FM_FAKE_DROP_LITERALS:-0}" ]; then
    return 0
  fi
  [ -f "$BUF" ] && cur=$(cat "$BUF")
  if [ -z "$cur" ]; then
    [ -f "$EATN" ] && n=$(cat "$EATN")
    if [ "$n" -lt "${FM_FAKE_EAT_LINES:-0}" ]; then
      printf '%s\n' "$((n + 1))" > "$EATN"
      text=${text:1}
    fi
  fi
  printf '%s' "$cur$text" > "$BUF"
}

exec_line() {  # <line>
  local cwd
  printf '%s\n' "$1" >> "$LINES"
  cwd=$(cat "$CWDF")
  ( cd "$cwd" 2>/dev/null || cd /; bash -c "$1" ) >> "${FM_FAKE_SHELL_LOG:-/dev/null}" 2>&1
}

run_line() {
  local line="" queued
  [ -f "$BUF" ] && line=$(cat "$BUF")
  : > "$BUF"
  [ -n "$line" ] || return 0
  # A pane whose shell has not started yet leaves typed lines in the tty and
  # runs them all at once when it finally wakes.
  if [ "$(bump "$QUEUEN")" -le "${FM_FAKE_BUFFER_ENTERS:-0}" ]; then
    printf '%s\n' "$line" >> "$QUEUE"
    return 0
  fi
  if [ -s "$QUEUE" ]; then
    while IFS= read -r queued; do
      [ -n "$queued" ] && exec_line "$queued"
    done < "$QUEUE"
    : > "$QUEUE"
  fi
  exec_line "$line"
}

case "$*" in
  *'#{pane_current_path}'*)
    # An empty read is how a pane with no process in it answers.
    if [ "$(bump "$CWDN")" -le "${FM_FAKE_CWD_HIDE_READS:-0}" ]; then
      printf '\n'
    else
      cat "$CWDF"
    fi
    exit 0
    ;;
  *'#{pane_current_command}'*) cat "$FG"; exit 0 ;;
  *'#{pane_id}'*) printf '%%1\n'; exit 0 ;;
  *'#{window_id}'*)
    # new-window: record the pane's starting cwd, then hand back a stable id.
    prev=""
    for arg in "$@"; do
      [ "$prev" = "-c" ] && printf '%s\n' "$arg" > "$CWDF"
      prev=$arg
    done
    printf '@1\n'
    exit 0
    ;;
esac

case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    shift
    # Drop the target selector.
    [ "${1:-}" = "-t" ] && shift 2
    if [ "${1:-}" = "-l" ]; then
      shift
      append "${1:-}"
      exit 0
    fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        Enter)
          # A pane can take the text and lose the Enter that would submit it.
          if [ "$(bump "$ENTERN")" -le "${FM_FAKE_EAT_ENTERS:-0}" ]; then
            :
          else
            run_line
          fi
          ;;
        *) append "$1" ;;
      esac
      shift
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  # The pool: `get --lease` answers non-interactively on stdout (the acquire
  # firstmate's own process makes), while a bare `get` only ever moves a live
  # pane's cwd - which is what makes it vulnerable to the typing path.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    for arg in "$@"; do
      if [ "$arg" = "--lease" ]; then
        printf 'lease\n' >> "${FM_FAKE_LEASE_CALLS:?FM_FAKE_LEASE_CALLS unset}"
        printf '%s\n' "${FM_FAKE_WT:?FM_FAKE_WT unset}"
        exit 0
      fi
    done
    printf '%s\n' "${FM_FAKE_WT:?FM_FAKE_WT unset}" > "${FM_FAKE_PANE_CWD_FILE:?}"
    exit 0
    ;;
  status) printf '[]\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"

  # The harness stub records that it ran, with the environment it inherited,
  # and claims the pane's foreground slot the way a real agent does.
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'launch cwd=%s gotmpdir=%s\n' "$PWD" "${GOTMPDIR:-}"
} >> "${FM_FAKE_LAUNCH_MARKER:?FM_FAKE_LAUNCH_MARKER unset}"
printf 'codex\n' > "${FM_FAKE_FG:?FM_FAKE_FG unset}"
exit 0
SH
  chmod +x "$fakebin/codex"

  printf '%s\n' "$fakebin"
}

# make_case <name> <id> <eat_lines> builds a home, a project with a real
# worktree standing in for the pool slot, and the fake pane described above.
make_case() {
  local name=$1 id=$2 eat_lines=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_pane_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/buf"
  : > "$case_dir/lines"
  : > "$case_dir/cwd-reads"
  : > "$case_dir/literal-sends"
  : > "$case_dir/enters"
  : > "$case_dir/queue-enters"
  : > "$case_dir/queue"
  : > "$case_dir/lease-calls"
  printf 'zsh\n' > "$case_dir/fg"
  printf '%s\n' "$proj" > "$case_dir/pane-cwd"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$eat_lines"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR EAT_LINES <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_WT="$WT_DIR" FM_FAKE_BUF="$CASE_DIR/buf" \
    FM_FAKE_PANE_CWD_FILE="$CASE_DIR/pane-cwd" FM_FAKE_FG="$CASE_DIR/fg" \
    FM_FAKE_EAT_COUNT="$CASE_DIR/eaten" FM_FAKE_EAT_LINES="$EAT_LINES" \
    FM_FAKE_CWD_COUNT="$CASE_DIR/cwd-reads" FM_FAKE_DROP_COUNT="$CASE_DIR/literal-sends" \
    FM_FAKE_ENTER_COUNT="$CASE_DIR/enters" \
    FM_FAKE_QUEUE_COUNT="$CASE_DIR/queue-enters" FM_FAKE_QUEUE="$CASE_DIR/queue" \
    FM_FAKE_LEASE_CALLS="$CASE_DIR/lease-calls" \
    FM_FAKE_LINES="$CASE_DIR/lines" FM_FAKE_SHELL_LOG="$CASE_DIR/shell.log" \
    FM_FAKE_LAUNCH_MARKER="$CASE_DIR/launched-marker" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# The reproduction. One prompt eats the first character of the first line the
# pane receives; the spawn must still put a live agent in the task's own
# worktree, with the task environment the brief promises.
test_prompt_eating_first_line_still_launches() {
  local rec id out status
  id=launch-eaten-first-line-z1
  rec=$(make_case eaten-first "$id" 1)
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should survive a prompt that ate the first typed line; output was: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the acquired worktree"
  assert_present "$CASE_DIR/launched-marker" "the agent never launched"
  assert_grep "cwd=$WT_DIR" "$CASE_DIR/launched-marker" \
    "the agent did not start in the task worktree; marker was: $(cat "$CASE_DIR/launched-marker")"
  assert_grep "gotmpdir=/tmp/fm-$id/gotmp" "$CASE_DIR/launched-marker" \
    "the agent did not inherit the task temp root"
  [ "$(wc -l < "$CASE_DIR/launched-marker")" -eq 1 ] \
    || fail "the retry launched a second agent"$'\n'"$(cat "$CASE_DIR/launched-marker")"
  pass "a prompt that eats the first typed line still reaches a launched agent"
}

# A pane whose prompt never clears must stop loudly and leave no record that
# reads as a started task.
test_unclearable_prompt_fails_loudly() {
  local rec id out status
  id=launch-eaten-always-z2
  rec=$(make_case eaten-always "$id" 99)
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn reported success though the launch never reached the shell"
  assert_contains "$out" "launch command was not delivered" \
    "the failure did not name undelivered launch input"
  assert_absent "$CASE_DIR/launched-marker" "the agent launched despite a mangled command"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "an unverified launch still recorded the task as started"
  pass "an unclearable prompt stops loudly and records no started task"
}

# The pool slot is acquired by firstmate's own process, never typed at a
# prompt: no pane input may contain the acquire command.
test_worktree_is_never_acquired_by_typing() {
  local rec id
  id=launch-acquire-offpane-z3
  rec=$(make_case acquire-offpane "$id" 0)
  read_case "$rec"

  run_spawn "$id" >/dev/null
  assert_no_grep 'treehouse get' "$CASE_DIR/lines" \
    "the worktree acquire was typed into the pane"
  pass "the worktree is acquired off-pane, never typed at a shell prompt"
}

test_respawn_reuses_lease_for_same_project() {
  local rec id out status
  id=launch-reuse-same-project-z4
  rec=$(make_case reuse-same-project "$id" 0)
  read_case "$rec"
  {
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'worktree_lease=treehouse\n'
    printf 'project=%s\n' "$PROJ_DIR"
  } > "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "respawn should reuse the same project's lease; output was: $out"
  [ ! -s "$CASE_DIR/lease-calls" ] \
    || fail "respawn took a new lease instead of reusing the recorded worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "respawn did not retain the recorded worktree"
  pass "a respawn reuses the lease recorded for the same project"
}

test_respawn_refuses_lease_from_different_project() {
  local rec id out status other_project
  id=launch-refuse-other-project-z8
  rec=$(make_case refuse-other-project "$id" 0)
  read_case "$rec"
  other_project="$CASE_DIR/other-project"
  mkdir -p "$other_project"
  {
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'worktree_lease=treehouse\n'
    printf 'project=%s\n' "$other_project"
  } > "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "respawn launched with a lease from another project"
  assert_contains "$out" "$WT_DIR" "mismatch error did not name the recorded worktree"
  assert_contains "$out" "$other_project" "mismatch error did not name the recorded project"
  assert_contains "$out" "$PROJ_DIR" "mismatch error did not name the requested project"
  [ ! -s "$CASE_DIR/lease-calls" ] \
    || fail "respawn took a new lease after detecting a project mismatch"
  assert_absent "$CASE_DIR/launched-marker" "respawn launched despite a project mismatch"
  pass "a respawn refuses a lease recorded for another project"
}

# A pane can swallow a send whole and leave no trace - measured live on herdr
# 0.7.5, a freshly created tab handed back a pane with no shell in it, which
# echoed keystrokes and executed nothing. The retry must recover WITHOUT
# concatenating onto whatever fragment the pane kept: exactly one agent, never
# two, never a spliced command line.
test_lost_first_send_retries_without_doubling() {
  local rec id out status
  id=launch-lost-send-z5
  rec=$(make_case lost-send "$id" 0)
  read_case "$rec"

  out=$(FM_FAKE_DROP_LITERALS=1 FM_FAKE_CWD_HIDE_READS=2 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should recover from a lost first send; output was: $out"
  assert_present "$CASE_DIR/launched-marker" "the agent never launched"
  [ "$(wc -l < "$CASE_DIR/launched-marker")" -eq 1 ] \
    || fail "the retry launched a second agent"$'\n'"$(cat "$CASE_DIR/launched-marker")"
  assert_no_grep 'printf.*printf' "$CASE_DIR/lines" \
    "the retry concatenated onto the pane's leftover input"
  pass "a lost send is retyped once, on a flushed input line, launching exactly one agent"
}

# The text landed but its Enter did not. The retry's flushing Enter submits that
# already-typed line, so the retry must notice and stop - retyping on top of it
# would start a second agent on the same task.
test_lost_enter_submits_once_and_never_twice() {
  local rec id out status
  id=launch-lost-enter-z6
  rec=$(make_case lost-enter "$id" 0)
  read_case "$rec"

  out=$(FM_FAKE_EAT_ENTERS=1 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should recover from a lost Enter; output was: $out"
  assert_present "$CASE_DIR/launched-marker" "the agent never launched"
  [ "$(wc -l < "$CASE_DIR/launched-marker")" -eq 1 ] \
    || fail "a lost Enter led to two agents on one task"$'\n'"$(cat "$CASE_DIR/launched-marker")"
  pass "a lost Enter is re-sent, submits the typed line once, and never doubles the agent"
}

# The pane took every line but ran none of them until later - measured live on
# herdr 0.7.5, a freshly created tab echoed keystrokes and executed nothing for
# the whole delivery window. When that pane wakes it runs the retries too, so the
# launch line itself has to refuse to start a second agent.
test_buffered_pane_runs_every_retry_but_launches_once() {
  local rec id out status
  id=launch-buffered-z7
  rec=$(make_case buffered "$id" 0)
  read_case "$rec"

  out=$(FM_FAKE_BUFFER_ENTERS=2 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should survive a pane that buffers its input; output was: $out"
  [ "$(wc -l < "$CASE_DIR/lines")" -ge 3 ] \
    || fail "the fixture did not actually replay the buffered retries"$'\n'"$(cat "$CASE_DIR/lines")"
  [ "$(wc -l < "$CASE_DIR/launched-marker")" -eq 1 ] \
    || fail "a buffered replay launched more than one agent"$'\n'"$(cat "$CASE_DIR/launched-marker")"
  pass "a pane that replays every buffered retry still launches exactly one agent"
}

test_prompt_eating_first_line_still_launches
test_unclearable_prompt_fails_loudly
test_buffered_pane_runs_every_retry_but_launches_once
test_worktree_is_never_acquired_by_typing
test_respawn_reuses_lease_for_same_project
test_respawn_refuses_lease_from_different_project
test_lost_first_send_retries_without_doubling
test_lost_enter_submits_once_and_never_twice

echo "# all fm-spawn-launch-delivery tests passed"
