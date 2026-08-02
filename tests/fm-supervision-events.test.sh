#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep, handle_push_transition in
# bin/fm-watch.sh). The watcher's source guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted deterministically with no
# real herdr, watcher process, or blocking sleeps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-supervision-events)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: a blocked edge ARMS the dwell, it does not alarm --

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a blocked EDGE must not enqueue on its own: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a blocked edge must not wake the supervisor before its dwell elapses"
fm_backend_deferred_since herdr "$STATE_DIR" default:wG:pQ >/dev/null \
  || fail "handle_push_transition must arm the pane's confirmation dwell"
grep -q 'deferred push blocked' "$STATE_DIR/.watch-triage.log" 2>/dev/null \
  || fail "the armed dwell should be logged to the triage log"
pass "handle_push_transition: a blocked crew arms its confirmation dwell instead of alarming on the edge"

# --- handle_push_transition: absorb (no wake, no enqueue) for a declared pause -

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/tk2.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a declared-pause crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a declared-pause crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the paused absorb should be logged to the triage log"
pass "handle_push_transition: a declared-pause crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- push_block_dwell_check: the dwell separates serviced from unserviced blocks
#
# These cases are the repaired form of the counterfactual harness in
# data/herdr-approval-wake-storm/report.md section 5, which drove the shipped
# functions with and without intervening `working` edges and measured 1
# escalation against 5. They pin BOTH halves of the repair: a clearer-style
# cycle now escalates zero times, and a block nothing services still escalates
# exactly once, after the dwell.

WIN=default:wG:pQ
fm_backend_source herdr || fail "the herdr backend must load for the dwell cases"

# Re-arm the pane's marker as though <secs> had already passed since its block,
# through the same public call handle_push_transition arms it with. Moving the
# recorded epoch keeps every case instant instead of sleeping a real dwell.
age_armed_block() {  # <window> <secs>
  fm_backend_defer_transition herdr "$STATE_DIR" "$1" "$(( $(date +%s) - $2 ))"
}
wake_count() { wc -l < "$WAKE_LOG" | tr -d '[:space:]'; }
working_edge() {  # <window-suffix>
  fm_backend_herdr_apply_transition "$STATE_DIR" default "$(mkrec "$1" working)" >/dev/null
}

# Case A: a block nothing services escalates once, and only once the dwell is up.
reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=$WIN" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 0 ] || fail "a block younger than the dwell must not escalate"
age_armed_block "$WIN" $(( PUSH_BLOCK_DWELL_SECS - 1 ))
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 0 ] || fail "a block one second short of the dwell must not escalate"
age_armed_block "$WIN" "$PUSH_BLOCK_DWELL_SECS"
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 1 ] || fail "a block that outlives the dwell must escalate, got $(wake_count)"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
grep -q "$WIN" "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'escalated push blocked' "$STATE_DIR/.watch-triage.log" 2>/dev/null \
  || fail "the escalating branch must leave a trace in the triage log"
push_block_dwell_check "$WIN" ""
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 1 ] || fail "a settled block must stay at ONE wake across later poll cycles, got $(wake_count)"
if fm_backend_herdr_apply_transition "$STATE_DIR" default "$(mkrec wG:pQ blocked)" >/dev/null; then
  fail "a further blocked edge on a settled pane must not be re-delivered"
fi
pass "push_block_dwell_check: a block nothing services escalates exactly once, after the dwell (report case A)"

# Case B: the approval-clearer cycle - blocked -> working -> blocked ... - which
# previously bought one escalation per cycle, now escalates zero times.
reset_state
fm_write_meta "$STATE_DIR/tk7.meta" "window=$WIN" "backend=herdr" "kind=ship"
i=0
while [ "$i" -lt 5 ]; do
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
  push_block_dwell_check "$WIN" ""
  working_edge wG:pQ
  push_block_dwell_check "$WIN" ""
  i=$((i + 1))
done
[ "$(wake_count)" = 0 ] || fail "5 clearer-serviced block cycles must produce ZERO escalations, got $(wake_count)"
pass "push_block_dwell_check: 5 clearer-serviced block cycles escalate 0 times where each cycle previously bought one"

# The cancel is not merely "the block was young": age an armed block well PAST
# the dwell first, then deliver the clearer's working edge. Cancelling an alarm
# that has not fired and deduping one that has are different operations, and only
# this case tells them apart.
reset_state
fm_write_meta "$STATE_DIR/tk7.meta" "window=$WIN" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
age_armed_block "$WIN" $(( PUSH_BLOCK_DWELL_SECS * 3 ))
working_edge wG:pQ
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 0 ] || fail "a working edge must CANCEL a pending escalation, even one already past the dwell"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 0 ] || fail "the next block must start a fresh dwell rather than inherit the cancelled one"
pass "push_block_dwell_check: a working edge cancels a pending escalation and the next block starts a fresh dwell"

# Case C, the binding constraint: an unattended crew really waiting on a human is
# blocked indefinitely, so it crosses any finite dwell and must still escalate -
# once - and stay protected afterwards rather than being silenced for good.
reset_state
fm_write_meta "$STATE_DIR/tk8.meta" "window=$WIN" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
age_armed_block "$WIN" $(( PUSH_BLOCK_DWELL_SECS * 20 ))
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 1 ] || fail "an unattended human-wait must still escalate, got $(wake_count)"
working_edge wG:pQ
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
age_armed_block "$WIN" "$PUSH_BLOCK_DWELL_SECS"
push_block_dwell_check "$WIN" ""
[ "$(wake_count)" = 2 ] || fail "a later unserviced block must escalate again once someone has acted, got $(wake_count)"
pass "push_block_dwell_check: an unattended human-wait still escalates once per unserviced block (binding constraint)"

# A crew that declares an external wait DURING the dwell is absorbed, matching
# the exemption handle_push_transition applies at the edge.
reset_state
fm_write_meta "$STATE_DIR/tk9.meta" "window=$WIN" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
age_armed_block "$WIN" "$PUSH_BLOCK_DWELL_SECS"
push_block_dwell_check "$WIN" "paused: waiting on the upstream release"
[ "$(wake_count)" = 0 ] || fail "a crew that declares a pause during the dwell must be absorbed, got $(wake_count)"
pass "push_block_dwell_check: a pause declared during the dwell absorbs the pending escalation"

# The enqueue-before-settle ordering: a failed durable enqueue must leave the
# escalation pending so the next watcher run re-escalates it.
reset_state
fm_write_meta "$STATE_DIR/tk10.meta" "window=$WIN" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
age_armed_block "$WIN" "$PUSH_BLOCK_DWELL_SECS"
(
  fm_wake_append() { return 1; }
  push_block_dwell_check "$WIN" ""
) >/dev/null 2>&1 || true
fm_backend_deferred_since herdr "$STATE_DIR" "$WIN" >/dev/null \
  || fail "a failed durable enqueue must leave the escalation pending, not settled"
pass "push_block_dwell_check: enqueue failure cannot settle the marker, so the alarm is never lost"

# A tmux home has no push path at all, so the re-check is inert for it.
reset_state
fm_write_meta "$STATE_DIR/tk11.meta" "window=fmses:fm-tk11" "kind=ship"
push_block_dwell_check fmses:fm-tk11 ""
[ "$(wake_count)" = 0 ] || fail "a non-push backend must never escalate through the dwell re-check"
pass "push_block_dwell_check: a home with no push-capable backend is inert"

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
fm_backend_wait_transition() {
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
EVENT_CAP_FAIL_MAX=2
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"

echo "# fm-supervision-events.test.sh: all assertions passed"
