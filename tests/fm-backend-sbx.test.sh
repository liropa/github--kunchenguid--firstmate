#!/usr/bin/env bash
# tests/fm-backend-sbx.test.sh - the sbx (Docker Sandboxes) backend adapter:
# bin/backends/sbx.sh's state probe, the three-valued agent-liveness mapping,
# state-gated capture, the steering resurrection sequence, and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep acting on sbx verdicts.
#
# The guarantees under test (agent-dotfiles design doc
# firstmate-sbx-secondmate-event-bridge.md §7.3/§8; docs/sbx-backend.md):
#   - fm_backend_sbx_state distinguishes running/stopped/ABSENT (a parse-clean
#     inventory positively lacking the name) from ERROR (CLI failure, bad
#     JSON, unrecognized status vocabulary).
#   - fm_backend_sbx_agent_alive maps: fresh beat -> alive with NO sbx CLI
#     call; running -> alive; stopped -> alive (idle-resumable - respawning
#     would destroy intact VM state); absent -> dead; error -> unknown, NEVER
#     dead (a transient CLI hiccup must not trigger a duplicate-supervisor
#     respawn).
#   - Probe-shaped reads (target_exists, capture) never `sbx exec`, because
#     exec AUTO-STARTS a stopped sandbox; capture is refused outright unless
#     the sandbox is already running.
#   - The send path owns resurrection: a running-but-no-tmux guest (the
#     post-auto-stop state) is rebuilt - tmux session at the recorded home,
#     agent relaunched with its harness's RESUME command - before delivery.
#   - The session-start liveness sweep respawns an sbx secondmate only on
#     confirmed-absent, leaves running/stopped untouched, and reports an
#     inconclusive probe as skipped without acting.
set -u

# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the sbx adapter's state probe)"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-backend-sbx)

# run_adapter <fakebin> <world> <snippet> [env k=v...]: run <snippet> in a bash
# that sourced fm-backend.sh + the sbx adapter, with the fake sbx first in
# PATH and the world's log/ls-file/signals-root wired. Echoes the snippet's
# stdout.
run_adapter() {
  local fakebin=$1 world=$2 snippet=$3
  shift 3
  # shellcheck disable=SC2016  # single quotes deliberate: $0 expands in the inner bash
  PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_SBX_LOG="$world/sbx.log" FM_FAKE_SBX_LS_FILE="$world/ls.json" \
    FM_SBX_SIGNALS_ROOT="$world/signals" FM_SBX_RESURRECT_SETTLE=0 \
    FM_SBX_RESURRECT_READY_TRIES=0 FM_SBX_KEEPALIVE_MAX=0 \
    env "$@" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source sbx; '"$snippet" "$ROOT"
}

new_sbx_world() {  # <name>
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/signals" "$w/state"
  : > "$w/sbx.log"
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  printf '%s\n' "$w"
}

# --- unit level: fm_backend_sbx_state ---------------------------------------

test_state_probe_classifies() {
  local w fb out
  w=$(new_sbx_world state-probe); fb=$(make_fake_sbx "$w")

  sbx_ls_json fm-x running > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x')
  [ "$out" = running ] || fail "a listed running sandbox should read running, got '$out'"

  sbx_ls_json fm-x stopped > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x')
  [ "$out" = stopped ] || fail "a listed stopped sandbox should read stopped, got '$out'"

  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x')
  [ "$out" = absent ] || fail "a parse-clean inventory lacking the name should read ABSENT, got '$out'"

  sbx_ls_json fm-other running > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x')
  [ "$out" = absent ] || fail "another sandbox's entry must not mask this name's absence, got '$out'"

  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x' FM_FAKE_SBX_LS_RC=1)
  [ "$out" = error ] || fail "a failing sbx CLI should read ERROR, never absent, got '$out'"

  printf 'not json at all\n' > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x')
  [ "$out" = error ] || fail "unparseable ls output should read ERROR, never absent, got '$out'"

  sbx_ls_json fm-x hibernating > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_state fm-x')
  [ "$out" = error ] || fail "an unrecognized status vocabulary should read ERROR (ambiguous), got '$out'"

  pass "fm_backend_sbx_state: running/stopped/absent vs error classification"
}

# --- unit level: fm_backend_sbx_agent_alive ---------------------------------

test_agent_alive_matrix() {
  local w fb out
  w=$(new_sbx_world alive-matrix); fb=$(make_fake_sbx "$w")

  # Fresh beat: alive from one host stat, with NO sbx CLI call at all.
  mkdir -p "$w/signals/x"
  touch "$w/signals/x/x.beat"
  : > "$w/sbx.log"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:fm-x')
  [ "$out" = alive ] || fail "a fresh beat should read alive, got '$out'"
  [ ! -s "$w/sbx.log" ] || fail "a fresh-beat verdict must not spend any sbx CLI call: $(cat "$w/sbx.log")"

  # Stale beat falls through to the state probe.
  touch -t 202001010000 "$w/signals/x/x.beat"
  sbx_ls_json fm-x running > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:fm-x')
  [ "$out" = alive ] || fail "stale beat + running should read alive, got '$out'"

  sbx_ls_json fm-x stopped > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:fm-x')
  [ "$out" = alive ] || fail "an idle-STOPPED sandbox is resumable and must read alive (a respawn would destroy intact state), got '$out'"

  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:fm-x')
  [ "$out" = dead ] || fail "a confirmed-absent sandbox should read dead, got '$out'"

  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:fm-x' FM_FAKE_SBX_LS_RC=1)
  [ "$out" = unknown ] || fail "a CLI error must read UNKNOWN, never dead (false-dead -> duplicate supervisor), got '$out'"

  sbx_ls_json fm-x hibernating > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:fm-x')
  [ "$out" = unknown ] || fail "an ambiguous status must read UNKNOWN, never dead, got '$out'"

  # A non-fm-* sandbox name has no derivable task id: no beat probe, still a
  # correct state-based verdict.
  sbx_ls_json custom running > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_alive sbx:custom')
  [ "$out" = alive ] || fail "a non-fm-* name should still classify from state, got '$out'"

  pass "fm_backend_sbx_agent_alive: beat/running/stopped/absent/error -> alive/alive/alive/dead/unknown"
}

test_agent_alive_dispatcher_routes_sbx() {
  local w fb out
  w=$(new_sbx_world dispatch); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_agent_alive sbx sbx:fm-x')
  [ "$out" = alive ] || fail "the generic dispatcher should route sbx to fm_backend_sbx_agent_alive, got '$out'"
  pass "fm_backend_agent_alive: routes sbx to the adapter"
}

# --- probe reads never exec (auto-start protection) -------------------------

test_target_exists_never_execs() {
  local w fb
  w=$(new_sbx_world exists); fb=$(make_fake_sbx "$w")

  sbx_ls_json fm-x stopped > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_target_exists sbx sbx:fm-x' \
    || fail "a stopped sandbox is a PRESENT (resumable) endpoint"
  assert_not_contains "$(cat "$w/sbx.log")" "exec" \
    "the presence probe must never sbx exec (exec auto-starts a stopped sandbox)"

  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  if run_adapter "$fb" "$w" 'fm_backend_target_exists sbx sbx:fm-x'; then
    fail "an absent sandbox must not read as present"
  fi

  pass "fm_backend_target_exists: state-probe only, stopped is present, no exec"
}

test_capture_gated_on_running() {
  local w fb out
  w=$(new_sbx_world capture); fb=$(make_fake_sbx "$w")

  sbx_ls_json fm-x stopped > "$w/ls.json"
  : > "$w/sbx.log"
  if run_adapter "$fb" "$w" 'fm_backend_sbx_capture sbx:fm-x 40'; then
    fail "capture of a STOPPED sandbox must be refused (exec would auto-start it)"
  fi
  assert_not_contains "$(cat "$w/sbx.log")" "exec" \
    "a refused capture must not have exec'd (that would have auto-started the VM)"

  sbx_ls_json fm-x running > "$w/ls.json"
  printf 'guest pane text\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_capture sbx:fm-x 40' FM_FAKE_SBX_CAPTURE="$w/pane.txt")
  [ "$out" = "guest pane text" ] || fail "a running sandbox's capture should read the guest pane, got '$out'"
  assert_contains "$(cat "$w/sbx.log")" "tmux capture-pane -p -t fm:fm-x -S -40" \
    "capture should target the in-guest tmux pane with the bounded tail"

  pass "fm_backend_sbx_capture: refused while stopped, guest tmux capture while running"
}

# --- steering: resurrection sequence (design §8.3) --------------------------

test_send_resurrects_dead_guest_stack() {
  local w fb log
  w=$(new_sbx_world resurrect); fb=$(make_fake_sbx "$w")
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=/sm/home" "project=/sm/home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=/sm/home" "sbx_signals_dir=$w/signals/x"

  # Post-auto-stop shape: the sandbox reads running once exec'd, but the guest
  # tmux server is gone (has-session fails).
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    || fail "a steer of a resurrectable sandbox should succeed"
  log=$(cat "$w/sbx.log")
  assert_contains "$log" "tmux new-session -d -s fm -n fm-x -c /sm/home" \
    "resurrection must rebuild the guest tmux session at the recorded home"
  assert_contains "$log" "codex resume --last --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust" \
    "resurrection must relaunch the agent in RESUME mode with codex's hook-trust TUI gate bypassed"
  assert_contains "$log" "touch '$w/signals/x/x.turn-ended' '$w/signals/x/x.beat'" \
    "the resumed codex launch must re-wire the turn-end hook at the mount's turn-ended AND beat, shell-quoted"
  assert_contains "$log" 'notify=[\"bash\",\"-c\",\"touch ' \
    "the notify JSON's escaped quotes must reach the guest intact (bash printf formats eat them)"
  assert_contains "$log" "send-keys -t fm:fm-x steer text Enter" \
    "the original steer must still be delivered after resurrection"
  # Rebuild strictly before delivery.
  [ "$(grep -n 'new-session' "$w/sbx.log" | head -1 | cut -d: -f1)" \
    -lt "$(grep -n 'steer text' "$w/sbx.log" | head -1 | cut -d: -f1)" ] \
    || fail "resurrection must complete before the steer is delivered"

  pass "send path: dead guest stack is resurrected (tmux + resume relaunch) before delivery"
}

test_resume_template_quoting() {
  local w fb out
  w=$(new_sbx_world resume-quote); fb=$(make_fake_sbx "$w")
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_resume_template codex /sig/x.turn-ended /sig/x.beat')
  assert_contains "$out" 'codex resume --last' \
    "codex resurrection must resume the most recent session"
  assert_contains "$out" '--dangerously-bypass-hook-trust' \
    "codex resume must bypass the hook-trust TUI gate (no one is in the pane to answer it)"
  assert_contains "$out" 'notify=[\"bash\",\"-c\",\"touch '\''/sig/x.turn-ended'\'' '\''/sig/x.beat'\''\"]' \
    "the notify JSON's escaped quotes and shell-quoted paths must survive template construction (bash printf formats eat \\\" - verified live)"
  pass "fm_backend_sbx_resume_template: notify quoting intact, paths shell-quoted, hook trust bypassed"
}

test_resurrection_waits_for_stable_pane() {
  local w fb log resume_line ready_line steer_line
  w=$(new_sbx_world resurrect-ready); fb=$(make_fake_sbx "$w")
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=/sm/home" "project=/sm/home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=/sm/home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  printf 'restored transcript\n' > "$w/pane.txt"
  : > "$w/sbx.log"
  # A resumed TUI drops keys while it redraws (observed live): delivery must
  # wait for pane stability - the ready poll's capture-pane reads land
  # between the resume relaunch and the steer.
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    FM_FAKE_SBX_CAPTURE="$w/pane.txt" FM_SBX_RESURRECT_READY_TRIES=3 \
    || fail "a steer with the ready poll enabled should still succeed"
  log=$(cat "$w/sbx.log")
  assert_contains "$log" "tmux capture-pane" \
    "the ready poll must read the pane before delivering"
  resume_line=$(grep -n 'codex resume' "$w/sbx.log" | head -1 | cut -d: -f1)
  ready_line=$(grep -n 'capture-pane' "$w/sbx.log" | head -1 | cut -d: -f1)
  steer_line=$(grep -n 'steer text' "$w/sbx.log" | head -1 | cut -d: -f1)
  [ "$resume_line" -lt "$ready_line" ] && [ "$ready_line" -lt "$steer_line" ] \
    || fail "the ready poll must run after the resume relaunch and before delivery"
  pass "send path: resurrection waits for a stable pane before delivering the steer"
}

test_resurrection_refuses_dead_pane_delivery() {
  local w fb
  w=$(new_sbx_world resurrect-dead); fb=$(make_fake_sbx "$w")
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=/sm/home" "project=/sm/home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=/sm/home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  # The resume died back to the guest shell (FG=bash). Delivering there would
  # EXECUTE the steer text as a shell command on the guest (observed live
  # before the foreground check existed).
  if run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 FM_FAKE_SBX_FG=bash 2>/dev/null; then
    fail "a resurrection whose pane stays on the guest shell must fail, not deliver"
  fi
  assert_not_contains "$(cat "$w/sbx.log")" "steer text" \
    "the steer text must never be typed into a dead (shell) pane"
  pass "send path: a failed resume (pane still a shell) is refused loudly, nothing delivered"
}

# --- send_text_submit: verify-and-retry (resume-time notices eat keys) ------

test_submit_confirms_busy_pane() {
  local w fb out
  w=$(new_sbx_world submit-ok); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  { printf '%s steer text and more\n' '> [marker]'; printf 'esc to interrupt\n'; } > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "> [marker] steer text and more words" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt")
  [ "$out" = submitted ] || fail "a pane showing the text and the busy footer should confirm the submit, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -eq 1 ] \
    || fail "a confirmed submit must have typed the text exactly once"
  pass "send_text_submit: text visible + busy pane -> submitted, typed once"
}

test_submit_retypes_when_text_swallowed() {
  local w fb out
  w=$(new_sbx_world submit-eaten); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  # The pane never shows the text - the resume-time-notice swallow observed
  # live: the delivery must be retyped, not just re-Entered.
  printf 'some other pane content\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "steer text that vanished" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt")
  [ "$out" = unknown ] || fail "an unconfirmable submit should stay conservative (unknown), got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -ge 2 ] \
    || fail "swallowed text must be retyped on retry"
  assert_contains "$(cat "$w/sbx.log")" "send-keys -t fm:fm-x C-u" \
    "a retype must clear any partial composer state first"
  pass "send_text_submit: swallowed text is cleared and retyped, verdict stays unknown"
}

test_submit_reenters_when_enter_swallowed() {
  local w fb out
  w=$(new_sbx_world submit-reenter); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  # Text sits in the composer (visible, pane not busy): Enter was eaten -
  # re-send Enter only, NEVER type the text a second time.
  printf '> steer text still in composer\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "steer text still in composer" 2 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt")
  [ "$out" = unknown ] || fail "text stuck in the composer never confirms, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -eq 1 ] \
    || fail "the text must be typed exactly once (no-double-text rule)"
  [ "$(grep -c 'send-keys -t fm:fm-x Enter' "$w/sbx.log")" -ge 2 ] \
    || fail "a swallowed Enter must be re-sent"
  pass "send_text_submit: swallowed Enter re-sends Enter only, text typed once"
}

test_send_starts_keepalive_after_delivery() {
  local w fb
  w=$(new_sbx_world keepalive); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  # sbx auto-stop is host-connection-based: a delivered steer starts a guest
  # turn that dies with the VM unless one exec stays pinned until the turn
  # ends. The keeper is fire-and-forget, so give its async log line a beat.
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"; sleep 0.5' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 \
    || fail "a steer with keep-alive enabled should succeed"
  assert_contains "$(cat "$w/sbx.log")" "$w/signals/x/x.turn-ended 60" \
    "delivery must start a keep-alive exec watching the id's turn-ended mount file"
  pass "send path: delivery pins the VM with a turn-end-bounded keep-alive exec"
}

test_send_skips_resurrection_when_stack_alive() {
  local w fb
  w=$(new_sbx_world no-resurrect); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=0 \
    || fail "a steer of a live stack should succeed"
  assert_not_contains "$(cat "$w/sbx.log")" "new-session" \
    "a live guest stack must never be rebuilt (that would clobber the running agent)"
  pass "send path: a live guest stack is delivered to directly, never rebuilt"
}

test_send_refuses_absent_sandbox() {
  local w fb
  w=$(new_sbx_world send-absent); fb=$(make_fake_sbx "$w")
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  : > "$w/sbx.log"
  if run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/state" 2>/dev/null; then
    fail "steering a confirmed-absent sandbox must fail loudly"
  fi
  assert_not_contains "$(cat "$w/sbx.log")" "exec" \
    "an absent sandbox must not be exec'd"
  pass "send path: a confirmed-absent sandbox is refused, not exec'd"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed stub set bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-liveness.test.sh's
# make_toolchain - duplication between suites is this repo's accepted pattern).
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir/toolchain")
  fm_fake_exit0 "$fakebin" node gh gh-axi chrome-devtools-axi lavish-axi quota-axi tmux
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.1.1' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

# new_sweep_world <name>: a scratch primary home with one sbx secondmate meta
# (sm1, harness=codex so the respawn's launch template resolves without config
# lookups beyond crew-harness) plus a seeded secondmate home dir.
new_sweep_world() {
  local name=$1 w home
  w=$(new_sbx_world "$name")
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  home="$w/sm1"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  fm_write_meta "$w/home/state/sm1.meta" \
    "window=sbx:fm-sm1" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "projects=alpha" "sbx_signals_dir=$w/signals/sm1"
  printf '%s\n' "$w"
}

run_sweep() {  # <world> <fakebin> <toolchain> [env k=v...] -> stdout+stderr
  local w=$1 fb=$2 tc=$3
  shift 3
  PATH="$fb:$tc:$BASE_PATH" TMUX='' FM_BACKEND=sbx FM_HOME="$w/home" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" FM_SBX_RESURRECT_SETTLE=0 \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_leaves_stopped_secondmate_untouched() {
  local w fb tc out
  w=$(new_sweep_world sweep-stopped); fb=$(make_fake_sbx "$w"); tc=$(make_toolchain "$w")
  sbx_ls_json fm-sm1 stopped > "$w/ls.json"
  : > "$w/sbx.log"
  out=$(run_sweep "$w" "$fb" "$tc")
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a stopped (idle-resumable) secondmate is healthy and must be silent"
  assert_not_contains "$(cat "$w/sbx.log")" "rm --force" \
    "a stopped secondmate must never be removed"
  assert_not_contains "$(cat "$w/sbx.log")" "create" \
    "a stopped secondmate must never be respawned"
  pass "sweep: a stopped sbx secondmate is left untouched (no rm, no respawn)"
}

test_sweep_never_acts_on_probe_error() {
  local w fb tc out
  w=$(new_sweep_world sweep-error); fb=$(make_fake_sbx "$w"); tc=$(make_toolchain "$w")
  : > "$w/sbx.log"
  out=$(run_sweep "$w" "$fb" "$tc" FM_FAKE_SBX_LS_RC=1)
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive (backend=sbx)" \
    "an inconclusive sbx probe should be reported as skipped"
  assert_not_contains "$(cat "$w/sbx.log")" "rm --force" \
    "an inconclusive reading must NEVER remove the sandbox (would risk a duplicate agent)"
  assert_not_contains "$(cat "$w/sbx.log")" "create" \
    "an inconclusive reading must NEVER respawn"
  pass "sweep: an sbx CLI error is reported but never acted on"
}

test_sweep_respawns_confirmed_absent_secondmate() {
  local w fb tc out
  w=$(new_sweep_world sweep-absent); fb=$(make_fake_sbx "$w"); tc=$(make_toolchain "$w")
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  : > "$w/sbx.log"
  out=$(run_sweep "$w" "$fb" "$tc" \
    FM_FAKE_SBX_CREATE_JSON="$(sbx_ls_json fm-sm1 running)")
  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed" \
    "the respawn of a confirmed-absent secondmate should succeed: $out"
  assert_contains "$(cat "$w/sbx.log")" "create --clone --name fm-sm1 codex" \
    "a confirmed-absent secondmate should be re-provisioned through the sbx spawn branch"
  pass "sweep: a confirmed-absent sbx secondmate is respawned"
}

# --- teardown: in-guest landed-work check (fm_backend_sbx_unlanded_work) -----
#
# fm_backend_sbx_kill's `sbx rm --force` destroys the whole VM, including the
# in-guest clone where a secondmate's real work lives. fm-teardown.sh's
# landed-work contract requires verifying that work landed BEFORE the kill; the
# host git checks cannot see inside the VM, so the adapter probes the guest.
# Safe (rc 0) only for a clean, fully-pushed guest or a confirmed-absent
# sandbox; every other reading - dirty, unpushed, unreadable - is UNSAFE
# (rc 1, fail-safe), mirroring the host worktree safety check.

test_unlanded_work_clean_guest_is_safe() {
  local w fb
  w=$(new_sbx_world unlanded-clean); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  # Clean guest: git status and git log both empty (GIT_STATUS/GIT_LOG unset).
  run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
    || fail "a clean, fully-pushed guest must be safe to destroy (rc 0)"
  assert_contains "$(cat "$w/sbx.log")" "git -C /guest/home status --porcelain" \
    "a running guest must be inspected for uncommitted changes"
  pass "unlanded_work: clean + pushed guest -> safe (rc 0)"
}

test_unlanded_work_dirty_guest_refuses() {
  local w fb out
  w=$(new_sbx_world unlanded-dirty); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
      FM_FAKE_SBX_GIT_STATUS=" M charter.md"); then
    fail "a guest with uncommitted changes must be refused (rc 1)"
  fi
  assert_contains "$out" "uncommitted changes" \
    "the refusal reason must name the uncommitted in-guest changes"
  pass "unlanded_work: dirty guest -> unsafe (rc 1) with a reason"
}

test_unlanded_work_untracked_claude_file_refuses() {
  local w fb out
  w=$(new_sbx_world unlanded-claude-untracked); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
      FM_FAKE_SBX_GIT_STATUS="?? .claude/notes.md"); then
    fail "an untracked .claude/ file in the guest must be refused (rc 1)"
  fi
  assert_contains "$out" "uncommitted changes" \
    "the refusal reason must name the uncommitted in-guest changes"
  pass "unlanded_work: untracked .claude/ guest file -> unsafe (rc 1)"
}

test_unlanded_work_unpushed_guest_refuses() {
  local w fb out
  w=$(new_sbx_world unlanded-unpushed); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  # Clean tree, but a commit reachable from nowhere but the VM disk.
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
      FM_FAKE_SBX_GIT_LOG="abc1234 wip in the VM"); then
    fail "a guest with commits on no remote must be refused (rc 1)"
  fi
  assert_contains "$out" "commits not on any remote" \
    "the refusal reason must name the unpushed in-guest commits"
  pass "unlanded_work: clean tree but unpushed commits -> unsafe (rc 1)"
}

test_unlanded_work_absent_is_safe() {
  local w fb
  w=$(new_sbx_world unlanded-absent); fb=$(make_fake_sbx "$w")
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
    || fail "a confirmed-absent sandbox has nothing to lose -> safe (rc 0)"
  assert_not_contains "$(cat "$w/sbx.log")" "git -C" \
    "an absent sandbox must not be exec'd to probe a VM that is already gone"
  pass "unlanded_work: confirmed-absent sandbox -> safe, no guest probe"
}

test_unlanded_work_error_state_refuses() {
  local w fb out
  w=$(new_sbx_world unlanded-error); fb=$(make_fake_sbx "$w")
  : > "$w/sbx.log"
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
      FM_FAKE_SBX_LS_RC=1); then
    fail "an unreadable sandbox state must be refused, never treated as clean (rc 1)"
  fi
  assert_contains "$out" "unreadable" \
    "the refusal reason must flag the unverifiable state"
  assert_not_contains "$(cat "$w/sbx.log")" "git -C" \
    "an unreadable state must be refused WITHOUT execing into a VM whose liveness is unknown"
  pass "unlanded_work: unreadable state -> unsafe (rc 1, fail-safe), no guest probe"
}

test_unlanded_work_git_failure_refuses() {
  local w fb out
  w=$(new_sbx_world unlanded-gitfail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
      FM_FAKE_SBX_GIT_RC=128); then
    fail "a guest whose git cannot be inspected must be refused (rc 1)"
  fi
  assert_contains "$out" "git status failed" \
    "an in-guest git failure must be reported, never silently treated as clean"
  pass "unlanded_work: in-guest git failure -> unsafe (rc 1, fail-safe)"
}

test_unlanded_work_stopped_guest_is_inspected() {
  local w fb
  w=$(new_sbx_world unlanded-stopped); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x stopped > "$w/ls.json"
  : > "$w/sbx.log"
  # A stopped VM's disk still holds the work: teardown must inspect it (exec
  # auto-starts it), unlike routine triage which leaves a stopped VM alone.
  run_adapter "$fb" "$w" 'fm_backend_sbx_unlanded_work sbx:fm-x /guest/home' \
    || fail "a stopped-but-clean guest is safe once inspected (rc 0)"
  assert_contains "$(cat "$w/sbx.log")" "git -C /guest/home status --porcelain" \
    "a STOPPED VM's disk holds the work, so teardown must inspect it, not skip it"
  pass "unlanded_work: a stopped VM is inspected (its disk holds the work), not skipped"
}

test_unlanded_work_dispatcher_routes() {
  local w fb out
  w=$(new_sbx_world unlanded-dispatch); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  # The generic dispatcher routes sbx to the adapter probe...
  if out=$(run_adapter "$fb" "$w" 'fm_backend_unlanded_work sbx sbx:fm-x /guest/home' \
      FM_FAKE_SBX_GIT_STATUS=" M x"); then
    fail "the dispatcher must route sbx to the in-guest probe (rc 1 on a dirty guest)"
  fi
  assert_contains "$out" "uncommitted changes" "sbx must reach fm_backend_sbx_unlanded_work"
  # ...and a host-worktree backend has no hidden VM, so it answers "safe".
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_unlanded_work tmux fm-x /guest/home' \
    || fail "a host-worktree backend has no hidden in-VM work -> safe (rc 0)"
  assert_not_contains "$(cat "$w/sbx.log")" "git -C" \
    "a non-sbx backend must never probe a guest (it has none)"
  pass "fm_backend_unlanded_work: routes sbx to the adapter, non-sbx answers safe"
}

# --- teardown integration: real fm-teardown.sh over an sbx secondmate --------

# new_teardown_world <name>: a parent firstmate home with one sbx secondmate
# (id `domain`) whose plain-clone home is a sibling dir, and NO host-side child
# metas - so fm-teardown.sh's host in-flight check passes and the in-guest
# landed-work probe is the gate under test.
new_teardown_world() {  # <name>
  local name=$1 w home subhome
  w=$(new_sbx_world "$name")
  home="$w/home"; subhome="$w/subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  touch "$home/state/.last-watcher-beat"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' \
    > "$home/data/secondmates.md"
  fm_write_meta "$home/state/domain.meta" \
    "window=sbx:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$subhome" "projects=alpha" "sbx_signals_dir=$w/signals/domain"
  printf '%s\n' "$w"
}

# run_teardown_sbx <world> <fakebin> <extra-args> [env k=v...]: run the real
# fm-teardown.sh over the world's `domain` secondmate, fake sbx first in PATH.
run_teardown_sbx() {  # <world> <fakebin> <extra> [env k=v...]
  local w=$1 fb=$2 extra=$3
  shift 3
  PATH="$fb:$PATH" FM_HOME="$w/home" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" \
    env "$@" "$ROOT/bin/fm-teardown.sh" domain $extra 2>&1
}

test_teardown_refuses_unlanded_guest() {
  local w fb out rc
  w=$(new_teardown_world teardown-refuse); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-domain running > "$w/ls.json"
  : > "$w/sbx.log"
  set +e
  out=$(run_teardown_sbx "$w" "$fb" "" FM_FAKE_SBX_GIT_STATUS=" M charter.md")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown must refuse an sbx secondmate with uncommitted in-guest work: $out"
  assert_contains "$out" "in-guest work that teardown would destroy" \
    "the refusal must name the in-guest hazard"
  assert_not_contains "$(cat "$w/sbx.log")" "rm --force" \
    "a refused teardown must NEVER destroy the VM"
  [ -d "$w/subhome" ] || fail "a refused teardown must preserve the secondmate home"
  [ -e "$w/home/state/domain.meta" ] || fail "a refused teardown must preserve the parent meta"
  pass "teardown: sbx secondmate with unlanded in-guest work is refused, VM and home preserved"
}

test_teardown_allows_clean_guest() {
  local w fb out rc
  w=$(new_teardown_world teardown-allow); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-domain running > "$w/ls.json"
  : > "$w/sbx.log"
  set +e
  out=$(run_teardown_sbx "$w" "$fb" "")   # clean guest: GIT_STATUS/GIT_LOG unset
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a clean-guest sbx secondmate should succeed: $out"
  assert_contains "$(cat "$w/sbx.log")" "rm --force fm-domain" \
    "a clean, pushed guest lets teardown destroy the VM"
  [ ! -d "$w/subhome" ] || fail "teardown should remove the retired secondmate home"
  [ ! -e "$w/home/state/domain.meta" ] || fail "teardown should clear the parent meta"
  pass "teardown: sbx secondmate with a clean, pushed guest is torn down (VM removed, home retired)"
}

test_teardown_force_skips_guest_probe() {
  local w fb out rc
  w=$(new_teardown_world teardown-force); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-domain running > "$w/ls.json"
  : > "$w/sbx.log"
  # A dirty guest would REFUSE without --force; --force is the captain's
  # explicit discard authority and must skip the probe entirely.
  set +e
  out=$(run_teardown_sbx "$w" "$fb" "--force" FM_FAKE_SBX_GIT_STATUS=" M charter.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--force teardown should succeed even with a dirty guest: $out"
  assert_not_contains "$(cat "$w/sbx.log")" "status --porcelain" \
    "--force must skip the in-guest probe (the captain already authorized discard)"
  assert_contains "$(cat "$w/sbx.log")" "rm --force fm-domain" \
    "--force must still destroy the VM"
  [ ! -d "$w/subhome" ] || fail "--force teardown should remove the retired secondmate home"
  pass "teardown: --force discards an sbx secondmate without probing the guest (captain-authorized)"
}

test_state_probe_classifies
test_agent_alive_matrix
test_agent_alive_dispatcher_routes_sbx
test_target_exists_never_execs
test_capture_gated_on_running
test_send_resurrects_dead_guest_stack
test_resume_template_quoting
test_resurrection_waits_for_stable_pane
test_resurrection_refuses_dead_pane_delivery
test_submit_confirms_busy_pane
test_submit_retypes_when_text_swallowed
test_submit_reenters_when_enter_swallowed
test_send_starts_keepalive_after_delivery
test_send_skips_resurrection_when_stack_alive
test_send_refuses_absent_sandbox
test_sweep_leaves_stopped_secondmate_untouched
test_sweep_never_acts_on_probe_error
test_sweep_respawns_confirmed_absent_secondmate
test_unlanded_work_clean_guest_is_safe
test_unlanded_work_dirty_guest_refuses
test_unlanded_work_untracked_claude_file_refuses
test_unlanded_work_unpushed_guest_refuses
test_unlanded_work_absent_is_safe
test_unlanded_work_error_state_refuses
test_unlanded_work_git_failure_refuses
test_unlanded_work_stopped_guest_is_inspected
test_unlanded_work_dispatcher_routes
test_teardown_refuses_unlanded_guest
test_teardown_allows_clean_guest
test_teardown_force_skips_guest_probe

echo "# all fm-backend-sbx tests passed"
