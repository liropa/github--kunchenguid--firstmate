#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# The awaiting-validation verb. On a no-mistakes ship task the crew commits its
# implementation and then STOPS, because firstmate owes it the validation trigger
# (AGENTS.md section 7 "Validate"). That handoff is NOT a completion, so it gets
# its own verb instead of reusing `done:`. Sharing `done:` made the two states
# indistinguishable in the durable record: a supervisor reading the last status
# line could not tell "waiting on you" from "shipped" without further inspection,
# and an away-mode crew could idle indefinitely behind a record that read as
# success. It is captain-relevant (firstmate must see it and act) and terminal
# (the crew ended its turn and will not advance on its own), but terminal is not
# the same as complete - needs-decision and blocked are terminal-and-unfinished in
# exactly the same way. This constant is the ONE definition of the verb; the
# captain regex below, status_is_terminal_verb, bin/fm-crew-state.sh's
# map_log_state, and bin/fm-brief.sh's generated brief all read it here rather
# than hardcoding a second copy. Like the other terminal captain verbs it is not
# individually overridable: a home wanting a different vocabulary replaces the
# whole set through FM_CAPTAIN_RE.
FM_CLASSIFY_AWAITING_VALIDATION_VERB='awaiting-validation'

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT="done:|${FM_CLASSIFY_AWAITING_VALIDATION_VERB}:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged"

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, awaiting-validation, needs-decision, blocked, failed). Terminal here means
# the crew ENDED ITS TURN and will not advance without firstmate - it does not mean
# the task finished: needs-decision, blocked, and awaiting-validation are all
# terminal-and-unfinished. Free-text tokens alone never count here; callers that
# need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed|"$FM_CLASSIFY_AWAITING_VALIDATION_VERB") return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed|"$FM_CLASSIFY_AWAITING_VALIDATION_VERB") return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format). An OPTIONAL "[key=<slug>]" token names the thread a line belongs to,
# and it is read in EITHER placement, both folding to the same key:
#   needs-decision [key=api-shape]: <summary>      canonical, before the colon
#   needs-decision: [key=api-shape] <summary>      accepted, leading the note
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
#
# After the colon, POSITION is part of the grammar: only a token that LEADS the
# note counts, optionally after the machine-written "corr=<16hex>" reply token a
# secondmate echoes back. A "[key=...]" further inside the prose stays prose,
# because notes legitimately QUOTE another event's key ("I will require the
# matching resolved: [key=nm-review-gate] event"). Reading those as keys would
# let a sentence ABOUT a decision close that decision, which loses more than the
# shared-bucket mis-folding this placement rule exists to fix.
#
# A token that is present but unreadable is neither renamed to "default" nor
# dropped; see FM_CLASSIFY_INVALID_KEY_PREFIX for the treatment and why it is
# visible.
#
# The parsers are pure reads of a single line. The verb parser strips any key
# token before the colon so the leading word is recovered cleanly, and the note
# parser strips a recognized leading token so both placements yield one note.

# Marker for a key token that is PRESENT but unreadable (empty, or holding a
# character outside the A-Za-z0-9._- slug set). Such a token is never silently
# renamed to "default", because folding unrelated threads into one shared bucket
# is the defect keys exist to prevent, and never silently dropped, because a
# dropped needs-decision or blocked line reaches nobody at all. It keeps a bucket
# of its own under this prefix, which is observable three ways: the raw token is
# preserved, so two different malformed tokens stay apart; "!" cannot occur in a
# valid slug, so a marked key is unmistakable wherever the fold is rendered (the
# fleet snapshot, bin/fm-parked-decision.sh, bin/fm-afk-return.sh's catch-up
# gate); and no well-formed key can close it, so the decision keeps surfacing
# until the producer is repaired. The mapping is deterministic, so a resolution
# carrying the same malformed token still closes its own thread.
FM_CLASSIFY_INVALID_KEY_PREFIX='invalid-key!'

status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

# Split a note into its optional leading correlation token, its optional leading
# "[key=<token>]", and the text after both, assigning each to the named variable.
# Returns 0 when a key token led the note (even if its slug is unreadable) and 1
# when none did, so callers can tell "no token" from "empty token".
#
# The "corr=<16hex>" grammar is owned by bin/fm-pending-reply-lib.sh
# (FM_PENDING_REPLY_CORR_RE), which strips the same prefix when it rewrites a
# marked message. It is matched here as a literal glob rather than by sourcing
# that library, because this classifier is a pure read that the away-mode daemon
# and bin/fm-afk-return.sh source without the backend and tmux libraries
# fm-pending-reply-lib.sh pulls in.
#
# Locals carry a _fmns_ prefix because bash scoping is dynamic: a local named
# after one of the caller's output variables would shadow it, and printf -v would
# then write to this frame instead of the caller's.
_fm_note_split() {  # <note> <corr-var> <token-var> <rest-var>
  local _fmns_n=$1 _fmns_corr='' _fmns_token='' _fmns_rest
  _fmns_n=${_fmns_n#"${_fmns_n%%[![:space:]]*}"}
  case "${_fmns_n:0:21}" in
    corr=[A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9])
      _fmns_corr=${_fmns_n:0:21}
      _fmns_n=${_fmns_n:21}
      _fmns_n=${_fmns_n#"${_fmns_n%%[![:space:]]*}"}
      ;;
  esac
  _fmns_rest=$_fmns_n
  case "$_fmns_n" in
    \[key=*\]*)
      _fmns_token=${_fmns_n#\[key=}
      _fmns_token=${_fmns_token%%\]*}
      _fmns_rest=${_fmns_n#*\]}
      _fmns_rest=${_fmns_rest#"${_fmns_rest%%[![:space:]]*}"}
      printf -v "$2" '%s' "$_fmns_corr"
      printf -v "$3" '%s' "$_fmns_token"
      printf -v "$4" '%s' "$_fmns_rest"
      return 0
      ;;
  esac
  printf -v "$2" '%s' "$_fmns_corr"
  printf -v "$3" '%s' "$_fmns_token"
  printf -v "$4" '%s' "$_fmns_rest"
  return 1
}

status_line_note() {  # <status-line> -> text after the first colon, trimmed
  # shellcheck disable=SC2034 # corr/token/rest are set by name through _fm_note_split.
  local n corr token rest
  case "$1" in
    *:*) n=${1#*:} ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  if _fm_note_split "$n" corr token rest; then
    if [ -n "$corr" ] && [ -n "$rest" ]; then
      printf '%s %s' "$corr" "$rest"
    elif [ -n "$corr" ]; then
      printf '%s' "$corr"
    else
      printf '%s' "$rest"
    fi
    return 0
  fi
  printf '%s' "${n#"${n%%[![:space:]]*}"}"
}

# Validate one raw key token: a well-formed slug passes through unchanged, and an
# unreadable one is marked rather than lost. See FM_CLASSIFY_INVALID_KEY_PREFIX.
_fm_decision_key_slug() {  # <raw-token> -> slug or marked invalid key
  local k=$1
  case "$k" in
    ''|*[!A-Za-z0-9._-]*)
      # A TAB would corrupt the fold's "<key>\t<verb>\t<note>" record shape.
      k=${k//$'\t'/ }
      k=${k//$'\r'/ }
      printf '%s%s' "$FM_CLASSIFY_INVALID_KEY_PREFIX" "$k"
      ;;
    *) printf '%s' "$k" ;;
  esac
}

_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  # shellcheck disable=SC2034 # corr/rest are set by name through _fm_note_split.
  local line=$1 prefix note corr token rest
  prefix=${line%%:*}
  case "$prefix" in
    *\[key=*\]*)
      token=${prefix#*\[key=}
      _fm_decision_key_slug "${token%%\]*}"
      return 0
      ;;
  esac
  case "$line" in
    *:*) note=${line#*:} ;;
    *) printf 'default'; return 0 ;;
  esac
  if _fm_note_split "$note" corr token rest; then
    _fm_decision_key_slug "$token"
  else
    printf 'default'
  fi
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line")
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# 0 when this task has FINISHED: its newest recorded event is done or failed.
# Finished is narrower than status_is_terminal_verb's "ended its turn":
# needs-decision, blocked and awaiting-validation are all terminal-and-unfinished.
#
# Two callers need this same rule and it is stated here once. An EMPTY kind is
# "not finished", because finished cannot be asserted about a task whose shape is
# unknown; a secondmate is likewise never finished, because it never reaches a
# terminal event of its own.
status_task_finished() {  # <status-file> <kind>
  local f=$1 kind=$2 verb
  [ -n "$kind" ] || return 1
  [ "$kind" != secondmate ] || return 1
  [ -e "$f" ] || return 1
  verb=$(status_line_verb "$(last_status_line "$f")")
  case "$verb" in
    done|failed) return 0 ;;
  esac
  return 1
}

# status_open_decisions restricted to decisions a LIVE task is still parked on.
# Same fold, same output shape, plus one rule: a task that has finished
# (status_task_finished above) is no longer sitting on anything and prints
# nothing.
#
# The two folds answer different questions and both are needed. The plain fold
# answers "what does this origin still owe the captain", which a finished task
# still owes; this one answers "is this worker still waiting", which a finished
# task is not.
status_open_decisions_live() {  # <status-file> <kind>
  local f=$1 kind=$2 open
  open=$(status_open_decisions "$f")
  [ -n "$open" ] || return 0
  status_task_finished "$f" "$kind" && return 0
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, awaiting-validation, failed, needs-decision, blocked, or resolved
# event carrying that key closes the phase, because it has moved to a terminal or
# separately tracked state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line")
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$FM_CLASSIFY_AWAITING_VALIDATION_VERB"|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
