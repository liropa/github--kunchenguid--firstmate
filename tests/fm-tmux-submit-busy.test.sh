#!/usr/bin/env bash
# tests/fm-tmux-submit-busy.test.sh - regression: a mid-turn Enter the harness
# ACCEPTED must never be reported as a swallowed Enter, in either shape.
#   opencode 1.18.4 keeps the typed text in the composer until the turn ends, so
#   the verdict comes from the spent-budget fm_pane_is_busy fallback.
#   Claude Code 2.1.268 instead replaces the composer with its own
#   "Press up to edit queued messages" acknowledgement, and renders no
#   "esc to interrupt" anywhere, so the busy fallback cannot rescue it - the
#   shared composer owner has to read that acknowledgement as "not pending".
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

test_busy_pane_pending_returns_empty() {
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
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane pending should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c 'fix findings' "$sent" 2>/dev/null || true)" -eq 0 ] \
    || fail "busy-pane should not retype text"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns empty (message queued)"
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

test_claude_queued_acknowledgement_returns_empty() {
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
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "a queued claude composer should return empty, got '$(cat "$vfile")'"
  [ "$(wc -l < "$sent" | tr -d ' ')" = 0 ] || fail "queued claude pane should not retype text"
  pass "fm_tmux_submit_enter_core: claude queued acknowledgement returns empty without a busy footer"
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
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "idle claude pane holding the steer should stay pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle claude pane holding real text still reports a genuine swallow"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_claude_queued_acknowledgement_returns_empty
test_claude_idle_composer_text_still_pending
