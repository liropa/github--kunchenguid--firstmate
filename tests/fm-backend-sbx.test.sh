#!/usr/bin/env bash
# tests/fm-backend-sbx.test.sh - the sbx (Docker Sandboxes) backend adapter:
# bin/backends/sbx.sh's state probe, the three-valued agent-liveness mapping,
# state-gated capture, steering resurrection, delivery-edge and keep-alive
# contracts, control-input scope, and bin/fm-bootstrap.sh's
# secondmate_liveness_sweep acting on sbx verdicts.
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
#   - Turn-submitting sends publish a pre-injection delivery edge and start a
#     keep-alive; literal typing and control keys do neither.
#   - Verified-submit retries preserve the conservative delivery edge, and
#     keep-alives pin visible child work while classifying suspicious exits.
#   - The session-start liveness sweep respawns an sbx secondmate only on
#     confirmed-absent, leaves running/stopped untouched, and reports an
#     inconclusive probe as skipped without acting.
set -u

# shellcheck source=tests/sbx-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sbx-helpers.sh"

# The marker-filename key the adapter writes with, so assertions name the same
# files the production code does rather than re-rolling the transform.
# shellcheck source=bin/fm-state-key-lib.sh
. "$ROOT/bin/fm-state-key-lib.sh"

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

# --- agent flavor vs driver harness (docs/sbx-backend.md) -------------------
#
# The sandbox's agent FLAVOR decides which vendor credential the guest can
# resolve; the driver HARNESS decides which CLI firstmate launches in the
# pane. Measured 2026-07-27: a claude-flavor sandbox 401s in-guest codex,
# while a codex-flavor sandbox serves both drivers - so the flavor must be
# pinnable apart from the driver, and an unservable pairing must refuse before
# a VM exists rather than after the guest's first authenticated call fails.

test_agent_flavor_defaults_to_the_driver() {
  local w fb out
  w=$(new_sbx_world flavor-default); fb=$(make_fake_sbx "$w")

  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness claude')
  [ "$out" = claude ] || fail "an unpinned claude driver must resolve the claude flavor, got '$out'"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness codex')
  [ "$out" = codex ] || fail "an unpinned codex driver must resolve the codex flavor, got '$out'"
  # An EMPTY pin is not a pin: the liveness sweep passes FM_SBX_AGENT="" for
  # every meta with no recorded flavor, exactly as it does for the template.
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness claude' FM_SBX_AGENT=)
  [ "$out" = claude ] || fail "an empty FM_SBX_AGENT must resolve exactly like an unset one, got '$out'"

  pass "fm_backend_sbx_agent_for_harness: unpinned resolution is the 1:1 driver map (existing spawns unchanged)"
}

test_agent_flavor_pin_is_independent_of_the_driver() {
  local w fb out
  w=$(new_sbx_world flavor-pin); fb=$(make_fake_sbx "$w")

  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness claude' FM_SBX_AGENT=codex)
  [ "$out" = codex ] || fail "FM_SBX_AGENT must pin the flavor independently of the driver, got '$out'"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness codex' FM_SBX_AGENT=codex)
  [ "$out" = codex ] || fail "a pin matching the driver's own flavor must resolve normally, got '$out'"

  pass "fm_backend_sbx_agent_for_harness: FM_SBX_AGENT=codex backs a claude driver (codex credentials kept alive for review)"
}

test_agent_flavor_refuses_pairings_it_cannot_serve() {
  local w fb out rc
  w=$(new_sbx_world flavor-refuse); fb=$(make_fake_sbx "$w")

  rc=0
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness codex' FM_SBX_AGENT=claude 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a claude flavor must be refused for a codex driver (in-guest codex 401s there)"
  assert_contains "$out" "cannot serve a 'codex' driver" \
    "the refusal should name the concrete unservable pairing"
  assert_contains "$out" "this flavor serves: claude" \
    "the refusal should name what the flavor DOES serve, so the operator can act on it"

  rc=0
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness claude' FM_SBX_AGENT=shell 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unsupported agent flavor must be refused"
  assert_contains "$out" "FM_SBX_AGENT='shell' is not a supported sbx agent flavor (supported: claude codex)" \
    "the refusal should name the offending value and the supported flavor set"

  # The pre-existing driver gate is unchanged: an unverified harness is still
  # refused on the harness, not misreported as a flavor problem.
  rc=0
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_agent_for_harness pi' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unverified driver harness must still be refused"
  assert_contains "$out" "harness 'pi' is not verified on the sbx backend (supported: claude codex)" \
    "an unverified harness must still refuse on the harness gate"

  [ ! -s "$w/sbx.log" ] || fail "flavor resolution must never touch the sbx CLI: $(cat "$w/sbx.log")"
  pass "fm_backend_sbx_agent_for_harness: unsupported flavors and unservable pairings refuse with concrete messages"
}

test_create_task_refuses_unservable_flavor_before_anything_exists() {
  local w fb out rc=0
  w=$(new_sbx_world flavor-create-refuse); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/sm"

  out=$(run_adapter "$fb" "$w" \
    'fm_backend_sbx_create_task fm-x '"$w"'/sm codex '"$w"'/signals/sm' FM_SBX_AGENT=claude 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse a flavor that cannot serve the driver"
  assert_contains "$out" "cannot serve a 'codex' driver" \
    "create_task's refusal should carry the resolver's concrete message"
  [ ! -s "$w/sbx.log" ] || fail "the refusal must land before ANY sbx CLI call: $(cat "$w/sbx.log")"
  [ ! -d "$w/signals/sm" ] || fail "the refusal must land before the signal directory is created"

  pass "fm_backend_sbx_create_task: an unservable pairing refuses before any sandbox, signal dir, or guest state exists"
}

test_create_task_creates_with_the_pinned_flavor() {
  local w fb
  w=$(new_sbx_world flavor-create); fb=$(make_fake_sbx "$w")
  mkdir -p "$w/sm"

  run_adapter "$fb" "$w" \
    'fm_backend_sbx_create_task fm-x '"$w"'/sm claude '"$w"'/signals/sm' FM_SBX_AGENT=codex \
    || fail "creating a codex-flavor sandbox for a claude driver should succeed"
  assert_contains "$(cat "$w/sbx.log")" "create --clone --name fm-x codex $w/sm $w/signals/sm" \
    "sbx create must receive the PINNED flavor, not the driver's own"

  pass "fm_backend_sbx_create_task: the pinned flavor is what sbx create receives"
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
  local w fb home log
  w=$(new_sbx_world resurrect); fb=$(make_fake_sbx "$w")
  # A real fixture home: the fake executes the provisioning re-assert for
  # real (clone mode guarantees the guest home exists - sbx create made it).
  home="$w/sm"
  mkdir -p "$home"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"

  # Post-auto-stop shape: the sandbox reads running once exec'd, but the guest
  # tmux server is gone (has-session fails).
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    || fail "a steer of a resurrectable sandbox should succeed"
  log=$(cat "$w/sbx.log")
  assert_contains "$log" "tmux new-session -d -s fm -n fm-x -c $home" \
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
  local w fb home log resume_line ready_line steer_line
  w=$(new_sbx_world resurrect-ready); fb=$(make_fake_sbx "$w")
  home="$w/sm"
  mkdir -p "$home"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
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
  local w fb home
  w=$(new_sbx_world resurrect-dead); fb=$(make_fake_sbx "$w")
  home="$w/sm"
  mkdir -p "$home"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
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

test_resurrection_reasserts_guest_home() {
  local w fb home log provision_line resume_line
  w=$(new_sbx_world reassert); fb=$(make_fake_sbx "$w")
  home="$w/sm"
  mkdir -p "$home/config" "$home/data"
  # Guest self-harm shapes the re-assert must heal (guest-home provisioning
  # design §4.3/§7): an inherited item replaced by a guest-local regular file
  # (its own crew would drift from the primary), and the identity marker
  # replaced by a symlink (fm_root_is_secondmate_home hard-refuses [ -L ]).
  printf 'local-drift\n' > "$home/config/crew-harness"
  ln -sfn /nonexistent "$home/.fm-secondmate-home"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    || fail "a steer of a resurrectable sandbox should succeed"
  [ -L "$home/config/crew-harness" ] \
    || fail "the re-assert must restore the read-through symlink over guest-local drift"
  [ "$(readlink "$home/config/crew-harness")" = /run/sandbox/source/config/crew-harness ] \
    || fail "the restored link must point at the RO source mount"
  [ ! -L "$home/.fm-secondmate-home" ] \
    || fail "the re-assert must replace a symlinked marker with a regular file"
  [ -f "$home/.fm-secondmate-home" ] \
    || fail "the re-assert must seed the identity marker"
  [ "$(cat "$home/.fm-secondmate-home")" = x ] \
    || fail "the marker content should be the task id, got '$(cat "$home/.fm-secondmate-home")'"
  log=$(cat "$w/sbx.log")
  assert_contains "$log" "ln -sfn" \
    "resurrection must run the provisioning re-assert through a guest exec"
  provision_line=$(grep -n 'ln -sfn' "$w/sbx.log" | head -1 | cut -d: -f1)
  resume_line=$(grep -n 'codex resume' "$w/sbx.log" | head -1 | cut -d: -f1)
  [ "$provision_line" -lt "$resume_line" ] \
    || fail "the re-assert must run before the agent relaunch"
  pass "send path: resurrection re-asserts the guest home's read path (links + marker) before relaunch"
}

test_resurrection_reasserts_claude_trust() {
  local w fb home guest_user cfg
  w=$(new_sbx_world reassert-trust); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data" "$guest_user"
  # `sbx` was measured to write projects["/"] at CREATE only, so a spawn-time
  # revoke holds today (docs/sbx-backend.md, fork issue #40). Re-asserting on
  # resurrection is what makes that independent of upstream behaviour firstmate
  # does not control, and lets a guest that skipped the pass heal later. The
  # fixture therefore plants the root grant back and expects it gone again.
  printf '%s\n' '{"projects":{"/":{"hasTrustDialogAccepted":true}}}' > "$guest_user/.claude.json"
  cfg="$guest_user/.claude.json"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"
  assert_not_contains "$(cat "$cfg")" '"/"' \
    "resurrection must revoke a guest-wide root grant it finds, not only spawn"
  assert_contains "$(cat "$cfg")" "$home" \
    "resurrection must (re)grant the guest home, or the relaunch parks on the trust dialog"
  assert_contains "$(cat "$cfg")" "$guest_user/.no-mistakes/worktrees" \
    "resurrection must (re)grant the gate worktree root"
  pass "send path: resurrection re-asserts the claude workspace-trust shape before relaunch"
}

test_resurrection_skips_claude_trust_for_a_codex_guest() {
  local w fb home guest_user
  w=$(new_sbx_world reassert-trust-codex); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data" "$guest_user"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"
  [ ! -e "$guest_user/.claude.json" ] \
    || fail "resurrecting a codex guest must not write claude state into it"
  assert_not_contains "$(cat "$w/sbx.log")" ".no-mistakes/worktrees" \
    "the reconcile must be gated on the harness, not spent on every resurrection"
  pass "send path: resurrecting a codex guest spends no claude trust reconcile"
}

# --- guest no-mistakes daemon restore ----------------------------------------
#
# Auto-stop kills the guest process tree, so a resurrected guest came back with
# its in-guest no-mistakes daemon dead and its socket left behind; every
# validation call then failed with `connect: connection refused` until
# firstmate started the daemon by hand. Resurrection now restores it at the
# pre-agent safe point (docs/sbx-backend.md "Guest no-mistakes daemon
# restore").
#
# The two directions are NOT equally costly, and the suite is weighted the way
# the risk is. One daemon instance serves every lane in its VM, so wrongly
# restarting a LIVE one destroys other lanes' in-flight runs, while leaving a
# dead one dead merely restores the manual round trip we had. The
# leave-a-live-daemon-alone cases therefore assert the DAMAGE (an in-flight run
# file the fake deletes on any lifecycle command) rather than only the absence
# of a log line.

# nm_world <name>: an sbx world with a guest-user $HOME whose gate root exists,
# a fake no-mistakes in the given state, and a codex secondmate meta ready to
# resurrect. Echoes "<world> <fakebin> <nmbin> <guest-user-home>".
nm_world() {  # <name> <state>
  local w fb nmbin home guest_user
  w=$(new_sbx_world "$1"); fb=$(make_fake_sbx "$w"); nmbin=$(make_fake_no_mistakes "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data" "$guest_user/.no-mistakes"
  printf '%s\n' "$2" > "$w/nm.state"
  : > "$w/nm.log"
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  printf '%s %s %s %s\n' "$w" "$fb" "$nmbin" "$guest_user"
}

# nm_steer <world> <fakebin> <nmbin> <guest-user-home> [extra env...]: resurrect
# and steer fm-x (FM_FAKE_SBX_TMUX_HAS_RC=1 is the post-auto-stop guest).
nm_steer() {
  local w=$1 fb=$2 nmbin=$3 guest_user=$4
  shift 4
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    FM_FAKE_NM_STATE_FILE="$w/nm.state" FM_FAKE_NM_LOG="$w/nm.log" "$@"
}

test_resurrection_restores_dead_gate_daemon_with_stale_socket() {
  local w fb nmbin guest_user restore_line resume_line
  read -r w fb nmbin guest_user <<<"$(nm_world nm-stale stale-socket)"
  # The exact reported shape: the daemon is gone but its socket file is not,
  # so `no-mistakes daemon status` never reaches its "not running" wording and
  # errors out on the refused connection instead. A classifier that only
  # matched "daemon not running" would miss precisely this case.
  : > "$guest_user/.no-mistakes/socket"

  nm_steer "$w" "$fb" "$nmbin" "$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"

  assert_contains "$(cat "$w/nm.log")" "daemon start" \
    "a guest whose daemon is down behind a stale socket must be restored, not left for a manual repair"
  [ "$(cat "$w/nm.state")" = running ] \
    || fail "the restore must leave the guest daemon actually serving, got '$(cat "$w/nm.state")'"
  restore_line=$(grep -n 'no-mistakes daemon status' "$w/sbx.log" | head -1 | cut -d: -f1)
  resume_line=$(grep -n 'codex resume' "$w/sbx.log" | head -1 | cut -d: -f1)
  [ -n "$restore_line" ] && [ "$restore_line" -lt "$resume_line" ] \
    || fail "the restore must run before the agent relaunch, so the resumed agent finds a live daemon"
  pass "resurrection: a daemon down behind a stale socket is restored before the relaunch"
}

test_resurrection_never_unlinks_the_guest_daemon_socket() {
  local w fb nmbin guest_user
  read -r w fb nmbin guest_user <<<"$(nm_world nm-socket stale-socket)"
  : > "$guest_user/.no-mistakes/socket"

  nm_steer "$w" "$fb" "$nmbin" "$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"

  # A firstmate-side unlink is the ONLY thing here that could race a daemon
  # coming up concurrently - removing the inode out from under a listener
  # leaves it serving a socket no client can reach. The fix declines to create
  # that race: `no-mistakes daemon start` owns the file under its own lock.
  [ -e "$guest_user/.no-mistakes/socket" ] \
    || fail "firstmate must never unlink the guest daemon socket; only no-mistakes may, under its own lock"
  pass "resurrection: the guest daemon socket is never unlinked host-side (no cleanup, no race)"
}

test_resurrection_restores_dead_gate_daemon_with_no_socket() {
  local w fb nmbin guest_user
  read -r w fb nmbin guest_user <<<"$(nm_world nm-down down)"

  nm_steer "$w" "$fb" "$nmbin" "$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"

  assert_contains "$(cat "$w/nm.log")" "daemon start" \
    "a plainly down daemon is the same stranded guest, just without the leftover socket"
  [ "$(cat "$w/nm.state")" = running ] \
    || fail "the restore must leave the guest daemon actually serving, got '$(cat "$w/nm.state")'"
  pass "resurrection: a daemon reported plainly not-running is restored too"
}

# THE case that matters most. A wrongly-restarted daemon destroys every lane's
# in-flight run in that VM; a daemon left down costs one supervision round
# trip. Both sub-cases assert the run file, so a regression fails on the
# damage, not on a log string that could be silently reworded.
test_resurrection_never_restarts_a_running_gate_daemon() {
  local w fb nmbin guest_user log
  read -r w fb nmbin guest_user <<<"$(nm_world nm-live running)"

  # (a) a live daemon serving nothing in particular
  nm_steer "$w" "$fb" "$nmbin" "$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"
  log=$(cat "$w/nm.log")
  assert_contains "$log" "daemon status" \
    "the restore must probe before deciding anything"
  assert_not_contains "$log" "daemon start" \
    "a LIVE daemon must never be started/restarted - that kills every other lane in the VM"
  assert_not_contains "$log" "daemon stop" \
    "the restore must never stop a daemon"
  assert_not_contains "$log" "daemon restart" \
    "the restore must never restart a daemon"

  # (b) the same live daemon with a pipeline run in flight. The fake deletes
  # the run file on ANY lifecycle command, so this asserts the consequence.
  read -r w fb nmbin guest_user <<<"$(nm_world nm-live-inflight running)"
  printf 'run 01KYPG4E22ZN03GF19NXV2KRDQ\n' > "$w/nm.run"
  nm_steer "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_NM_RUN_FILE="$w/nm.run" \
    || fail "a steer of a resurrectable sandbox should succeed"
  [ -e "$w/nm.run" ] \
    || fail "resurrection destroyed an in-flight pipeline run by restarting a live daemon"
  assert_not_contains "$(cat "$w/nm.log")" "daemon start" \
    "an in-flight run must not even be exposed to a lifecycle command"
  [ "$(cat "$w/nm.state")" = running ] \
    || fail "a live daemon's state must come out exactly as it went in"
  pass "resurrection: a running daemon is left untouched, in-flight run intact"
}

test_resurrection_leaves_an_unrecognized_daemon_status_alone() {
  local w fb nmbin guest_user err
  read -r w fb nmbin guest_user <<<"$(nm_world nm-garbage garbage)"
  printf 'run 01KYPG4E22ZN03GF19NXV2KRDQ\n' > "$w/nm.run"

  err=$(nm_steer "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_NM_RUN_FILE="$w/nm.run" 2>&1 >/dev/null) \
    || fail "a steer of a resurrectable sandbox should succeed"

  # Only two outputs positively mean "down". An upstream rewording must fall
  # through to leaving the daemon alone and saying so, never to guessing.
  assert_not_contains "$(cat "$w/nm.log")" "daemon start" \
    "an unreadable verdict must not be acted on; it could be a live daemon"
  [ -e "$w/nm.run" ] || fail "an unreadable verdict must not cost an in-flight run"
  assert_contains "$err" "unrecognized no-mistakes daemon status" \
    "an unreadable verdict must be reported, not swallowed"
  pass "resurrection: an unrecognized daemon status is reported and left strictly alone"
}

test_resurrection_skips_the_daemon_restore_without_a_gate_root() {
  local w fb nmbin guest_user
  read -r w fb nmbin guest_user <<<"$(nm_world nm-nogate down)"
  # A guest that has never run the gate has no dead daemon to restore and
  # nothing stale to clear, so the pass stays narrower than "start a daemon in
  # every guest" - it must not even probe.
  rmdir "$guest_user/.no-mistakes"

  nm_steer "$w" "$fb" "$nmbin" "$guest_user" \
    || fail "a steer of a resurrectable sandbox should succeed"

  # Scoped to daemon lifecycle, not to every no-mistakes call: the cross-vendor
  # gate assertion runs `doctor` on the same resurrection, and deliberately does
  # NOT wait for a gate root - a guest whose first gate run has not happened yet
  # is exactly the one whose first review must not be a self-review.
  assert_not_contains "$(cat "$w/nm.log")" "daemon" \
    "a guest with no gate root must have no daemon probed or started"
  pass "resurrection: a guest that never ran the gate gets no daemon probe at all"
}

test_resurrection_reports_a_gate_root_with_no_cli() {
  local w fb nmbin guest_user err
  read -r w fb nmbin guest_user <<<"$(nm_world nm-nocli down)"
  # A guest with a gate root but no reachable CLI genuinely uses the gate, so a
  # silent skip would hide the restore never firing at all.
  nmbin="$w/absent-nmbin"

  err=$(nm_steer "$w" "$fb" "$nmbin" "$guest_user" 2>&1 >/dev/null) \
    || fail "a steer of a resurrectable sandbox should succeed"

  assert_contains "$err" "no no-mistakes on the exec PATH" \
    "a gate-using guest whose CLI cannot be reached must say so, not skip silently"
  pass "resurrection: a gate root with no reachable CLI is reported, not silently skipped"
}

test_resurrection_survives_a_failed_daemon_restore() {
  local w fb nmbin guest_user err
  read -r w fb nmbin guest_user <<<"$(nm_world nm-execfail down)"

  # The steer is the priority: a guest that cannot be probed is exactly the
  # guest we have today, and refusing the steer over it would be a regression.
  err=$(nm_steer "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_SBX_NM_RC=1 2>&1 >/dev/null) \
    || fail "a daemon restore that cannot run must not abandon the steer"
  assert_contains "$err" "daemon restore did not complete" \
    "a failed restore must name itself, so the round trip it costs is not a mystery"
  assert_contains "$(cat "$w/sbx.log")" "codex resume" \
    "the agent must still be relaunched after a failed restore"

  # A start that runs but yields no serving daemon is the same honesty rule.
  read -r w fb nmbin guest_user <<<"$(nm_world nm-inert down)"
  err=$(nm_steer "$w" "$fb" "$nmbin" "$guest_user" FM_FAKE_NM_START_INERT=1 2>&1 >/dev/null) \
    || fail "an ineffective start must not abandon the steer"
  assert_contains "$err" "still not answering" \
    "a start that did not produce a serving daemon must be reported as such"
  pass "resurrection: a failed or ineffective daemon restore is reported, never fatal to the steer"
}

test_live_stack_delivery_spends_no_daemon_restore() {
  local w fb nmbin guest_user
  read -r w fb nmbin guest_user <<<"$(nm_world nm-livestack running)"
  printf 'run 01KYPG4E22ZN03GF19NXV2KRDQ\n' > "$w/nm.run"

  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=0 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" FM_FAKE_SBX_NM_BIN="$nmbin" \
    FM_FAKE_NM_STATE_FILE="$w/nm.state" FM_FAKE_NM_LOG="$w/nm.log" \
    FM_FAKE_NM_RUN_FILE="$w/nm.run" \
    || fail "a steer of a live stack should succeed"

  # Resurrect-only cost, and resurrect-only reach: a guest whose stack is up is
  # running its daemon and possibly a pipeline run, and routine delivery must
  # not go near either.
  assert_not_contains "$(cat "$w/sbx.log")" "no-mistakes daemon status" \
    "the daemon restore is resurrect-only; routine delivery must not spend the exec"
  [ ! -s "$w/nm.log" ] || fail "routine delivery must not touch the guest daemon: $(cat "$w/nm.log")"
  [ -e "$w/nm.run" ] || fail "routine delivery must never disturb an in-flight run"
  pass "send path: a live guest stack spends no daemon restore and never touches the daemon"
}

# --- guest shell-profile env (docs/sbx-backend.md "Guest shell-profile env") -
#
# sbx plants CLAUDE_CODE_OAUTH_TOKEN into the guest env once, at sandbox
# creation, and the claude agent does not pass it down to the processes it
# spawns - so an in-guest daemon the agent starts comes up unauthenticated
# (401), while interactive sessions in the same VM authenticate fine. The
# provisioning pass re-supplies it at shell init. These tests drive the real
# callers and then measure what an AGENT-SPAWNED child actually inherits;
# asserting that a line was written to a file would have passed before the bug
# existed. The guest-user-home fixture and the agent-child probe are shared
# with tests/fm-spawn-sbx.test.sh, so they live in tests/sbx-helpers.sh.

# steer_with_guest_env <fakebin> <world> <home> <guest-user-home> [env k=v...]:
# resurrect and steer sbx:fm-x, which is the REAL caller of the provisioning
# pass (fm_backend_sbx_ensure_stack re-asserts it before relaunching the
# agent). Driving the provisioning function directly would skip that wiring.
steer_with_guest_env() {  # <fakebin> <world> <home> <guest-user-home> [env...]
  local fb=$1 w=$2 home=$3 guest_user=$4
  shift 4
  fm_write_meta "$w/state/x.meta" \
    "window=sbx:fm-x" "worktree=$home" "project=$home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "sbx_signals_dir=$w/signals/x"
  sbx_ls_json fm-x running > "$w/ls.json"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer text"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_TMUX_HAS_RC=1 \
    FM_FAKE_SBX_GUEST_USER_HOME="$guest_user" "$@"
}

test_guest_profiles_reinject_placeholder_into_agent_children() {
  local w fb home guest_user out
  w=$(new_sbx_world guest-env); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data"
  seed_debian_guest_user_home "$guest_user"

  # Baseline: the fixture reproduces the failing case AND its filter. An agent
  # child starts without the placeholder, and ~/.bashrc's early return really
  # does swallow everything below it for such a child.
  out=$(agent_child_var "$guest_user" bashrc)
  [ "$out" = UNSET ] \
    || fail "fixture baseline: an agent-spawned child must start with no placeholder, got '$out'"
  out=$(agent_child_var "$guest_user" bashrc FM_TEST_OPERATOR_RC_MARKER)
  [ "$out" = UNSET ] \
    || fail "fixture baseline: the non-interactive early return must swallow anything below it, got '$out'"

  steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    FM_FAKE_SBX_GUEST_ENV_TOKEN="$SBX_FAKE_PLACEHOLDER" \
    || fail "a steer of a resurrectable sandbox should succeed"

  # The regression itself: the same non-interactive, agent-spawned child now
  # inherits the placeholder, which only happens if the snippet is sourced
  # ABOVE the early return.
  out=$(agent_child_var "$guest_user" bashrc)
  [ "$out" = "$SBX_FAKE_PLACEHOLDER" ] \
    || fail "a non-interactive agent-spawned child must inherit the planted placeholder, got '$out'"
  out=$(agent_child_var "$guest_user" login)
  [ "$out" = "$SBX_FAKE_PLACEHOLDER" ] \
    || fail "a login shell must inherit the planted placeholder, got '$out'"
  out=$(agent_child_var "$guest_user" posix)
  [ "$out" = "$SBX_FAKE_PLACEHOLDER" ] \
    || fail "the snippet must parse and export under POSIX sh too, got '$out'"

  # The operator's own profile content survives untouched, and the value never
  # reaches a host-side log (it is read from the guest exec env, never passed
  # as an argument).
  assert_contains "$(cat "$guest_user/.bashrc")" "FM_TEST_OPERATOR_RC_MARKER" \
    "the operator's existing ~/.bashrc content must be preserved"
  assert_contains "$(cat "$guest_user/.profile")" "FM_TEST_OPERATOR_PROFILE_MARKER" \
    "the operator's existing ~/.profile content must be preserved"
  assert_not_contains "$(cat "$w/sbx.log")" "$SBX_FAKE_PLACEHOLDER" \
    "the token value must never appear in a host-side command line or log"

  pass "guest env: a non-interactive agent-spawned child inherits the planted placeholder"
}

test_guest_profile_seed_is_idempotent_and_yields_to_the_operator() {
  local w fb home guest_user out n
  w=$(new_sbx_world guest-env-idem); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data"
  seed_debian_guest_user_home "$guest_user"
  # An operator's own export, below where the snippet lands: it runs last and
  # must therefore win, which is what the snippet's `:=` assignment buys.
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=operator-own-value\n' >> "$guest_user/.profile"

  steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    FM_FAKE_SBX_GUEST_ENV_TOKEN="$SBX_FAKE_PLACEHOLDER" \
    || fail "the first steer should succeed"
  steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    FM_FAKE_SBX_GUEST_ENV_TOKEN="$SBX_FAKE_PLACEHOLDER" \
    || fail "a re-provisioning steer should succeed"

  for out in .bashrc .profile; do
    n=$(grep -cF '.fm-sbx-env.sh' "$guest_user/$out")
    [ "$n" -eq 1 ] \
      || fail "re-provisioning must not append a second source line to ~/$out, found $n"
  done

  # An operator value already in the child's env is never overwritten...
  # shellcheck disable=SC2016  # deliberate: the probe must expand in the CHILD shell, after ~/.bashrc ran
  out=$(env HOME="$guest_user" CLAUDE_CODE_OAUTH_TOKEN=operator-env-value bash -c \
    '. "$HOME/.bashrc"; printf "%s" "${CLAUDE_CODE_OAUTH_TOKEN-UNSET}"')
  [ "$out" = operator-env-value ] \
    || fail "an operator's already-set value must win over the planted placeholder, got '$out'"
  # ...and neither is one the operator exports from their own profile.
  out=$(agent_child_var "$guest_user" posix)
  [ "$out" = operator-own-value ] \
    || fail "an operator's own profile export must win over the planted placeholder, got '$out'"

  pass "guest env: re-provisioning is idempotent and never fights the operator's own value"
}

test_guest_profile_seed_reports_unowned_source_without_touching_profile() {
  local w fb home guest_user out
  w=$(new_sbx_world guest-env-unowned); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data"
  seed_debian_guest_user_home "$guest_user"
  printf ". \"\$HOME/.fm-sbx-env.sh\"\n" >> "$guest_user/.bashrc"
  cp "$guest_user/.bashrc" "$w/bashrc.before"

  out=$(steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    FM_FAKE_SBX_GUEST_ENV_TOKEN="$SBX_FAKE_PLACEHOLDER" 2>&1) \
    || fail "a steer with unowned profile content should still succeed: $out"

  cmp -s "$w/bashrc.before" "$guest_user/.bashrc" \
    || fail "an unowned source line must leave the operator profile byte-identical"
  assert_contains "$out" "$guest_user/.bashrc may not reach non-interactive shells" \
    "an unowned source line must be reported to stderr"
  assert_contains "$out" "not moving operator content" \
    "the diagnostic must say operator content was left alone"

  pass "guest env: unowned profile source is reported without rewriting"
}

test_guest_profile_seed_repositions_owned_stale_source_line() {
  local w fb home guest_user out n
  w=$(new_sbx_world guest-env-stale-owned); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data"
  seed_debian_guest_user_home "$guest_user"
  fm_sbx_guest_env_source_line >> "$guest_user/.bashrc"

  steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    FM_FAKE_SBX_GUEST_ENV_TOKEN="$SBX_FAKE_PLACEHOLDER" \
    || fail "a steer with a stale owned source line should still succeed"

  out=$(agent_child_var "$guest_user" bashrc)
  [ "$out" = "$SBX_FAKE_PLACEHOLDER" ] \
    || fail "a repositioned owned source line must reach non-interactive children, got '$out'"
  n=$(grep -cF '.fm-sbx-env.sh' "$guest_user/.bashrc")
  [ "$n" -eq 1 ] \
    || fail "repositioning an owned source line must not duplicate it, found $n"

  pass "guest env: stale owned source line is repositioned before early return"
}

test_guest_profile_seed_skips_absent_or_unsafe_values() {
  local w fb home guest_user
  w=$(new_sbx_world guest-env-skip); fb=$(make_fake_sbx "$w")
  home="$w/sm"; guest_user="$w/guest-user-home"
  mkdir -p "$home/config" "$home/data"
  seed_debian_guest_user_home "$guest_user"

  # No placeholder in the guest env (a template or agent type sbx plants
  # nothing for): the profiles are left exactly as the operator had them.
  steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    || fail "a steer with no planted placeholder should still succeed"
  [ ! -e "$guest_user/.fm-sbx-env.sh" ] \
    || fail "no planted placeholder means no snippet file"
  assert_not_contains "$(cat "$guest_user/.bashrc")" ".fm-sbx-env.sh" \
    "no planted placeholder means no source line"

  # A value outside the token charset is refused rather than interpolated: the
  # snippet is shell source, so an unexpected value must never become code.
  # shellcheck disable=SC2016  # deliberate: the injection attempt must stay literal here, not expand host-side
  steer_with_guest_env "$fb" "$w" "$home" "$guest_user" \
    FM_FAKE_SBX_GUEST_ENV_TOKEN='x"; touch $HOME/pwned; :"' \
    || fail "a steer with an unsafe planted value should still succeed"
  [ ! -e "$guest_user/.fm-sbx-env.sh" ] \
    || fail "a value outside the token charset must not be persisted"
  [ ! -e "$guest_user/pwned" ] \
    || fail "a value outside the token charset must never be executed"

  pass "guest env: an absent or unsafe planted value writes nothing"
}

# --- send_text_submit: verify-and-retry (resume-time notices eat keys) ------

test_submit_confirms_busy_pane() {
  local w fb out marker ack
  w=$(new_sbx_world submit-ok); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  marker="$w/state/.sbx-delivered-x"
  ack="$w/ack"
  # The pane starts WITHOUT the text (presence is judged against a pre-type
  # baseline); the echo knob renders the type, Enter starts the busy footer.
  printf 'idle notice line\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "> [marker] steer text and more words" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_TYPE_ECHO=1 FM_FAKE_SBX_ENTER_BUSY=1 \
    FM_FAKE_SBX_EXPECT_PENDING_DIR="$w/state" \
    FM_FAKE_SBX_ACK_ON_ENTER="$ack")
  [ "$out" = submitted ] || fail "a pane showing the text and the busy footer should confirm the submit, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -eq 1 ] \
    || fail "a confirmed submit must have typed the text exactly once"
  [ -e "$marker" ] && [ -e "$ack" ] \
    || fail "the confirmed submit must publish its pre-Enter delivery candidate"
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
  # Text lands in the composer (typed and rendered, pane not busy): Enter was
  # eaten - re-send Enter only, NEVER type the text a second time.
  printf 'idle notice line\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "steer text still in composer" 2 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" FM_FAKE_SBX_TYPE_ECHO=1)
  [ "$out" = unknown ] || fail "text stuck in the composer never confirms, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -eq 1 ] \
    || fail "the text must be typed exactly once (no-double-text rule)"
  [ "$(grep -c 'send-keys -t fm:fm-x Enter' "$w/sbx.log")" -ge 2 ] \
    || fail "a swallowed Enter must be re-sent"
  pass "send_text_submit: swallowed Enter re-sends Enter only, text typed once"
}

test_submit_refreshes_delivery_candidate_per_retry() {
  local w fb out
  w=$(new_sbx_world submit-fresh-edge); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  printf 'idle notice line\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "steer text still in composer" 2 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_TYPE_ECHO=1 FM_FAKE_SBX_ENTER_BUSY=1 \
    FM_FAKE_SBX_ENTER_BUSY_AFTER=2 FM_FAKE_SBX_EXPECT_PENDING_DIR="$w/state" \
    FM_FAKE_SBX_REQUIRE_FRESH_PENDING=1 FM_FAKE_SBX_ACK_ON_ENTER="$w/old-ack" \
    FM_FAKE_SBX_ACK_ON_ENTER_ONCE=1)
  [ "$out" = submitted ] || fail "the second Enter should confirm the submit, got '$out'"
  [ "$(cat "$w/sbx.log.enter-count")" -eq 2 ] \
    || fail "the fixture should exercise exactly two Enter attempts"
  [ -e "$w/old-ack" ] || fail "the first attempt should emit the older acknowledgement"
  [ -e "$w/state/.sbx-delivered-x" ] || fail "the successful retry should publish its fresh delivery edge"
  [ -z "$(find "$w/state" -name '.sbx-delivery-pending-*' -print -quit)" ] \
    || fail "the successful retry should leave no unpublished delivery candidates"
  pass "send_text_submit: each Enter retry uses a fresh delivery candidate"
}

test_submit_failure_preserves_previous_delivery_edge() {
  local w fb out marker reference
  w=$(new_sbx_world submit-enter-fail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  marker="$w/state/.sbx-delivered-x"
  reference="$w/previous-marker-time"
  touch -t 202001010000 "$marker"
  touch -r "$marker" "$reference"
  printf 'idle notice line\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "steer text" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_TYPE_ECHO=1 FM_FAKE_SBX_ENTER_RC=1)
  [ "$out" = pending ] || fail "a failed first Enter should report pending composer text, got '$out'"
  [ ! "$marker" -nt "$reference" ] && [ ! "$reference" -nt "$marker" ] \
    || fail "a totally failed submit must preserve the previous published delivery edge"
  [ -z "$(find "$w/state" -name '.sbx-delivery-pending-*' -print -quit)" ] \
    || fail "a totally failed submit should remove its unpublished candidate"
  pass "send_text_submit: total failure preserves the previous delivery edge"
}

test_submit_retype_failure_preserves_previous_delivery_edge() {
  local w fb out
  w=$(new_sbx_world submit-retype-fail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  printf 'idle notice line\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "steer text" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_TYPE_FAIL_ON=2)
  [ "$out" = unknown ] || fail "a failed retype after an Enter should report unknown, got '$out'"
  [ "$(cat "$w/sbx.log.type-count")" -eq 2 ] \
    || fail "the fixture should fail the second type attempt"
  [ "$(cat "$w/sbx.log.enter-count")" -eq 1 ] \
    || fail "the retype failure should follow exactly one successful Enter"
  [ -e "$w/state/.sbx-delivered-x" ] \
    || fail "the earlier Enter's delivery edge must be published after a failed retype"
  [ -z "$(find "$w/state" -name '.sbx-delivery-pending-*' -print -quit)" ] \
    || fail "a failed retype should leave no unpublished delivery candidate"
  pass "send_text_submit: failed retype preserves the earlier delivery edge"
}

test_submit_ignores_stale_prefix_line_in_scrollback() {
  local w fb out
  w=$(new_sbx_world submit-stale); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  # Verified live in the 5-secondmate soak: repeated steers share the needle's
  # 24-char prefix ("[fm-from-firstmate]soak turn 2" vs "... turn 3"), and the
  # previous turn's rendered steer line still sits in the captured scrollback.
  # When the freshly typed text is eaten by resume-time init, that stale line
  # must NOT read as parked/submitted - the type has to be retried, exactly as
  # if the pane never showed the text.
  printf '> [fm-from-firstmate]soak turn 2\nidle notice line\n' > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "[fm-from-firstmate]soak turn 3" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt")
  [ "$out" = unknown ] || fail "a stale-prefix match never confirms, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -ge 2 ] \
    || fail "an eaten type must be retyped even when an older steer matches the needle prefix"
  assert_contains "$(cat "$w/sbx.log")" "send-keys -t fm:fm-x C-u" \
    "the retype must clear any partial composer state first"
  pass "send_text_submit: a stale same-prefix scrollback line does not mask an eaten type"
}

test_submit_retypes_when_stale_prefix_goes_busy() {
  local w fb out
  w=$(new_sbx_world submit-stale-busy); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  { printf '> [fm-from-firstmate]soak turn 2\n'; printf 'idle notice line\n'; } > "$w/pane.txt"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "[fm-from-firstmate]soak turn 3" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" FM_FAKE_SBX_ENTER_BUSY=1)
  [ "$out" = unknown ] || fail "a busy pane with only a stale-prefix match must not confirm, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -ge 2 ] \
    || fail "a stale-prefix busy pane must still retype an eaten steer"
  assert_contains "$(cat "$w/sbx.log")" "send-keys -t fm:fm-x C-u" \
    "the retype must clear any partial composer state first"
  pass "send_text_submit: stale same-prefix busy pane does not confirm"
}

test_submit_counts_full_history_when_window_scrolls() {
  local w fb out i
  w=$(new_sbx_world submit-window-scroll); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  printf '> [fm-from-firstmate]soak turn 2\n' > "$w/pane.txt"
  i=2
  while [ "$i" -le 30 ]; do
    printf 'idle filler %s\n' "$i" >> "$w/pane.txt"
    i=$((i + 1))
  done
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "[fm-from-firstmate]soak turn 3" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_TYPE_ECHO=1 FM_FAKE_SBX_ENTER_BUSY=1)
  [ "$out" = submitted ] || fail "a new busy submit must confirm when an older prefix leaves a 30-line window, got '$out'"
  [ "$(grep -c 'send-keys -t fm:fm-x -l' "$w/sbx.log")" -eq 1 ] \
    || fail "a window-scroll confirmation must not retype"
  assert_not_contains "$(cat "$w/sbx.log")" "send-keys -t fm:fm-x C-u" \
    "a window-scroll confirmation must not clear the composer"
  pass "send_text_submit: full-history count survives 30-line window churn"
}

test_submit_fails_when_baseline_capture_fails() {
  local w fb out
  w=$(new_sbx_world submit-baseline-fail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  printf '> [fm-from-firstmate]soak turn 2\nidle notice line\n' > "$w/pane.txt"
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_submit sbx:fm-x "[fm-from-firstmate]soak turn 3" 1 0 0' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_CAPTURE="$w/pane.txt" \
    FM_FAKE_SBX_CAPTURE_FAIL_ONCE=1 2>/dev/null); then
    fail "baseline capture failure must fail before delivery, got '$out'"
  fi
  [ "$out" = send-failed ] || fail "baseline capture failure should return send-failed, got '$out'"
  assert_not_contains "$(cat "$w/sbx.log")" "send-keys -t fm:fm-x -l" \
    "baseline capture failure must not type the steer"
  pass "send_text_submit: baseline capture failure fails before typing"
}

test_send_starts_keepalive_after_delivery() {
  local w fb
  w=$(new_sbx_world keepalive); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  # sbx auto-stop is host-connection-based: a delivered steer starts guest
  # work that dies with the VM unless one exec stays pinned until the guest
  # goes idle. The keeper is fire-and-forget, so give its async log line a
  # beat. The recorded home= must ride along so the guest loop can watch the
  # guest home's state/ for child-worker signal advances.
  printf 'home=/g/home\n' > "$w/state/x.meta"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"; sleep 0.5' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 \
    || fail "a steer with keep-alive enabled should succeed"
  assert_contains "$(cat "$w/sbx.log")" "$w/signals/x/x.turn-ended 60" \
    "delivery must start a keep-alive exec watching the id's turn-ended mount file"
  assert_contains "$(cat "$w/sbx.log")" "/g/home" \
    "the keep-alive must carry the meta's recorded home for the child-signal probe"
  assert_contains "$(cat "$w/sbx.log")" "esc (to )?interrupt" \
    "the keep-alive must carry the busy-pane regex for the in-guest activity probe"
  pass "send path: delivery pins the VM with a guest-work-bounded keep-alive exec"
}

test_send_records_delivery_breadcrumb() {
  # The stranding beacon's acknowledgement clock (fm-watch.sh scan_sbx_beacon).
  # Delivery is NOT processing evidence - a send lands in the guest pane
  # whether or not the agent behind it can work - so the host records WHEN it
  # last spoke to the guest and the beacon alarms when nothing comes back.
  # Host-written and content-free by design: a guest can neither forge nor
  # suppress it, and no delivered text is ever stored.
  local w fb
  w=$(new_sbx_world delivered); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  : > "$w/sbx.log"
  # Keep-alives OFF: the acknowledgement clock must not depend on a pinned
  # connection, so the breadcrumb is written on this path too.
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "a steer with keep-alives disabled should still succeed"
  [ -f "$w/state/.sbx-delivered-x" ] \
    || fail "a delivered steer must record the beacon's delivery breadcrumb"
  [ ! -s "$w/state/.sbx-delivered-x" ] \
    || fail "the breadcrumb must stay content-free: $(cat "$w/state/.sbx-delivered-x")"
  pass "send path: delivery records the beacon's content-free acknowledgement breadcrumb"
}

test_delivery_breadcrumb_is_not_shared_by_colliding_ids() {
  # The marker key must separate two ids the superseded `tr '.' '_'` fold
  # collapsed (bin/fm-state-key-lib.sh). Sharing one breadcrumb let a steer to
  # one secondmate silence the other's unacknowledged-delivery alarm, and let
  # either one's teardown delete the other's live beacon.
  local w fb dotted under
  w=$(new_sbx_world delivered-collision); fb=$(make_fake_sbx "$w")
  : > "$w/sbx.log"
  sbx_ls_json fm-a.b running > "$w/ls.json"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-a.b "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "a steer to the dotted id should succeed"
  sbx_ls_json fm-a_b running > "$w/ls.json"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-a_b "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "a steer to the underscored id should succeed"

  dotted="$w/state/.sbx-delivered-$(fm_state_key_encode 'a.b')"
  under="$w/state/.sbx-delivered-$(fm_state_key_encode 'a_b')"
  [ "$dotted" != "$under" ] || fail "the two ids still resolve to one breadcrumb path"
  [ -f "$dotted" ] || fail "a.b's delivery breadcrumb is missing: $(ls -a "$w/state")"
  [ -f "$under" ] || fail "a_b's delivery breadcrumb is missing: $(ls -a "$w/state")"
  pass "send path: two ids the old fold collapsed publish separate delivery breadcrumbs"
}

test_delivery_breadcrumb_predates_guest_acknowledgement() {
  local w fb marker ack
  w=$(new_sbx_world delivered-before-ack); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  marker="$w/state/.sbx-delivered-x"
  ack="$w/ack"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    FM_FAKE_SBX_EXPECT_PENDING_DIR="$w/state" \
    FM_FAKE_SBX_ACK_ON_ENTER="$ack" \
    || fail "a steer with a simulated immediate acknowledgement should succeed"
  [ -e "$marker" ] || fail "delivery should publish its breadcrumb"
  [ -e "$ack" ] \
    || fail "the delivery candidate must exist when Enter emits an acknowledgement"
  pass "send path: the delivery breadcrumb causally predates an immediate guest acknowledgement"
}

test_delivery_beacon_prepare_failure_refuses_before_send() {
  local w fb out
  w=$(new_sbx_world delivered-prepare-fail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/missing/state" FM_SBX_KEEPALIVE_MAX=0 2>&1 || true)
  assert_contains "$out" "refusing to deliver untracked input" \
    "a breadcrumb preparation failure should name the undelivered outcome"
  assert_not_contains "$(cat "$w/sbx.log")" "send-keys" \
    "a delivery must not be attempted when its beacon cannot be prepared"
  pass "send path: a beacon preparation failure refuses before delivery"
}

test_delivery_beacon_publish_failure_does_not_invite_resend() {
  local w fb out rc
  w=$(new_sbx_world delivered-publish-fail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  cat > "$fb/mv" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
case "$last" in
  *.sbx-delivered-x) exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$fb/mv"
  if out=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
      FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] \
    || fail "a delivered-but-untracked send must not return a retryable transport failure"
  assert_contains "$out" "input was delivered" \
    "a publish failure should explicitly report that input was delivered"
  assert_contains "$out" "do not resend" \
    "a publish failure should explicitly prevent an unsafe duplicate resend"
  [ "$(grep -c 'send-keys' "$w/sbx.log")" -eq 1 ] \
    || fail "the delivered-but-untracked path should inject input exactly once"
  pass "send path: a post-delivery beacon failure reports untracked delivery without inviting resend"
}

test_failed_delivery_preserves_previous_breadcrumb() {
  local w fb marker reference
  w=$(new_sbx_world delivered-send-fail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  marker="$w/state/.sbx-delivered-x"
  reference="$w/previous-marker-time"
  touch -t 202001010000 "$marker"
  touch -r "$marker" "$reference"
  if run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
      FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
      FM_FAKE_SBX_SEND_RC=1 2>/dev/null; then
    fail "a failed tmux injection should remain a failed delivery"
  fi
  [ ! "$marker" -nt "$reference" ] && [ ! "$reference" -nt "$marker" ] \
    || fail "a failed delivery must restore the previous delivery edge unchanged"
  [ -z "$(find "$w/state" -name '.sbx-delivery-pending-*' -print -quit)" ] \
    || fail "a failed delivery should remove its unpublished candidate"
  pass "send path: failed injection preserves the previous delivery edge"
}

test_control_input_does_not_arm_delivery_beacon() {
  local w fb marker
  w=$(new_sbx_world delivered-control); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  marker="$w/state/.sbx-delivered-x"
  run_adapter "$fb" "$w" \
    'fm_backend_sbx_send_literal sbx:fm-x "draft"; fm_backend_sbx_send_key sbx:fm-x Escape; fm_backend_sbx_send_key sbx:fm-x C-c' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "literal and control-only input should still reach the pane"
  [ ! -e "$marker" ] \
    || fail "literal typing, Escape, and C-c must not arm a turn-delivery alarm"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_key sbx:fm-x Enter' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "standalone Enter should still reach the pane"
  [ ! -e "$marker" ] || fail "standalone Enter must not arm a turn-delivery alarm"
  run_adapter "$fb" "$w" \
    'fm_backend_sbx_send_literal sbx:fm-x "launch"; fm_backend_sbx_submit_composed sbx:fm-x' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "the explicit composed-submit path should deliver the launch"
  [ -e "$marker" ] || fail "the explicit composed-submit path must arm the turn-delivery alarm"
  pass "send path: only proven composed submission arms the delivery beacon"
}

test_send_to_foreign_name_records_no_breadcrumb() {
  # A non-fm-* sandbox has no derivable id or signal path, so nothing
  # host-side would ever see its turn end - arming an acknowledgement clock
  # that can never be acknowledged would alarm forever.
  local w fb
  w=$(new_sbx_world delivered-foreign); fb=$(make_fake_sbx "$w")
  sbx_ls_json other running > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:other "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=0 \
    || fail "a steer to a non-fm sandbox should still deliver"
  [ -z "$(find "$w/state" -name '.sbx-delivered-*' 2>/dev/null)" ] \
    || fail "a non-fm sandbox must not arm the acknowledgement clock"
  pass "send path: a non-fm sandbox records no delivery breadcrumb"
}

# --- keep-alive guest loop: pin/release logic (fork issue #12) ---------------
#
# fm_backend_sbx_keepalive_script is plain POSIX sh over stat/tmux/grep, so
# these tests execute it directly ON THE HOST with a fake tmux and real files -
# no sandbox, no fake sbx - unit-testing the exact loop the guest runs.

# make_fake_guest_tmux <fakebin>: a guest tmux whose secondmate pane (fm:1.0)
# shows the file named by FAKE_TMUX_PANE (empty/unset = idle pane). Setting
# FAKE_TMUX_PANE2 adds the in-guest crewmate's pane in its own session, the
# real layout: bin/backends/tmux.sh puts crewmate windows in session
# "firstmate" while the sbx guest agent runs in session FM_SBX_GUEST_SESSION.
make_fake_guest_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes)
    printf 'fm:1.0\n'
    [ -n "${FAKE_TMUX_PANE2:-}" ] && printf 'firstmate:1.0\n'
    ;;
  capture-pane)
    case " $* " in
      *" firstmate:1.0 "*) cat "${FAKE_TMUX_PANE2:-/dev/null}" 2>/dev/null ;;
      *) cat "${FAKE_TMUX_PANE:-/dev/null}" 2>/dev/null ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

# keepalive_home: the fixture $HOME every run of the loop below is pinned to.
# The loop's fourth arm reads the GUEST's own $HOME/.no-mistakes/logs, so an
# unpinned run would read the HOST's real gate logs and a live local
# no-mistakes run would flip unrelated fixtures from idle to active. The
# default names a path that does not exist, so the arm is off unless a test
# opts in by setting KEEPALIVE_HOME to a fixture it built.
keepalive_home() {
  printf '%s' "${KEEPALIVE_HOME:-$TMP_ROOT/no-such-guest-home}"
}

# keepalive_auth_regex: the SHIPPED sign-in signature, read from the adapter so
# every fixture below exercises the real default rather than a copy of it that
# can drift. Resolved once - it costs a bash subshell per call.
KEEPALIVE_AUTH_RE=
keepalive_auth_regex() {
  local w fb
  if [ -z "$KEEPALIVE_AUTH_RE" ]; then
    w=$(new_sbx_world keeper-authre); fb=$(make_fake_sbx "$w")
    # shellcheck disable=SC2016  # single quotes deliberate: the variable expands in the inner bash run_adapter starts, not here
    KEEPALIVE_AUTH_RE=$(run_adapter "$fb" "$w" 'printf "%s" "$FM_SBX_AUTH_REGEX"')
  fi
  printf '%s' "$KEEPALIVE_AUTH_RE"
}

# run_keepalive_raw <fakebin> <pane-file> <args...>: execute the guest loop
# synchronously with the fake tmux first in PATH; echoes its whole stdout - the
# arm-detail line followed by the verdict line. The sign-in signature is appended
# as the loop's last positional, exactly as the wrapper passes it, so no fixture
# has to restate it.
run_keepalive_raw() {
  local fakebin=$1 pane=$2 script
  shift 2
  script=$(run_adapter "$fakebin" "$TMP_ROOT" 'fm_backend_sbx_keepalive_script')
  PATH="$fakebin:$BASE_PATH" FAKE_TMUX_PANE="$pane" HOME="$(keepalive_home)" \
    sh -c "$script" _ "$@" "$(keepalive_auth_regex)"
}

# run_keepalive_script <fakebin> <pane-file> <args...>: as above, echoing the
# VERDICT line alone, so the pin/release assertions below read exactly as they
# did before the loop grew its detail line.
run_keepalive_script() {
  run_keepalive_raw "$@" | grep -v '^fm-keepalive detail '
}

# keepalive_detail_of <raw output>: the arm-detail line from a raw run.
keepalive_detail_of() {
  printf '%s\n' "$1" | grep '^fm-keepalive detail ' | tail -1
}

test_keepalive_script_capped_verdicts() {
  local w fb te out
  w=$(new_sbx_world keeper-cap); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"

  # Turn never ends, guest idle: the cap bounds the pin and reads as idle.
  out=$(run_keepalive_script "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  [ "$out" = "fm-keepalive capped-idle" ] || fail "an idle guest at the cap should read capped-idle, got '$out'"
  [ ! -e "$w/signals/x/x.guest-active" ] || fail "an idle guest must not touch the guest-active breadcrumb"

  # A busy pane is WORK: the cap verdict flags it and the breadcrumb advances.
  printf 'esc to interrupt\n' > "$w/pane.txt"
  out=$(run_keepalive_script "$fb" "$w/pane.txt" "$te" 1 0 120 "" 'esc (to )?interrupt')
  [ "$out" = "fm-keepalive capped-active" ] || fail "a busy pane at the cap should read capped-active, got '$out'"
  [ -e "$w/signals/x/x.guest-active" ] || fail "visible work must touch the guest-active breadcrumb"

  # A child worker's fresh signal file is WORK even with every pane idle.
  rm -f "$w/signals/x/x.guest-active"
  : > "$w/home/state/w1.status"
  out=$(run_keepalive_script "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  [ "$out" = "fm-keepalive capped-active" ] || fail "a fresh child signal file should read capped-active, got '$out'"
  [ -e "$w/signals/x/x.guest-active" ] || fail "child-signal work must touch the guest-active breadcrumb"

  # A stale child signal file is NOT work: the between-turns bridge is bounded.
  touch -t 202001010000 "$w/home/state/w1.status"
  out=$(run_keepalive_script "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  [ "$out" = "fm-keepalive capped-idle" ] || fail "a stale child signal file should read capped-idle, got '$out'"

  pass "keep-alive loop: cap verdicts distinguish active work from a genuinely idle guest"
}

test_keepalive_script_pins_busy_worker_across_turn_end() {
  # THE issue #12 regression: the v1 keeper released on the secondmate's own
  # turn-end, so an in-guest crewmate mid-implementation lost its only pin and
  # the VM died about 35.4 s later. A busy worker pane must hold the pin across
  # the secondmate's turn boundary, and the pin must still release - bounded -
  # once the guest goes genuinely idle.
  local w fb script te pid i
  w=$(new_sbx_world keeper-pin); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  touch -t 202001010000 "$te"
  printf 'esc to interrupt\n' > "$w/pane.txt"
  PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE="$w/pane.txt" HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 60 1 120 "" 'esc (to )?interrupt' "$(keepalive_auth_regex)" > "$w/verdict.txt" &
  pid=$!
  sleep 0.3
  touch "$te"
  # The secondmate's turn just ended; the busy worker pane must keep the pin.
  sleep 2.5
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "the keeper released on the secondmate's turn-end while a worker pane was busy: $(cat "$w/verdict.txt")"
  fi
  # Worker goes idle: the pin must release promptly (auto-stop re-engages).
  : > "$w/pane.txt"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the keeper did not release after the guest went idle"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$w/verdict.txt")" "fm-keepalive released-idle" \
    "an idle guest after the turn-end should release the pin"
  [ -e "$w/signals/x/x.guest-active" ] || fail "the busy stretch should have touched the guest-active breadcrumb"
  pass "keep-alive loop: a busy worker pane pins across the secondmate's turn-end, then releases on idle"
}

test_keepalive_script_releases_idle_guest_on_turn_end() {
  local w fb script te pid i
  w=$(new_sbx_world keeper-release); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  touch -t 202001010000 "$te"
  PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE=/dev/null HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 60 1 120 "" 'esc (to )?interrupt' "$(keepalive_auth_regex)" > "$w/verdict.txt" &
  pid=$!
  sleep 0.3
  touch "$te"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the keeper did not release an idle guest on the turn-end (v1 contract regressed)"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$w/verdict.txt")" "fm-keepalive released-idle" \
    "a genuinely idle guest should release as released-idle"
  [ ! -e "$w/signals/x/x.guest-active" ] || fail "an idle guest must not touch the guest-active breadcrumb"
  pass "keep-alive loop: a genuinely idle guest still releases on the turn-end (auto-stop preserved)"
}

# THE 2026-07-31 recurrence of fork issue #12, after its fix had already
# shipped: the keeper was alive and pinning,
# then released as idle at the secondmate's own turn-end while an in-guest
# crewmate was genuinely running - it had committed and was driving a
# no-mistakes run, so it appended no signal for far longer than the activity
# window and its pane tail did not carry the busy idiom at the polled instant.
# A redrawing crewmate pane is the third activity arm and must hold the pin.
test_keepalive_script_pins_redrawing_crewmate_with_quiet_tail() {
  local w fb script te pid wid i
  w=$(new_sbx_world keeper-redraw); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  touch -t 202001010000 "$te"
  # A crewmate task is registered in the guest home and its only signal file is
  # far older than the activity window: the worker is inside one long
  # operation, exactly the state the VM died on top of.
  : > "$w/home/state/w1.meta"
  : > "$w/home/state/w1.status"
  touch -t 202001010000 "$w/home/state/w1.status"
  : > "$w/pane.txt"
  printf 'running tests\n' > "$w/worker.txt"
  # The crewmate's pane redraws while its tail never carries the busy idiom.
  ( i=0
    while [ "$i" -lt 300 ]; do
      printf 'running tests %s\n' "$i" > "$w/worker.txt"
      i=$((i + 1))
      sleep 0.2
    done ) &
  wid=$!
  PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE="$w/pane.txt" FAKE_TMUX_PANE2="$w/worker.txt" HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 60 1 120 "$w/home" 'esc (to )?interrupt' "$(keepalive_auth_regex)" > "$w/verdict.txt" &
  pid=$!
  sleep 0.5
  touch "$te"
  # The secondmate's turn just ended; the working crewmate must keep the pin.
  sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    kill "$wid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the keeper released on the turn-end while a crewmate was still working: $(cat "$w/verdict.txt")"
  fi
  # The crewmate's pane goes static: the pin must release, auto-stop re-engages.
  kill "$wid" 2>/dev/null || true
  wait "$wid" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the keeper did not release after the crewmate's pane went static"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$w/verdict.txt")" "fm-keepalive released-idle" \
    "a quiescent guest after the turn-end should release the pin"
  [ -e "$w/signals/x/x.guest-active" ] || fail "the redrawing stretch should have touched the guest-active breadcrumb"
  pass "keep-alive loop: a redrawing crewmate pins across the turn-end despite a quiet tail and stale signals"
}

test_keepalive_script_releases_static_crewmate_pane() {
  # The other direction of the same arm: a crewmate that is registered but done
  # - reported and awaiting cleanup - has a static pane and is NOT work, so an
  # unlanded task registration alone can never defeat auto-stop.
  local w fb te out
  w=$(new_sbx_world keeper-static); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  : > "$w/home/state/w1.meta"
  printf 'ready for review\n' > "$w/worker.txt"
  export FAKE_TMUX_PANE2="$w/worker.txt"
  out=$(run_keepalive_script "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  unset FAKE_TMUX_PANE2
  [ "$out" = "fm-keepalive capped-idle" ] || fail "a registered but static crewmate pane must not pin, got '$out'"
  [ ! -e "$w/signals/x/x.guest-active" ] || fail "a static crewmate pane must not touch the guest-active breadcrumb"
  pass "keep-alive loop: a registered crewmate with a static pane stays idle (auto-stop preserved)"
}

test_keepalive_script_change_arm_needs_a_registered_crewmate() {
  # The arm is gated on a registered crewmate task so the ordinary idle
  # secondmate - the common case, and the one stopped-is-healthy rests on -
  # keeps exactly its pre-fix auto-stop behaviour whatever its panes redraw.
  local w fb te out wid i
  w=$(new_sbx_world keeper-gate); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  printf 'boot\n' > "$w/worker.txt"
  ( i=0
    while [ "$i" -lt 60 ]; do
      printf 'line %s\n' "$i" > "$w/worker.txt"
      i=$((i + 1))
      sleep 0.1
    done ) &
  wid=$!
  export FAKE_TMUX_PANE2="$w/worker.txt"
  out=$(run_keepalive_script "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  unset FAKE_TMUX_PANE2
  kill "$wid" 2>/dev/null || true
  wait "$wid" 2>/dev/null || true
  [ "$out" = "fm-keepalive capped-idle" ] || fail "a changing pane with no registered crewmate must not pin, got '$out'"
  pass "keep-alive loop: the pane-change arm stays off for an ordinary idle secondmate"
}

# --- keep-alive loop: the gate-activity arm (2026-08-07 kills) ----------------
#
# make_gate_logs <home> <age-flag> [nested]: build a guest gate log root at
# <home>/.no-mistakes/logs the way no-mistakes lays one out - a top-level
# daemon.log plus a per-run directory of step logs. <age-flag> is "fresh" or
# "stale"; "nested" puts the only fresh file inside the run directory, which is
# where a run's step output actually lands.
# The run DIRECTORY is aged too, not just the files in it: its own mtime
# advances whenever a step log is created there, so it is a work signal in its
# own right and a freshly built fixture directory would otherwise read as work
# no matter how the files inside it were aged.
make_gate_logs() {  # <home> <fresh|stale> [nested]
  local home=$1 age=$2 nested=${3:-} root run
  root="$home/.no-mistakes/logs"
  run="$root/01KZDAJJ76CJ5TJEQX5118WX8R"
  mkdir -p "$run"
  : > "$root/daemon.log"
  : > "$run/test.log"
  touch -t 202001010000 "$root/daemon.log" "$run/test.log"
  if [ "$age" != stale ]; then
    if [ -n "$nested" ]; then touch "$run/test.log"; else touch "$root/daemon.log"; fi
  fi
  touch -t 202001010000 "$run" "$root"
}

test_keepalive_script_pins_an_offscreen_gate_run() {
  # THE 2026-08-07 regression, proven 6 runs of 6 with matched host and guest
  # timestamps: a validation run is a gate-daemon child writing to
  # $HOME/.no-mistakes/logs/<run>/, so it reaches no terminal and touches no
  # status file. All three screen-and-status arms read 0 while the guest daemon
  # was making four IPC calls per second, the keeper released, and sandboxd
  # powered the VM off 35.4 s later - four validation runs died that way. The
  # gate-activity arm reads the work itself and must hold the pin.
  local w fb te out
  w=$(new_sbx_world keeper-gatearm); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state" "$w/guest"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  # The exact state the VM died on top of: a registered worker whose last
  # status append is an hour stale, and a pane parked on a settled screen.
  : > "$w/home/state/w1.meta"
  : > "$w/home/state/w1.status"
  touch -t 202001010000 "$w/home/state/w1.status"
  make_gate_logs "$w/guest" fresh

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-active" \
    "an off-screen gate run must pin the VM, not read as idle"
  assert_contains "$(keepalive_detail_of "$out")" "arm1=0 arm2=0 arm3=0 arm4=1" \
    "the off-screen gate run should be reported as arm 4"
  [ -e "$w/signals/x/x.guest-active" ] \
    || fail "gate-run work must touch the guest-active breadcrumb like any other arm"
  pass "keep-alive loop: an off-screen validation run pins the VM (2026-08-07 kills)"
}

test_keepalive_script_gate_arm_reads_a_runs_step_log() {
  # A run's own step logs live one level deeper than the daemon log, and a long
  # step can leave the daemon log untouched for many minutes (measured 57 min,
  # 2026-08-07) - so the arm must see the nested file, not just the top level.
  local w fb te out
  w=$(new_sbx_world keeper-gatearm-nested); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/guest"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  make_gate_logs "$w/guest" fresh nested

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-active" \
    "a fresh step log inside a run directory must pin the VM"
  assert_contains "$(keepalive_detail_of "$out")" "arm4=1" \
    "a nested step log should be reported as arm 4"
  pass "keep-alive loop: the gate arm sees a run's step log, not only the daemon log"
}

test_keepalive_script_gate_arm_releases_a_quiet_gate() {
  # The other direction, and the property stopped-is-healthy rests on: a live
  # but IDLE gate daemon writes nothing at all (measured: a running daemon left
  # its logs untouched for 5.5 h on 2026-08-07), so a guest with a gate root
  # and no run in flight still reads idle and still auto-stops.
  local w fb te out
  w=$(new_sbx_world keeper-gatearm-quiet); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/guest"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  make_gate_logs "$w/guest" stale

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-idle" \
    "an idle gate daemon must not pin the VM"
  assert_contains "$(keepalive_detail_of "$out")" "arm4=0" \
    "an idle gate daemon should be reported as arm 4 reading nothing"
  [ ! -e "$w/signals/x/x.guest-active" ] \
    || fail "an idle gate daemon must not touch the guest-active breadcrumb"

  # A guest with no gate installed at all is the same reading, with no stamp.
  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-idle" \
    "a guest with no gate root must not pin the VM"
  assert_not_contains "$(keepalive_detail_of "$out")" "nmlog=" \
    "a guest with no gate root should stamp no gate-log mtime"
  pass "keep-alive loop: an idle or absent gate still releases (auto-stop preserved)"
}

# --- keep-alive fifth arm: a worker parked on an unanswered decision ---------
#
# make_guest_firstmate_bin <home>: give a fixture guest home the bin/ every real
# secondmate home has (bin/fm-home-seed.sh refuses one without it), which is
# where the loop finds the parked-decision predicate it runs in-guest.
make_guest_firstmate_bin() {  # <home>
  ln -s "$ROOT/bin" "$1/bin"
}

# park_worker <home> <id>: a REGISTERED in-guest worker that appended a decision
# nobody has answered yet, and whose signals are long stale - the exact shape
# every other arm reads as idle.
park_worker() {  # <home> <id>
  printf 'kind=ship\n' > "$1/state/$2.meta"
  {
    printf 'working: implementing the rename\n'
    printf 'needs-decision: ship the rename now or behind a flag\n'
  } > "$1/state/$2.status"
  touch -t 202001010000 "$1/state/$2.meta" "$1/state/$2.status"
}

test_keepalive_script_pins_a_worker_parked_on_a_decision() {
  # THE 2026-08-10 regression, from the keeper's own verdict log: three
  # released-idle verdicts with arm1..arm4 all 0 and crew=1, each while the
  # in-guest worker sat parked on a decision firstmate had escalated to the
  # captain. Every existing arm reads a screen or an mtime, and a parked worker
  # moves neither - so the pin has to come from the durable record of the wait
  # itself.
  local w fb te out
  w=$(new_sbx_world keeper-parked); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state" "$w/guest"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  park_worker "$w/home" w1
  make_gate_logs "$w/guest" stale

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  # capped-active is BOTH assertions at once: the pin held (the decision was
  # never answered, so nothing ever released it) and the cap still ended it.
  # An unanswered decision therefore cannot pin a machine indefinitely.
  assert_contains "$out" "fm-keepalive capped-active" \
    "a worker parked on an unanswered decision must pin the VM, not read as idle"
  assert_contains "$(keepalive_detail_of "$out")" "arm1=0 arm2=0 arm3=0 arm4=0 arm5=1" \
    "the parked decision should be reported as arm 5"
  pass "keep-alive loop: a parked worker pins the VM, and the cap still bounds it (2026-08-10 stops)"
}

test_keepalive_script_parked_worker_survives_the_secondmate_turn_end() {
  # The logged shape, exactly: the three stops were released-idle verdicts, not
  # cap expiries. The secondmate relays the escalation, its own turn ends, and
  # the v4 loop released on that turn-end - so the pin has to survive the
  # turn-end advancing, which is the one condition every release requires.
  local w fb script te pid i
  w=$(new_sbx_world keeper-parked-turnend); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x" "$w/home/state"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  touch -t 202001010000 "$te"
  park_worker "$w/home" w1
  PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE=/dev/null HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 3 1 120 "$w/home" 'esc (to )?interrupt' "$(keepalive_auth_regex)" > "$w/verdict.txt" &
  pid=$!
  sleep 0.3
  touch "$te"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_not_contains "$(cat "$w/verdict.txt")" "fm-keepalive released-idle" \
    "the keeper released on the turn-end while a worker sat on an unanswered decision"
  pass "keep-alive loop: a parked worker's pin survives the secondmate's own turn-end"
}

test_keepalive_script_parked_pin_releases_when_the_answer_lands() {
  # Clearing is the worker's own resolution line, not a separate marker anyone
  # has to remember to delete: the moment the answer is delivered and recorded,
  # the next poll reads no open decision and the guest is free to stop again.
  local w fb te out
  w=$(new_sbx_world keeper-parked-answered); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state" "$w/guest"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  park_worker "$w/home" w1
  printf 'resolved: behind a flag\n' >> "$w/home/state/w1.status"
  touch -t 202001010000 "$w/home/state/w1.status"

  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-idle" \
    "an answered decision must release the pin"
  assert_contains "$(keepalive_detail_of "$out")" "arm5=0" \
    "an answered decision should read as arm 5 reading nothing"
  pass "keep-alive loop: delivering the answer releases the parked pin"
}

test_keepalive_script_releases_a_finished_worker_with_an_open_decision() {
  # The invariant the keep-alive contract will not give up: a finished worker
  # awaiting cleanup still lets the VM stop. A decision line it never explicitly
  # resolved must not convert that into a permanent pin.
  local w fb te out
  w=$(new_sbx_world keeper-parked-finished); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  park_worker "$w/home" w1
  printf 'done: PR https://example.invalid/pr/1 checks green\n' >> "$w/home/state/w1.status"
  touch -t 202001010000 "$w/home/state/w1.status"

  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-idle" \
    "a finished worker awaiting cleanup must still let the VM stop"
  pass "keep-alive loop: a finished worker's stale decision line never pins"
}

test_keepalive_script_parked_arm_needs_a_registered_crewmate() {
  # Gated exactly like the pane-change arm: with no crewmate registered there is
  # no in-guest session a stop would destroy, so the ordinary idle secondmate's
  # auto-stop behaviour is untouched.
  local w fb te out
  w=$(new_sbx_world keeper-parked-nocrew); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  park_worker "$w/home" w1
  rm -f "$w/home/state/w1.meta"

  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-idle" \
    "an open decision with no registered crewmate must not pin"
  pass "keep-alive loop: the parked-decision arm needs a registered crewmate"
}

test_keepalive_script_parked_pin_leaves_the_breadcrumb_alone() {
  # A parked worker is a WAIT, not work, and the guest-active breadcrumb means
  # work. The watcher's stranding arm treats a fresh breadcrumb as
  # acknowledgement of a delivery, so letting a park refresh it would silence
  # the alarm for a guest that never processed the answer it was sent.
  local w fb te
  w=$(new_sbx_world keeper-parked-breadcrumb); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  park_worker "$w/home" w1

  run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt' >/dev/null
  [ ! -e "$w/signals/x/x.guest-active" ] \
    || fail "a parked worker must not touch the guest-active breadcrumb"

  # A busy pane on the same fixture still does, so this is the park being
  # excluded rather than the breadcrumb being broken.
  printf 'esc to interrupt\n' > "$w/pane.txt"
  run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt' >/dev/null
  [ -e "$w/signals/x/x.guest-active" ] \
    || fail "visible work must still touch the guest-active breadcrumb"
  pass "keep-alive loop: a parked pin never fakes in-guest activity"
}

test_keepalive_script_parked_arm_fails_closed_without_the_predicate() {
  # A guest home cloned before this shipped has no predicate to run. The arm
  # must then read nothing and leave the previous behaviour exactly as it was,
  # rather than pinning on the strength of a missing file.
  local w fb te out
  w=$(new_sbx_world keeper-parked-nopredicate); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  park_worker "$w/home" w1

  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$out" "fm-keepalive capped-idle" \
    "a guest home with no parked-decision predicate must behave exactly as before"
  assert_contains "$(keepalive_detail_of "$out")" "arm5=0" \
    "an unavailable predicate should read as arm 5 reading nothing"
  pass "keep-alive loop: the parked-decision arm fails closed on an older guest home"
}

test_keepalive_script_detail_reports_panes_and_gate_freshness() {
  # The 2026-08-07 scout could prove all three arms read 0 but NOT why, and
  # declined to guess among four candidates - two of them (no tmux panes at
  # all; a gate run writing off-screen) are settled outright by these two
  # fields, which the loop already reads on the deciding poll.
  local w fb te out mtime
  w=$(new_sbx_world keeper-detail-panes); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/guest"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  make_gate_logs "$w/guest" stale
  mtime=$(stat -c %Y "$w/guest/.no-mistakes/logs/daemon.log" 2>/dev/null \
    || stat -f %m "$w/guest/.no-mistakes/logs/daemon.log")

  # Two panes visible, a gate root present but quiet: the line settles both.
  export FAKE_TMUX_PANE2="$w/worker.txt"
  printf 'ready for review\n' > "$w/worker.txt"
  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  unset FAKE_TMUX_PANE2
  assert_contains "$(keepalive_detail_of "$out")" "panes=2 park=none nmlog=$mtime" \
    "the detail line should carry the pane count and the newest gate-log mtime"

  # No tmux server at all - the candidate the scout could not rule out - reads
  # as a pane count of zero rather than as an indistinguishable all-arms-idle.
  rm -f "$fb/tmux"
  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "panes=0" \
    "a guest with no tmux panes should report a pane count of zero"
  pass "keep-alive detail: pane count and gate-log freshness make the next release decidable"
}

# assert_log_matches <file> <ere> <msg> / assert_log_lacks: the verdict log's
# fields are structured (timestamp, verdict, pin=Ns, arm flags), so asserting
# on their SHAPE needs a real regex rather than lib.sh's fixed-string grep.
assert_log_matches() {
  grep -qE -- "$2" "$1" || fail "$3"$'\n'"--- log ---"$'\n'"$(cat "$1" 2>/dev/null)"
}

assert_log_lacks() {
  ! grep -qE -- "$2" "$1" || fail "$3"$'\n'"--- log ---"$'\n'"$(cat "$1" 2>/dev/null)"
}

# --- keep-alive instrumentation: the arm detail line -------------------------
#
# Why these exist: a released pin used to leave no durable trace, so "the keeper
# released" and "no keeper ever started" were indistinguishable after the fact
# (2026-08-03 scout, §3.2/§3.4). The loop now reports how each arm read on the
# deciding poll. These fixtures pin the REPORT only - the pin/release fixtures
# above are unchanged and remain the behavioural net.

test_keepalive_script_detail_names_the_deciding_arm() {
  local w fb te out
  w=$(new_sbx_world keeper-detail); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"

  # Idle, nothing registered: every arm reads 0 and the crewmate gate is shut.
  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "" 'esc (to )?interrupt')
  [ "$(keepalive_detail_of "$out")" = "fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=0 panes=1 park=none" ] \
    || fail "an idle guest should report all five arms 0 with the gate shut, got '$(keepalive_detail_of "$out")'"

  # Arm 1: a busy pane tail.
  printf 'esc to interrupt\n' > "$w/pane.txt"
  out=$(run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "arm1=1 arm2=0 arm3=0 arm4=0" \
    "a busy pane tail should be reported as arm 1"

  # Arm 2: a child worker's fresh signal file, every pane idle.
  : > "$w/home/state/w1.status"
  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "arm1=0 arm2=1 arm3=0 arm4=0" \
    "a fresh child signal should be reported as arm 2"

  pass "keep-alive detail: the line names which activity arm read the guest as working"
}

test_keepalive_script_detail_reports_the_pane_change_arm() {
  # Arm 3 needs two polls to compare against, so this run must actually loop.
  local w fb script te wid out i
  w=$(new_sbx_world keeper-detail-arm3); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  : > "$w/home/state/w1.meta"
  : > "$w/home/state/w1.status"
  touch -t 202001010000 "$w/home/state/w1.status"
  printf 'boot\n' > "$w/worker.txt"
  ( i=0
    while [ "$i" -lt 200 ]; do
      printf 'running tests %s\n' "$i" > "$w/worker.txt"
      i=$((i + 1))
      sleep 0.2
    done ) &
  wid=$!
  out=$(PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE=/dev/null FAKE_TMUX_PANE2="$w/worker.txt" HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 3 1 120 "$w/home" 'esc (to )?interrupt' "$(keepalive_auth_regex)")
  kill "$wid" 2>/dev/null || true
  wait "$wid" 2>/dev/null || true
  assert_contains "$out" "fm-keepalive capped-active" \
    "a redrawing crewmate pane should still pin to the cap"
  assert_contains "$(keepalive_detail_of "$out")" "arm1=0 arm2=0 arm3=1 arm4=0 arm5=0 crew=1" \
    "a redrawing crewmate pane should be reported as arm 3 with the gate open"
  pass "keep-alive detail: a redrawing crewmate pane is reported as the pane-change arm"
}

test_keepalive_script_detail_stamps_release_against_task_state() {
  # THE discrimination the 2026-08-03 investigation had to infer from
  # connection arithmetic: a release with a registered in-guest task is the
  # silent-worker defect's fingerprint, a release with none is healthy. Both
  # release identically - only the report distinguishes them.
  local w fb script te pid i out mtime
  w=$(new_sbx_world keeper-detail-release); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  touch -t 202001010000 "$te"
  # A crewmate task registered, its last status append far outside the activity
  # window: the worker is inside one long silent operation.
  : > "$w/home/state/w1.meta"
  : > "$w/home/state/w1.status"
  touch -t 202401011200 "$w/home/state/w1.status"
  mtime=$(stat -c %Y "$w/home/state/w1.status" 2>/dev/null || stat -f %m "$w/home/state/w1.status")

  ( sleep 0.4; touch "$te" ) &
  pid=$!
  out=$(PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE=/dev/null HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 30 1 120 "$w/home" 'esc (to )?interrupt' "$(keepalive_auth_regex)")
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "fm-keepalive released-idle" \
    "a quiescent guest should release on the turn-end"
  [ "$(keepalive_detail_of "$out")" = "fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=1 panes=1 park=unknown status=$mtime" ] \
    || fail "a release with a registered task must carry the gate and the newest in-guest status mtime, got '$(keepalive_detail_of "$out")'"

  # The healthy shape: no task registered, so no stamp and an unmistakably
  # different line - "gate correctly off" is not "gate open, pane static".
  rm -f "$w/home/state/w1.meta"
  touch -t 202001010000 "$te"
  ( sleep 0.4; touch "$te" ) &
  pid=$!
  out=$(PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE=/dev/null HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 30 1 120 "$w/home" 'esc (to )?interrupt' "$(keepalive_auth_regex)")
  wait "$pid" 2>/dev/null || true
  [ "$(keepalive_detail_of "$out")" = "fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=0 panes=1 park=none" ] \
    || fail "a release with no registered task must report the gate shut and carry no stamp, got '$(keepalive_detail_of "$out")'"
  i=$(printf '%s\n' "$out" | grep -c 'status=' || true)
  [ "$i" -eq 0 ] || fail "a release with no registered task must not stamp an in-guest status mtime"
  pass "keep-alive detail: a release separates a registered-but-static task from no task at all"
}

# --- keep-alive instrumentation: why the screen was static -------------------
#
# All five arms read zero for two guests whose remedies are OPPOSITE: a worker
# stopped on a harness sign-in prompt, which posts no status at all so no open
# decision exists for the fifth arm to find, and a worker that finished and is
# waiting for cleanup, which is correctly allowed to let the machine stop. One
# needs a human to restore the login; the other needs nothing. `park=`
# classifies which, from readings the loop already makes.
#
# It records a CLASSIFICATION and never the pane text: the verdict log lives on
# the signal-bridge mount, which survives both the stop and a full guest rebuild,
# and a worker pane can hold credential material.

# static_worker <home> <id>: a REGISTERED worker whose signals are long stale and
# whose newest event is nonterminal - every arm reads idle and nothing in the
# record explains it.
static_worker() {  # <home> <id>
  printf 'kind=ship\n' > "$1/state/$2.meta"
  printf 'working: implementing the rename\n' > "$1/state/$2.status"
  touch -t 202001010000 "$1/state/$2.meta" "$1/state/$2.status"
}

# finished_worker <home> <id>: the same static shape, but the record says the
# work ended - the guest that is right to stop.
finished_worker() {  # <home> <id>
  printf 'kind=ship\n' > "$1/state/$2.meta"
  {
    printf 'working: implementing the rename\n'
    printf 'done: PR https://example.invalid/pr/1 checks green\n'
  } > "$1/state/$2.status"
  touch -t 202001010000 "$1/state/$2.meta" "$1/state/$2.status"
}

# park_world <name> <pane-text>: a guest whose only pane shows <pane-text>, with
# a registered worker and a stale gate root, so every arm reads 0. Echoes
# "<world> <fakebin> <turnend>".
park_world() {  # <name> <pane-text>
  local w fb te
  w=$(new_sbx_world "$1"); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state" "$w/guest"
  make_guest_firstmate_bin "$w/home"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  printf '%s\n' "$2" > "$w/pane.txt"
  make_gate_logs "$w/guest" stale
  printf '%s %s %s\n' "$w" "$fb" "$te"
}

test_keepalive_detail_classifies_a_signin_park() {
  # The recorded shape, verbatim from data/learnings.md 2026-08-02: two live
  # crewmates showing `Please run /login - API Error: 401 OAuth access token has
  # expired`. That worker posts nothing, so no arm and no durable record can see
  # it - only its screen can.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-auth \
    'Please run /login - API Error: 401 OAuth access token has expired')"
  static_worker "$w/home" w1

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "park=auth" \
    "a pane holding the sign-in signature must be recorded as a sign-in park"
  # The classification is evidence, never a pin: the machine still stops.
  assert_contains "$out" "fm-keepalive capped-idle" \
    "classifying a sign-in park must not change whether the machine may stop"
  assert_contains "$(keepalive_detail_of "$out")" "arm1=0 arm2=0 arm3=0 arm4=0 arm5=0" \
    "the classification must feed no arm"
  pass "keep-alive detail: a worker stopped on a sign-in prompt is recorded as such"
}

test_keepalive_detail_never_records_the_pane_text() {
  # THE security property. The verdict log lives on the signal-bridge mount,
  # which outlives the stop and a full guest rebuild, so a pane excerpt written
  # there is a durable secret-exposure surface on the host. Only the enum leaves
  # the guest, even when the matching line carries a credential beside it.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-secret \
    'Please run /login - API Error: 401 (token sk-ant-oat01-NOTAREALSECRET)')"
  static_worker "$w/home" w1

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "park=auth" \
    "the pane should still classify as a sign-in park"
  assert_not_contains "$out" "sk-ant-oat01" \
    "the guest must emit a classification, never any part of the pane text"
  assert_not_contains "$out" "API Error" \
    "the guest must emit a classification, never any part of the pane text"
  pass "keep-alive detail: the classification carries no pane text"
}

test_keepalive_detail_classifies_a_finished_worker() {
  # The opposite remedy: nothing is wrong, cleanup is owed. Same static pane,
  # same zero arms - only the durable record separates it from the case above.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-finished 'ready for review')"
  finished_worker "$w/home" w1

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "park=finished" \
    "a worker whose record says it finished must be recorded as finished"
  assert_contains "$out" "fm-keepalive capped-idle" \
    "a finished worker must still let the machine stop"
  pass "keep-alive detail: a finished worker awaiting cleanup is recorded as finished"
}

test_keepalive_detail_admits_an_unrecognised_static_pane() {
  # A confident wrong label is worse than an honest gap: an unrecognised static
  # pane must not be forced into either bucket.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-unknown 'some screen nobody has classified')"
  static_worker "$w/home" w1

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "park=unknown" \
    "an unrecognised static pane must be recorded as unknown, not guessed at"
  pass "keep-alive detail: an unrecognised static pane stays honestly unknown"
}

test_keepalive_detail_reports_no_park_when_work_is_visible() {
  # There is no static screen to explain while the guest is working, and gating
  # on that is what stops a worker whose own output happens to quote a sign-in
  # message from being labelled as stopped on one.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-busy \
    'grep -n "Please run /login" docs/sbx-backend.md
esc to interrupt')"
  static_worker "$w/home" w1

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "arm1=1" \
    "the busy tail should still read as work"
  assert_contains "$(keepalive_detail_of "$out")" "park=none" \
    "a working guest has no static screen to classify"
  pass "keep-alive detail: a working guest reports no park, whatever its output quotes"
}

test_keepalive_detail_reports_no_park_without_a_registered_task() {
  # An ordinary idle secondmate is the healthy resting case: no in-guest worker
  # is registered, so there is no static-worker question to answer.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-nocrew 'idle')"

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "crew=0 panes=1 park=none" \
    "a guest with no registered task has nothing to classify"
  pass "keep-alive detail: an idle secondmate with no task reports no park"
}

test_keepalive_detail_classifies_a_signin_park_without_a_task() {
  # The secondmate's OWN pane can be the one stopped on a sign-in prompt
  # (data/learnings.md 2026-07-31: a stop whose cause was claude requiring a
  # login, wholly outside the keep-alive story). That is worth recording even
  # with no in-guest worker registered, so the sign-in reading is not gated on
  # the crewmate flag.
  local w fb te out
  read -r w fb te <<<"$(park_world keeper-park-auth-nocrew 'Not logged in')"

  out=$(KEEPALIVE_HOME="$w/guest" \
    run_keepalive_raw "$fb" "$w/pane.txt" "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "crew=0 panes=1 park=auth" \
    "a sign-in prompt on the guest's own pane must be recorded without a registered task"
  pass "keep-alive detail: the guest's own sign-in park is recorded too"
}

test_keepalive_detail_park_fails_closed_without_the_predicate() {
  # A guest home cloned before this shipped has no predicate to run. "Finished"
  # then cannot be asserted, and the honest answer is unknown - never finished on
  # the strength of a missing file, which would read as "the stop was correct".
  local w fb te out
  w=$(new_sbx_world keeper-park-nopredicate); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  finished_worker "$w/home" w1

  out=$(run_keepalive_raw "$fb" /dev/null "$te" 1 0 120 "$w/home" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "park=unknown" \
    "a guest home with no predicate must report unknown rather than claim finished"
  pass "keep-alive detail: the finished reading fails closed on an older guest home"
}

test_keepalive_detail_park_needs_a_signature_to_claim_auth() {
  # The wrapper always supplies the signature, and an empty pattern would match
  # every line. A loop invoked without one must classify nothing as a sign-in
  # park rather than everything.
  local w fb script te out
  w=$(new_sbx_world keeper-park-nopattern); fb=$(make_fake_sbx "$w")
  make_fake_guest_tmux "$fb"
  script=$(run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive_script')
  mkdir -p "$w/signals/x" "$w/home/state"
  te="$w/signals/x/x.turn-ended"
  : > "$te"
  printf 'Please run /login\n' > "$w/pane.txt"

  out=$(PATH="$fb:$BASE_PATH" FAKE_TMUX_PANE="$w/pane.txt" HOME="$(keepalive_home)" \
    sh -c "$script" _ "$te" 1 0 120 "" 'esc (to )?interrupt')
  assert_contains "$(keepalive_detail_of "$out")" "park=none" \
    "a loop with no sign-in signature must claim nothing"
  pass "keep-alive detail: an absent sign-in signature claims nothing rather than everything"
}

# --- keep-alive wrapper: verdict log -----------------------------------------

test_keepalive_wrapper_logs_every_verdict() {
  # The scout's §3.2 gap: a clean release wrote NOTHING, so an armed-and-
  # released keeper could not be told from one that never started. Every exit
  # now leaves a line, silent classifications included.
  local w fb case_ log
  w=$(new_sbx_world keeper-log); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  log="$w/state/.sbx-keepalive-x.log"
  for case_ in released-idle capped-idle capped-active; do
    run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
      FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
      FM_FAKE_SBX_KEEPALIVE_OUT="fm-keepalive $case_" \
      || fail "the keep-alive call itself should succeed for $case_"
  done
  # The exec dying with no verdict at all is its own recorded outcome, not an
  # absence: that ambiguity is exactly what this log exists to close.
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_RC=1 \
    || fail "the keep-alive call itself should succeed for a dead exec"

  [ -f "$log" ] || fail "every keeper exit must leave a durable verdict line at $log"
  [ "$(wc -l < "$log")" -eq 4 ] || fail "four keeper exits should leave four lines, got $(wc -l < "$log")"
  for case_ in released-idle capped-idle capped-active no-verdict; do
    assert_grep "$case_" "$log" "the log should record the $case_ outcome"
  done
  assert_log_matches "$log" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z (released-idle|capped-idle|capped-active|no-verdict) pin=[0-9]+s$' \
    "each line should be a UTC timestamp, a verdict and the elapsed pin duration"
  pass "keep-alive log: every keeper exit records its verdict, timestamp and pin duration"
}

test_keepalive_wrapper_log_carries_validated_guest_detail() {
  # Guest stdout is untrusted: the arm report is admitted only in its exact
  # shape, so nothing but 0/1 flags and a digit timestamp can reach the log.
  local w fb log stale_detail
  w=$(new_sbx_world keeper-log-detail); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  log="$w/state/.sbx-keepalive-x.log"

  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT=$'fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=1 panes=2 park=finished status=1785512635 nmlog=1786127662\nfm-keepalive released-idle' \
    || fail "the keep-alive call itself should succeed"
  assert_log_matches "$log" \
    'released-idle pin=[0-9]+s arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=1 panes=2 park=finished status=1785512635 nmlog=1786127662$' \
    "the log line should carry the guest's arm report, pane count, static-screen verdict and both mtime stamps"
  assert_no_grep 'fm-keepalive detail' "$log" \
    "the log should carry the report's fields, not the raw guest marker line"

  # A forged or garbled report is dropped, and the verdict line still lands.
  : > "$log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT=$'fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=1 panes=2 park=auth; rm -rf /\nfm-keepalive released-idle' \
    || fail "the keep-alive call itself should succeed"
  assert_log_matches "$log" 'released-idle pin=[0-9]+s$' \
    "an unparseable report should be dropped, leaving the verdict line intact"
  assert_no_grep 'rm -rf' "$log" "a guest line outside the accepted shape must never reach the log"

  # A superseded arm shape is dropped rather than logged as if the newest arm
  # had reported: a guest running an older loop must not read as "the arm that
  # loop never had saw nothing". Both retired shapes are checked, because each
  # new arm turns the previous current shape into another one to refuse.
  for stale_detail in \
    'fm-keepalive detail arm1=0 arm2=0 arm3=0 crew=1 status=1785512635' \
    'fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 crew=1 panes=2 status=1785512635' \
    'fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=1 panes=2 status=1785512635'; do
    : > "$log"
    run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
      FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
      FM_FAKE_SBX_KEEPALIVE_OUT="$stale_detail"$'\nfm-keepalive released-idle' \
      || fail "the keep-alive call itself should succeed"
    assert_log_matches "$log" 'released-idle pin=[0-9]+s$' \
      "a report in a superseded arm shape should be dropped, leaving the verdict intact"
    assert_no_grep 'arm1=' "$log" "a superseded report shape must not reach the log"
  done

  # The static-screen verdict is a CLOSED enum. A value outside it - the shape a
  # guest smuggling pane text would produce - is refused entirely rather than
  # logged, exactly like every other field outside its accepted shape.
  : > "$log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT=$'fm-keepalive detail arm1=0 arm2=0 arm3=0 arm4=0 arm5=0 crew=1 panes=2 park=Please run /login\nfm-keepalive released-idle' \
    || fail "the keep-alive call itself should succeed"
  assert_log_matches "$log" 'released-idle pin=[0-9]+s$' \
    "a verdict outside the closed enum should be dropped, leaving the verdict line intact"
  assert_no_grep '/login' "$log" "free text in the verdict field must never reach the log"
  pass "keep-alive log: the guest's arm report is admitted only in its exact shape"
}

test_keepalive_wrapper_log_failure_cannot_affect_the_keeper() {
  # The log is evidence, not machinery: an unwritable log must not disturb the
  # wrapper's own classification, nor make the keep-alive call fail.
  local w fb
  w=$(new_sbx_world keeper-log-unwritable); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x stopped > "$w/ls.json"
  # A directory at the log path makes every append fail, without chmod games.
  mkdir -p "$w/state/.sbx-keepalive-x.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT='fm-keepalive capped-active' \
    || fail "an unwritable verdict log must not fail the keep-alive call"
  [ -f "$w/state/.sbx-midtask-stop-x" ] \
    || fail "an unwritable verdict log must not suppress the mid-task-stop marker"
  pass "keep-alive log: an append failure changes neither the call's result nor the wrapper's alarm"
}

test_keepalive_log_growth_is_bounded() {
  # A long-lived home must not accumulate an unbounded file, and the trim must
  # keep the NEWEST lines - a post-mortem reads the most recent exits.
  local w fb log lines
  w=$(new_sbx_world keeper-log-bound); fb=$(make_fake_sbx "$w")
  log="$w/state/keeper.log"
  # shellcheck disable=SC2016  # single quotes deliberate: $i expands in the inner bash run_adapter starts, not here
  run_adapter "$fb" "$w" \
    'i=1; while [ "$i" -le 60 ]; do fm_backend_sbx_keepalive_log "'"$log"'" released-idle "$i" "" || exit 1; i=$((i + 1)); done' \
    FM_SBX_KEEPALIVE_LOG_LINES=10 \
    || fail "the log writer should always succeed"
  lines=$(wc -l < "$log")
  [ "$lines" -le 20 ] || fail "60 exits at a 10-line bound should stay under the trim threshold, got $lines lines"
  [ "$lines" -ge 10 ] || fail "the trim should keep the configured number of lines, got $lines"
  assert_contains "$(tail -1 "$log")" "pin=60s" "the newest exit must survive the trim"
  assert_log_lacks "$log" 'pin=1s$' "the oldest exits should have been trimmed away"
  [ ! -e "$log.tmp" ] || fail "the trim must not leave its scratch file behind"
  pass "keep-alive log: growth is bounded and the trim keeps the newest exits"
}

# --- keep-alive wrapper: mid-task-stop classification ------------------------

test_keepalive_wrapper_marks_midtask_stop_on_capped_active() {
  local w fb
  w=$(new_sbx_world keeper-capmark); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x stopped > "$w/ls.json"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT='fm-keepalive capped-active' \
    || fail "the keep-alive call itself should succeed"
  [ -f "$w/state/.sbx-midtask-stop-x" ] \
    || fail "a cap expiry with active work and a stopped VM must record the mid-task-stop marker"
  assert_contains "$(cat "$w/state/.sbx-midtask-stop-x")" "expired while in-guest work was still active" \
    "the marker should carry the cap-expiry reason"
  pass "keep-alive wrapper: cap expiry with active work + stopped VM records the mid-task-stop marker"
}

test_keepalive_wrapper_skips_marker_when_vm_still_running() {
  # Another keeper (or a fresh steer) may still be pinning: a running VM after
  # the settle means no mid-task stop happened, so no alarm.
  local w fb
  w=$(new_sbx_world keeper-still-up); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x running > "$w/ls.json"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT='fm-keepalive capped-active' \
    || fail "the keep-alive call itself should succeed"
  [ ! -e "$w/state/.sbx-midtask-stop-x" ] \
    || fail "a VM still running after the settle must not be flagged as a mid-task stop"
  pass "keep-alive wrapper: a still-running VM after a cap expiry raises no alarm"
}

test_keepalive_wrapper_marks_dropped_connection_with_fresh_breadcrumb() {
  # The exec dying without a verdict (sbx stop, a crash) is a mid-task stop
  # exactly when the guest-active breadcrumb proves work was live.
  local w fb
  w=$(new_sbx_world keeper-dropped); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x stopped > "$w/ls.json"
  mkdir -p "$w/signals/x"
  touch "$w/signals/x/x.guest-active"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_RC=1 \
    || fail "the keep-alive call itself should succeed"
  [ -f "$w/state/.sbx-midtask-stop-x" ] \
    || fail "a dead exec with a fresh breadcrumb and a stopped VM must record the mid-task-stop marker"
  assert_contains "$(cat "$w/state/.sbx-midtask-stop-x")" "connection dropped while in-guest work was active" \
    "the marker should carry the dropped-connection reason"
  pass "keep-alive wrapper: a dead exec with a fresh breadcrumb + stopped VM records the mid-task-stop marker"
}

test_keepalive_wrapper_quiet_on_idle_death() {
  # No verdict and no fresh breadcrumb: an idle keeper dying (VM stopped while
  # nothing was working) is the healthy auto-stop, not a captain-facing event -
  # and must not even spend a state probe.
  local w fb
  w=$(new_sbx_world keeper-idle-death); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x stopped > "$w/ls.json"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_RC=1 \
    || fail "the keep-alive call itself should succeed"
  [ ! -e "$w/state/.sbx-midtask-stop-x" ] \
    || fail "an idle keeper death must not be flagged as a mid-task stop"
  assert_not_contains "$(cat "$w/sbx.log")" "ls --json" \
    "an idle keeper death must not spend a state probe"
  pass "keep-alive wrapper: an idle keeper death stays silent with zero extra sbx calls"
}

test_keepalive_wrapper_quiet_on_clean_release() {
  # A clean idle release wins over everything, breadcrumb freshness included.
  local w fb
  w=$(new_sbx_world keeper-clean); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-x stopped > "$w/ls.json"
  mkdir -p "$w/signals/x"
  touch "$w/signals/x/x.guest-active"
  : > "$w/sbx.log"
  run_adapter "$fb" "$w" 'fm_backend_sbx_keepalive fm-x x ""; wait' \
    FM_STATE_OVERRIDE="$w/state" FM_SBX_KEEPALIVE_MAX=60 FM_SBX_MIDTASK_STOP_SETTLE=0 \
    FM_FAKE_SBX_KEEPALIVE_OUT='fm-keepalive released-idle' \
    || fail "the keep-alive call itself should succeed"
  [ ! -e "$w/state/.sbx-midtask-stop-x" ] \
    || fail "a clean idle release must not be flagged as a mid-task stop"
  assert_not_contains "$(cat "$w/sbx.log")" "ls --json" \
    "a clean idle release must not spend a state probe"
  pass "keep-alive wrapper: a clean idle release stays silent with zero extra sbx calls"
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
  assert_not_contains "$(cat "$w/sbx.log")" "ln -sfn" \
    "the provisioning re-assert is resurrect-only; routine delivery must not spend the exec"
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

# A caller with no route to the control plane cannot steer ANY sandbox, so the
# refusal must not read as "the sandbox is gone" - that sends an operator
# hunting a healthy guest. The two conditions need different responses:
# recreate the sandbox vs re-issue from a context that can reach the daemon.
test_send_refusal_names_unreadable_apart_from_absent() {
  local w fb absent_err unreadable_err
  w=$(new_sbx_world send-refusal); fb=$(make_fake_sbx "$w")
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  absent_err=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/state" 2>&1 >/dev/null || true)
  assert_contains "$absent_err" "confirmed absent" \
    "a clean inventory lacking the name must be reported as a confirmed absence"
  sbx_ls_json fm-x running > "$w/ls.json"
  unreadable_err=$(run_adapter "$fb" "$w" 'fm_backend_sbx_send_text_line sbx:fm-x "steer"' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_LS_RC=1 2>&1 >/dev/null || true)
  assert_contains "$unreadable_err" "unreadable from this context" \
    "an unreadable inventory must be reported as this caller's missing route"
  assert_not_contains "$unreadable_err" "absent" \
    "an unreadable inventory must never be reported as an absence"
  pass "send path: an unreadable inventory is refused as a missing route, not an absence"
}

# The deliverability probe behind fm-pending-reply-lib.sh's recovery deferral.
# It asks whether THIS caller has a route, so a stopped guest stays reachable
# (`sbx exec` auto-starts it) and only an unreadable inventory says no.
test_transport_reachable_tracks_route_not_power_state() {
  local w fb
  w=$(new_sbx_world reachable); fb=$(make_fake_sbx "$w")
  for st in running stopped; do
    sbx_ls_json fm-x "$st" > "$w/ls.json"
    run_adapter "$fb" "$w" 'fm_backend_sbx_transport_reachable fm-x' \
      FM_STATE_OVERRIDE="$w/state" \
      || fail "a $st sandbox must count as reachable"
  done
  printf '%s\n' "$SBX_LS_EMPTY" > "$w/ls.json"
  run_adapter "$fb" "$w" 'fm_backend_sbx_transport_reachable fm-x' \
    FM_STATE_OVERRIDE="$w/state" \
    || fail "a confirmed absence is a target problem, not an unreachable control plane"
  sbx_ls_json fm-x running > "$w/ls.json"
  if run_adapter "$fb" "$w" 'fm_backend_sbx_transport_reachable fm-x' \
    FM_STATE_OVERRIDE="$w/state" FM_FAKE_SBX_LS_RC=1 2>/dev/null; then
    fail "an unreadable inventory must report the control plane as unreachable"
  fi
  # The generic dispatcher must not hold back a backend with no probe. This
  # used to use tmux as the stand-in; tmux has its own probe now (fork issue
  # #29), so it uses one of the backends that genuinely still assumes reachable.
  # tests/fm-backend.test.sh owns the exhaustiveness guard over that set.
  run_adapter "$fb" "$w" 'fm_backend_transport_reachable zellij fm-x:0' \
    FM_STATE_OVERRIDE="$w/state" \
    || fail "a backend without a reachability probe must default to reachable"
  pass "transport_reachable follows the caller's route, not the guest's power state"
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

# new_teardown_world <name> [id]: a parent firstmate home with one sbx secondmate
# whose plain-clone home is a sibling dir, and NO host-side child
# metas - so fm-teardown.sh's host in-flight check passes and the in-guest
# landed-work probe is the gate under test.
new_teardown_world() {  # <name> [id]
  local name=$1 id=${2:-domain} w home subhome
  w=$(new_sbx_world "$name")
  home="$w/home"; subhome="$w/subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf -- '- %s - design domain (home: %s; scope: design domain; projects: alpha; added 2026-06-22)\n' "$id" "$subhome" \
    > "$home/data/secondmates.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=sbx:fm-$id" "worktree=$subhome" "project=$subhome" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$subhome" "projects=alpha" "sbx_signals_dir=$w/signals/$id"
  printf '%s\n' "$id" > "$w/teardown-id"
  printf '%s\n' "$w"
}

# run_teardown_sbx <world> <fakebin> <extra-args> [env k=v...]: run the real
# fm-teardown.sh over the world's secondmate, fake sbx first in PATH.
run_teardown_sbx() {  # <world> <fakebin> <extra> [env k=v...]
  local w=$1 fb=$2 extra=$3 id
  id=$(cat "$w/teardown-id")
  shift 3
  PATH="$fb:$PATH" FM_HOME="$w/home" \
    FM_FAKE_SBX_LOG="$w/sbx.log" FM_FAKE_SBX_LS_FILE="$w/ls.json" \
    FM_SBX_SIGNALS_ROOT="$w/signals" \
    env "$@" "$ROOT/bin/fm-teardown.sh" "$id" "$extra" 2>&1
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

test_teardown_clears_beacon_markers() {
  # The watcher's beat-beacon (scan_sbx_beacon) tracks per-id marker files in
  # the parent's state dir. Teardown must remove them with the id's other
  # state files: a leftover .sbx-stranded-alarmed marker would SUPPRESS the
  # stranding alarm for a re-provisioned same-id secondmate that is stranded
  # from birth (its status never progresses, so nothing ever clears it), and a
  # leftover .sbx-delivered marker would RAISE one for a delivery made to the
  # retired secondmate the replacement never received.
  local w fb out rc m
  w=$(new_teardown_world teardown-beacon); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-domain running > "$w/ls.json"
  : > "$w/sbx.log"
  for m in .sbx-beat-te-domain .sbx-beat-status-domain .sbx-noprogress-domain \
           .sbx-stranded-alarmed-domain .sbx-mount-alarmed-domain \
           .sbx-midtask-stop-domain .sbx-delivered-domain \
           .sbx-delivery-pending-domain.123.456; do
    : > "$w/home/state/$m"
  done
  # A neighbour whose id merely starts with this one's: teardown's candidate
  # glob is delimited by the `.` an encoded key can never contain, so it must
  # not reach the neighbour's in-flight candidate.
  : > "$w/home/state/.sbx-delivery-pending-domain-two.123.457"
  set +e
  out=$(run_teardown_sbx "$w" "$fb" "")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "clean-guest teardown should succeed: $out"
  for m in .sbx-beat-te-domain .sbx-beat-status-domain .sbx-noprogress-domain \
           .sbx-stranded-alarmed-domain .sbx-mount-alarmed-domain \
           .sbx-midtask-stop-domain .sbx-delivered-domain \
           .sbx-delivery-pending-domain.123.456; do
    [ ! -e "$w/home/state/$m" ] || fail "teardown should remove the beacon marker $m"
  done
  [ -e "$w/home/state/.sbx-delivery-pending-domain-two.123.457" ] \
    || fail "teardown of domain must not reach domain-two's in-flight delivery candidate"
  pass "teardown: the id's beat-beacon markers are removed with its state files, and no neighbour id's are"
}

test_teardown_preserves_cross_scheme_marker() {
  local w fb out rc m
  w=$(new_teardown_world teardown-ambiguous a.b); fb=$(make_fake_sbx "$w")
  sbx_ls_json fm-a.b running > "$w/ls.json"
  : > "$w/sbx.log"
  : > "$w/home/state/a_2eb.status"
  for m in .sbx-beat-te-a_2eb .sbx-beat-status-a_2eb .sbx-noprogress-a_2eb \
           .sbx-stranded-alarmed-a_2eb .sbx-mount-alarmed-a_2eb \
           .sbx-midtask-stop-a_2eb .sbx-delivered-a_2eb; do
    : > "$w/home/state/$m"
  done
  set +e
  out=$(run_teardown_sbx "$w" "$fb" "")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "cross-scheme teardown should succeed while preserving ambiguous markers: $out"
  for m in .sbx-beat-te-a_2eb .sbx-beat-status-a_2eb .sbx-noprogress-a_2eb \
           .sbx-stranded-alarmed-a_2eb .sbx-mount-alarmed-a_2eb \
           .sbx-midtask-stop-a_2eb .sbx-delivered-a_2eb; do
    [ -e "$w/home/state/$m" ] || fail "teardown removed another live task's possible legacy marker $m"
  done
  pass "teardown: cross-scheme marker paths are preserved for another live task"
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
test_agent_flavor_defaults_to_the_driver
test_agent_flavor_pin_is_independent_of_the_driver
test_agent_flavor_refuses_pairings_it_cannot_serve
test_create_task_refuses_unservable_flavor_before_anything_exists
test_create_task_creates_with_the_pinned_flavor
test_target_exists_never_execs
test_capture_gated_on_running
test_send_resurrects_dead_guest_stack
test_resume_template_quoting
test_resurrection_waits_for_stable_pane
test_resurrection_refuses_dead_pane_delivery
test_resurrection_reasserts_guest_home
test_resurrection_reasserts_claude_trust
test_resurrection_skips_claude_trust_for_a_codex_guest
test_resurrection_restores_dead_gate_daemon_with_stale_socket
test_resurrection_never_unlinks_the_guest_daemon_socket
test_resurrection_restores_dead_gate_daemon_with_no_socket
test_resurrection_never_restarts_a_running_gate_daemon
test_resurrection_leaves_an_unrecognized_daemon_status_alone
test_resurrection_skips_the_daemon_restore_without_a_gate_root
test_resurrection_reports_a_gate_root_with_no_cli
test_resurrection_survives_a_failed_daemon_restore
test_live_stack_delivery_spends_no_daemon_restore
test_guest_profiles_reinject_placeholder_into_agent_children
test_guest_profile_seed_is_idempotent_and_yields_to_the_operator
test_guest_profile_seed_reports_unowned_source_without_touching_profile
test_guest_profile_seed_repositions_owned_stale_source_line
test_guest_profile_seed_skips_absent_or_unsafe_values
test_submit_confirms_busy_pane
test_submit_retypes_when_text_swallowed
test_submit_reenters_when_enter_swallowed
test_submit_refreshes_delivery_candidate_per_retry
test_submit_failure_preserves_previous_delivery_edge
test_submit_retype_failure_preserves_previous_delivery_edge
test_submit_ignores_stale_prefix_line_in_scrollback
test_submit_retypes_when_stale_prefix_goes_busy
test_submit_counts_full_history_when_window_scrolls
test_submit_fails_when_baseline_capture_fails
test_send_starts_keepalive_after_delivery
test_send_records_delivery_breadcrumb
test_delivery_breadcrumb_is_not_shared_by_colliding_ids
test_delivery_breadcrumb_predates_guest_acknowledgement
test_delivery_beacon_prepare_failure_refuses_before_send
test_delivery_beacon_publish_failure_does_not_invite_resend
test_failed_delivery_preserves_previous_breadcrumb
test_control_input_does_not_arm_delivery_beacon
test_send_to_foreign_name_records_no_breadcrumb
test_keepalive_script_capped_verdicts
test_keepalive_script_pins_busy_worker_across_turn_end
test_keepalive_script_releases_idle_guest_on_turn_end
test_keepalive_script_pins_redrawing_crewmate_with_quiet_tail
test_keepalive_script_releases_static_crewmate_pane
test_keepalive_script_change_arm_needs_a_registered_crewmate
test_keepalive_script_pins_an_offscreen_gate_run
test_keepalive_script_gate_arm_reads_a_runs_step_log
test_keepalive_script_gate_arm_releases_a_quiet_gate
test_keepalive_script_pins_a_worker_parked_on_a_decision
test_keepalive_script_parked_worker_survives_the_secondmate_turn_end
test_keepalive_script_parked_pin_releases_when_the_answer_lands
test_keepalive_script_releases_a_finished_worker_with_an_open_decision
test_keepalive_script_parked_arm_needs_a_registered_crewmate
test_keepalive_script_parked_pin_leaves_the_breadcrumb_alone
test_keepalive_script_parked_arm_fails_closed_without_the_predicate
test_keepalive_script_detail_names_the_deciding_arm
test_keepalive_script_detail_reports_panes_and_gate_freshness
test_keepalive_script_detail_reports_the_pane_change_arm
test_keepalive_script_detail_stamps_release_against_task_state
test_keepalive_detail_classifies_a_signin_park
test_keepalive_detail_never_records_the_pane_text
test_keepalive_detail_classifies_a_finished_worker
test_keepalive_detail_admits_an_unrecognised_static_pane
test_keepalive_detail_reports_no_park_when_work_is_visible
test_keepalive_detail_reports_no_park_without_a_registered_task
test_keepalive_detail_classifies_a_signin_park_without_a_task
test_keepalive_detail_park_fails_closed_without_the_predicate
test_keepalive_detail_park_needs_a_signature_to_claim_auth
test_keepalive_wrapper_logs_every_verdict
test_keepalive_wrapper_log_carries_validated_guest_detail
test_keepalive_wrapper_log_failure_cannot_affect_the_keeper
test_keepalive_log_growth_is_bounded
test_keepalive_wrapper_marks_midtask_stop_on_capped_active
test_keepalive_wrapper_skips_marker_when_vm_still_running
test_keepalive_wrapper_marks_dropped_connection_with_fresh_breadcrumb
test_keepalive_wrapper_quiet_on_idle_death
test_keepalive_wrapper_quiet_on_clean_release
test_send_skips_resurrection_when_stack_alive
test_send_refuses_absent_sandbox
test_send_refusal_names_unreadable_apart_from_absent
test_transport_reachable_tracks_route_not_power_state
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
test_teardown_clears_beacon_markers
test_teardown_preserves_cross_scheme_marker
test_teardown_force_skips_guest_probe

echo "# all fm-backend-sbx tests passed"
