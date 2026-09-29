#!/usr/bin/env bash
# tests/fm-tmux-submit-busy.test.sh - regression: a mid-turn Enter the harness
# ACCEPTED must never be reported as a swallowed Enter, in either shape.
#   opencode 1.18.4 keeps the typed text in the composer until the turn ends, so
#   the verdict comes from the spent-budget fm_pane_is_busy fallback.
#   Claude Code 2.1.268 instead replaces the composer with its own
#   "Press up to edit queued messages" acknowledgement, and renders no
#   "esc to interrupt" anywhere, so the busy fallback cannot rescue it - the
#   shared composer owner has to read that acknowledgement as "not pending".
# Both shapes report `queued`, distinct from a cleared composer's `empty`.
# The frame tests replay whole claude panes measured on 2026-09-29
# (docs/tmux-backend.md): a long multi-line paste whose redraw lags past the
# Enter-retry budget must not read as a swallowed Enter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0; is_literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) is_literal=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$is_literal" = 1 ] && printf '%s\n' "$1" >> "${FM_FAKE_SENT:-/dev/null}" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        printf '│ > │\n' > "$COMPOSER"
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_busy_pane_pending_returns_queued() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-accepted"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  # Pre-check: composer state should be pending (via function, not $()).
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "pre-check: composer state expected pending, got '$(cat "$vfile")'"
  # Now test the submit - write verdict to file to avoid nested $().
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = queued ] || fail "busy-pane pending should return queued, got '$(cat "$vfile")'"
  [ "$(grep -c 'fix findings' "$sent" 2>/dev/null || true)" -eq 0 ] \
    || fail "busy-pane should not retype text"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns queued"
}

test_idle_pane_pending_returns_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "idle-pane pending should return pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)"
}

test_busy_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy pane clears composer on first Enter - returns empty"
}

test_idle_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "idle-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane clears composer on first Enter - returns empty as before"
}

test_claude_queued_acknowledgement_returns_queued() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/claude-queued"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  # The exact composer row measured on a busy Claude Code 2.1.268 pane whose
  # mid-turn Enter was accepted and queued (2026-09-10, docs/tmux-backend.md).
  # FM_FAKE_PANE_BUSY=0 reproduces the other measured half: that release prints
  # no "esc to interrupt", so fm_pane_is_busy reads a busy claude pane as idle
  # and the spent-budget fallback cannot save the verdict.
  printf '❯ Press up to edit queued messages\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 claude > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = queued ] \
    || fail "a queued claude composer should return queued, got '$(cat "$vfile")'"
  [ "$(wc -l < "$sent" | tr -d ' ')" = 0 ] || fail "queued claude pane should not retype text"
  pass "fm_tmux_submit_enter_core: claude queued acknowledgement returns queued without a busy footer"
}

test_claude_idle_composer_text_still_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/claude-idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  # Same unbordered claude composer shape, but holding the real typed steer: an
  # idle pane that never took the Enter must keep failing loudly.
  printf '❯ /no-mistakes\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 claude > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "idle claude pane holding the steer should stay pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle claude pane holding real text still reports a genuine swallow"
}

# make_frame_mock: a tmux stub that replays whole measured pane frames. Each
# composer read starts with the cursor_y query, which advances to the next name
# in FM_FAKE_FRAME_SEQ (the last one repeats). capture-pane honours -S/-E, so
# the reader gets exactly the row it asked for.
make_frame_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_FRAMES:?}
read -r -a seq <<< "${FM_FAKE_FRAME_SEQ:?}"
n=$(cat "$dir/.reads" 2>/dev/null || printf 0)
case "${1:-}" in
  display-message)
    n=$((n + 1)); printf '%s' "$n" > "$dir/.reads"
    printf '26\n'; exit 0 ;;
  capture-pane)
    [ "$n" -gt 0 ] || n=1
    [ "$n" -le "${#seq[@]}" ] || n=${#seq[@]}
    first=0; last=29
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) first=$2; shift ;;
        -E) last=$2; shift ;;
      esac
      shift
    done
    sed -n "$((first + 1)),$((last + 1))p" "$dir/${seq[$((n - 1))]}"
    exit 0 ;;
  send-keys)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) printf 'literal\n' >> "$dir/keys.log" ;;
        Enter) printf 'Enter\n' >> "$dir/keys.log" ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# write_frame: a 30-row, 80-column claude pane. Rows 14-29 come from stdin;
# rows 0-13 are blank, as they were in the measured pane.
write_frame() {  # <file>
  { local i; for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13; do printf '\n'; done; cat; } > "$1"
}

# The measured frames. "held": the long paste still in the composer, cursor on
# its last wrapped line. "cleared": the idle composer after delivery.
# "queued": the busy pane's acknowledgement, rendered dim as claude draws it.
make_long_paste_frames() {  # <dir>
  local dir=$1 esc rule
  esc=$(printf '\033')
  rule='────────────────────────────────────────────────────────────────────────────────'
  mkdir -p "$dir"
  write_frame "$dir/held" <<EOF
✻ Cogitated for 29s · done 9:25 AM
                                                     ctrl+g to edit in VS Code
$rule
❯ and the long lines below exist to wrap past the pane width so the composer
  spans several rows.
  Line three is short.
  Line four repeats the point at length: keep the type-once submit model,
  never retype text into the composer, and report exactly what the pane shows
  after each Enter.
  Line five is also short.
  Line six is the last long one, written so that it is clearly wider than one
  hundred and twenty columns in the worker pane under test.
  Reply with exactly: ack PROBE-F
$rule
   lp1@Lindsays-MacBook-Pro proj [main] | ctx: 22% | \$0.14
  ⏵⏵ bypass permissions on (shift+tab to cycle)
EOF
  write_frame "$dir/cleared" <<EOF
  retype text into the composer, and report exactly what the pane shows after
  each Enter.
  Line five is also short.
  Line six is the last long one, written so that it is clearly wider than one
  hundred and twenty columns in the worker pane under test.
  Reply with exactly: ack PROBE-F

· Brewing…
  ⎿  Tip: Run /ultrareview for a cloud-based multi-agent review that finds and
     verifies bugs in your branch — 3 free reviews left

$rule
${esc}[38;5;246m❯ ${esc}[39m
$rule
   lp1@Lindsays-MacBook-Pro proj [main] | ctx: 22% | \$0.14
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF
  write_frame "$dir/queued" <<EOF
  spans several rows.
  Line three is short.
  Line four repeats the point at length: keep the type-once submit model, never
  retype text into the composer, and report exactly what the pane shows after
  each Enter.
  Line five is also short.
  Line six is the last long one, written so that it is clearly wider than one
  hundred and twenty columns in the worker pane under test.
  Reply with exactly: ack PROBE-G
${esc}[49m  ${esc}[38;5;246mctrl+x ctrl+s to send now${esc}[39m

$rule
${esc}[38;5;246m❯ ${esc}[2m${esc}[39mPress up to edit queued messages${esc}[0m
$rule
   lp1@Lindsays-MacBook-Pro proj [main] | ctx: 23% | \$0.14
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF
}

# run_frames: replay <seq> through the submit core for a recorded claude pane
# (FM_FAKE_PANE_BUSY=0: this claude prints no busy text) and echo the verdict.
run_frames() {  # <dir> <seq>
  local dir=$1 seq=$2 fakebin
  make_long_paste_frames "$dir"
  fakebin=$(make_frame_mock "$dir")
  : > "$dir/keys.log"
  PATH="$fakebin:$PATH" FM_FAKE_FRAMES="$dir" FM_FAKE_FRAME_SEQ="$seq" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.01 claude > "$dir/verdict" 2>/dev/null
}

assert_three_enters_no_retype() {  # <dir>
  [ "$(grep -c '^Enter$' "$1/keys.log")" = 3 ] \
    || fail "expected exactly 3 Enters, got: $(tr '\n' ' ' < "$1/keys.log")"
  [ "$(grep -c '^literal$' "$1/keys.log")" = 0 ] || fail "the submit core retyped text"
}

test_long_paste_idle_cleared_first_read_is_delivered() {
  local dir="$TMP_ROOT/long-idle-fast"
  run_frames "$dir" "cleared"
  [ "$(cat "$dir/verdict")" = empty ] || fail "long paste cleared on the first read: expected empty, got '$(cat "$dir/verdict")'"
  [ "$(grep -c '^Enter$' "$dir/keys.log")" = 1 ] || fail "a cleared composer needs one Enter"
  pass "fm_tmux_submit_enter_core: long paste cleared at once reports delivered after one Enter"
}

test_long_paste_idle_redraw_lag_is_delivered() {
  local dir="$TMP_ROOT/long-idle-lag"
  # Four reads still show the paste, one more than the Enter budget covers.
  run_frames "$dir" "held held held held cleared"
  [ "$(cat "$dir/verdict")" = empty ] \
    || fail "long paste delivered after a slow redraw: expected empty, got '$(cat "$dir/verdict")'"
  assert_three_enters_no_retype "$dir"
  pass "fm_tmux_submit_enter_core: long paste whose redraw lags the Enter budget reports delivered"
}

test_long_paste_busy_redraw_lag_is_queued() {
  local dir="$TMP_ROOT/long-busy-lag"
  run_frames "$dir" "held held held held queued"
  [ "$(cat "$dir/verdict")" = queued ] \
    || fail "long paste queued after a slow redraw: expected queued, got '$(cat "$dir/verdict")'"
  assert_three_enters_no_retype "$dir"
  pass "fm_tmux_submit_enter_core: long paste queued behind a busy claude pane reports queued"
}

test_long_paste_busy_dim_acknowledgement_is_queued() {
  local dir="$TMP_ROOT/long-busy-fast"
  run_frames "$dir" "queued"
  [ "$(cat "$dir/verdict")" = queued ] \
    || fail "dim queued acknowledgement: expected queued, got '$(cat "$dir/verdict")'"
  pass "fm_tmux_submit_enter_core: dim claude queued acknowledgement reports queued, not delivered"
}

test_long_paste_left_unsent_is_pending() {
  local dir="$TMP_ROOT/long-idle-swallow"
  run_frames "$dir" "held"
  [ "$(cat "$dir/verdict")" = pending ] \
    || fail "long paste never submitted: expected pending, got '$(cat "$dir/verdict")'"
  assert_three_enters_no_retype "$dir"
  pass "fm_tmux_submit_enter_core: long paste left in an idle composer still reports a swallow"
}

test_busy_pane_pending_returns_queued
test_idle_pane_pending_returns_pending
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_claude_queued_acknowledgement_returns_queued
test_claude_idle_composer_text_still_pending
test_long_paste_idle_cleared_first_read_is_delivered
test_long_paste_idle_redraw_lag_is_delivered
test_long_paste_busy_redraw_lag_is_queued
test_long_paste_busy_dim_acknowledgement_is_queued
test_long_paste_left_unsent_is_pending
