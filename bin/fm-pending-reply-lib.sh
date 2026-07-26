#!/usr/bin/env bash
# fm-pending-reply-lib.sh - parent-owned secondmate missed-report guards.
#
# When the main firstmate delivers a marked from-firstmate request to a
# secondmate, this library records a durable parent-owned pending-reply
# expectation BEFORE delivery, embeds a privacy-safe correlation id in the
# outbound message, and later resolves that expectation only from a correlated
# parent status line or status-pointed document - never from transport success,
# chat content, or unrelated status activity.
#
# Safety property (captain direction 2026-07-22): a secondmate agent may ignore
# the marker and answer only in its visible conversation. The parent must notice
# the missing correlated report without scraping that conversation, send exactly
# one automatic recovery request asking for a repost through the parent channel,
# and escalate once if the recovery turn also completes without a correlated
# report. Never loop, never repeatedly inject, never silently expire unresolved
# records, and never treat wrong-home or structured-home heuristics as
# acknowledgement.
#
# Record location (parent FM_HOME):
#   state/pending-replies/<corr_id>
# Each record is a key=value file owned by this library. Schema:
#   schema=fm-pending-reply.v1
#   corr_id=                privacy-safe correlation token
#   task_id=                secondmate task id in the parent home
#   parent_home=            absolute parent FM_HOME
#   parent_status=          absolute path of parent state/<task_id>.status
#   parent_status_scan_signature=  rescan gate signature of parent_status
#                           (fm_pending_reply_file_signature owns the stat -L
#                           symlink semantics)
#   request_summary=        short sanitized summary (no secrets by design)
#   created_epoch=          when the expectation was created
#   delivered_epoch=        when the marked request was confirmed delivered
#                           (empty until delivery; delivery never resolves)
#   phase=                  awaiting_report | delivery_unknown | recovery_sending |
#                           recovery_sent | recovery_failed | recovery_unknown |
#                           recovery_deferred | escalated | resolved |
#                           reconciled_stale
#                           recovery_failed means a send was made and did not
#                           land; recovery_deferred means no send was made at
#                           all because this context had no route to the
#                           endpoint. Both escalate; only the first consumed the
#                           record's one recovery attempt.
#   turn_seen_busy=         0|1 after delivery for the original request turn
#   request_turn_completed_epoch=
#   request_turnend_signature=  size:mtime signature of state/<task_id>.turn-ended
#                           snapshotted at delivery; the sbx completion source
#                           below reads any later signature change as request-turn
#                           completion. Key PRESENCE also marks a post-upgrade
#                           record for the one-time stale reconciliation.
#   recovery_turnend_signature= same snapshot taken when the recovery send is
#                           confirmed, anchoring the recovery-turn completion read
#   reconciled_epoch=       when the one-time stale reconciliation retired this record
#   reconciled_reported_epoch= when the stale retirement summary was published
#   recovery_attempted_epoch=
#   recovery_sender_pid=
#   recovery_sender_identity=  ps identity of the committing sender, or a
#                           self-declared flock-identity marker when ps is
#                           unavailable (fm_pending_reply_sender_identity)
#   recovery_sent_epoch=
#   recovery_delivery_outcome=
#   recovery_deferred_epoch= when the recovery send was deferred UNATTEMPTED
#                           because this context had no route to the endpoint;
#                           recovery_attempted_epoch stays empty, so the one
#                           recovery is still owed rather than spent
#   recovery_defer_reason=  short token naming that no-route condition
#   recovery_turn_seen_busy=
#   recovery_turn_completed_epoch=
#   escalated_epoch=
#   resolved_epoch=
#   resolved_via=           status | document | helper | empty
#   wrong_home_hits=        count of corr sightings under the secondmate home
#   wrong_home_sightings=   comma-separated identities of counted sightings
#   wrong_home_scan_signature=
#   grace_secs=             bounded grace before recovery is eligible
#
# sbx completion source: an sbx-backed secondmate's state/<task_id>.turn-ended
# is a host-side symlink onto the signal-bridge mount, guest-touched at every
# turn end and host-stat-able even while the VM is stopped (bin/fm-spawn.sh's
# sbx branch; docs/sbx-backend.md "Signal bridge wiring"). fm_backend_busy_state
# has no sbx semantics and the capture fallback would need `sbx exec` into a
# running VM, so for backend=sbx the tick derives turn completion from a
# turn-ended signature change since the anchored snapshot instead of pane
# observation (fm_pending_reply_sbx_busy_state) - pure host stats, zero sbx CLI
# calls, preserving the idle-supervision cost property. Like pane busy/idle,
# a signature change proves A turn boundary, not specifically the request's;
# an absent or unreadable turn-ended file yields no proof and leaves completion
# unset, the same fail-safe posture as an unknown pane observation.
#
# One-time stale reconciliation: records created before the sbx completion
# source existed (no request_turnend_signature key in the file) could sit in
# awaiting_report forever for sbx-backed tasks, because observation was
# permanently unknown. fm_pending_reply_tick retires those pre-upgrade sbx
# records into the terminal reconciled_stale phase - visibly, via one summary
# `blocked: pending-reply-stale-reconciled:` status line per affected task -
# instead of burst-sending recovery nags for long-dead requests. Retired
# records are never marked resolved-as-answered, remain on disk, and a
# correlated report seen during the sweep still resolves normally. If a sweep
# pass is interrupted mid-way, the next pass retires the remainder with its own
# summary line - bounded and loud, never silent.
#
# Sourced by bin/fm-send.sh, bin/fm-watch.sh, bin/fm-secondmate-report.sh, and
# tests. No side effects on source. set -u / set -e safe.
#
# Tunables (env):
#   FM_PENDING_REPLY_GRACE_SECS   default 120
#   FM_PENDING_REPLY_DIR_OVERRIDE override the pending-replies directory (tests)
#   FM_PENDING_REPLY_SEND_HOOK    optional command template for recovery delivery
#                                 (tests); receives task_id and full message as args
#   FM_PENDING_REPLY_NOW          optional fixed epoch for deterministic tests

# shellcheck source=bin/fm-marker-lib.sh
_FM_PENDING_REPLY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PENDING_REPLY_LIB_DIR="."
# shellcheck source=bin/fm-marker-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$_FM_PENDING_REPLY_LIB_DIR/fm-tmux-lib.sh"

FM_PENDING_REPLY_SCHEMA='fm-pending-reply.v1'
FM_PENDING_REPLY_CORR_RE='corr=[A-Fa-f0-9]{16}'
FM_PENDING_REPLY_GRACE_DEFAULT=120

fm_pending_reply_now() {
  if [ -n "${FM_PENDING_REPLY_NOW:-}" ]; then
    printf '%s' "$FM_PENDING_REPLY_NOW"
    return 0
  fi
  date +%s
}

fm_pending_reply_grace_secs() {
  local g=${FM_PENDING_REPLY_GRACE_SECS:-$FM_PENDING_REPLY_GRACE_DEFAULT}
  case "$g" in
    ''|*[!0-9]*) g=$FM_PENDING_REPLY_GRACE_DEFAULT ;;
  esac
  printf '%s' "$g"
}

# Directory holding durable pending-reply records for <state-dir>.
fm_pending_reply_dir() {  # <state-dir>
  local state=$1
  if [ -n "${FM_PENDING_REPLY_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$FM_PENDING_REPLY_DIR_OVERRIDE"
    return 0
  fi
  printf '%s/pending-replies' "$state"
}

fm_pending_reply_path() {  # <state-dir> <corr_id>
  printf '%s/%s' "$(fm_pending_reply_dir "$1")" "$2"
}

# Privacy-safe correlation id: 16 lowercase hex chars (64 bits of entropy).
fm_pending_reply_new_id() {
  local raw hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" | cksum 2>/dev/null | awk '{print $1}')
    hex=$(printf '%s' "$raw$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:16}
  fi
  printf '%s' "$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)"
}

fm_pending_reply_corr_token() {  # <corr_id>
  printf 'corr=%s' "$1"
}

# Extract the first corr=<16hex> token from free text, or empty.
fm_pending_reply_extract_corr() {  # <text>
  local text=$1
  printf '%s' "$text" | grep -oE "$FM_PENDING_REPLY_CORR_RE" 2>/dev/null | head -1 | cut -d= -f2- | tr 'A-F' 'a-f' || true
}

# 0 if <text> carries the exact correlation token for <corr_id>.
fm_pending_reply_text_has_corr() {  # <text> <corr_id>
  local text=$1 corr=$2 token
  token=$(fm_pending_reply_corr_token "$corr")
  case "$text" in
    *"$token"*) return 0 ;;
  esac
  return 1
}

# Sanitize a short request summary: single line, bounded, no control chars.
fm_pending_reply_summarize() {  # <text>
  local text=$1 cleaned
  cleaned=$(printf '%s' "$text" | tr '\t\r\n' '   ' | tr -cd '\11\12\15\40-\176' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Drop an already-present marker/corr prefix so the durable summary stays short.
  cleaned=${cleaned#"$FM_FROMFIRST_MARK"}
  cleaned=$(printf '%s' "$cleaned" | sed -E "s/^corr=[A-Fa-f0-9]{16}[[:space:]]*//")
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

fm_pending_reply_get() {  # <record-path> <key>
  local rec=$1 key=$2
  [ -f "$rec" ] || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_pending_reply_corr_reusable() {  # <state-dir> <corr_id> <task_id>
  local state=$1 corr=$2 task_id=$3 rec phase
  printf '%s' "$corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 1
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ "$(fm_pending_reply_get "$rec" task_id)" = "$task_id" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending|recovery_sent) return 0 ;;
  esac
  return 1
}

# Rewrite one key in a pending-reply record atomically. Other keys preserved.
fm_pending_reply_set() {  # <record-path> <key> <value>
  local rec=$1 key=$2 value=$3 dir base tmp line
  [ -f "$rec" ] || return 1
  dir=$(dirname "$rec")
  base=$(basename "$rec")
  tmp="$dir/.${base}.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || return 1
  mv -f "$tmp" "$rec"
}

# Embed or replace a correlation token after the from-firstmate marker.
# Idempotent for the same corr; replaces a different leading corr token.
# Result is assigned to <result-var>.
# Trailing newlines in the request body are preserved: never strip via bare
# $(...) on the body (command substitution removes trailing newlines).
fm_pending_reply_embed_corr() {  # <message> <corr_id> <result-var>
  local message=$1 corr=$2 result_var=$3 body token marked existing
  [ -n "$result_var" ] || return 2
  token=$(fm_pending_reply_corr_token "$corr")
  fm_message_mark_from_firstmate "$message" marked
  body=${marked#"$FM_FROMFIRST_MARK"}
  # Strip a leading corr=<16hex> plus following blanks (space/tab only).
  existing=${body:0:21}
  case "$existing" in
    corr=[a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9])
      body=${body:21}
      while [ "${body# }" != "$body" ]; do body=${body# }; done
      while [ "${body#$'\t'}" != "$body" ]; do body=${body#$'\t'}; done
      ;;
  esac
  printf -v "$result_var" '%s' "${FM_FROMFIRST_MARK}${token} ${body}"
}

# Create a durable pending-reply expectation. Prints corr_id on success.
# Does not deliver anything. Fails if parent paths cannot be prepared.
fm_pending_reply_create() {  # <parent-home> <state-dir> <task_id> <request-text>
  local parent_home=$1 state=$2 task_id=$3 request_text=$4
  local dir rec corr now summary status_path tmp
  [ -n "$parent_home" ] && [ -n "$state" ] && [ -n "$task_id" ] || return 2
  dir=$(fm_pending_reply_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  corr=$(fm_pending_reply_new_id)
  [ "${#corr}" -eq 16 ] || return 1
  rec=$(fm_pending_reply_path "$state" "$corr")
  # Extremely unlikely collision; regenerate once.
  if [ -e "$rec" ]; then
    corr=$(fm_pending_reply_new_id)
    rec=$(fm_pending_reply_path "$state" "$corr")
    [ ! -e "$rec" ] || return 1
  fi
  now=$(fm_pending_reply_now)
  summary=$(fm_pending_reply_summarize "$request_text")
  status_path="$state/${task_id}.status"
  # Prefer absolute parent_status when parent_home/state resolve.
  case "$status_path" in
    /*) ;;
    *) status_path="$(cd "$state" 2>/dev/null && pwd)/${task_id}.status" ;;
  esac
  case "$parent_home" in
    /*) ;;
    *) parent_home=$(cd "$parent_home" 2>/dev/null && pwd) || parent_home=$1 ;;
  esac
  tmp="$dir/.${corr}.tmp.$$"
  cat > "$tmp" <<EOF
schema=$FM_PENDING_REPLY_SCHEMA
corr_id=$corr
task_id=$task_id
parent_home=$parent_home
parent_status=$status_path
parent_status_scan_signature=
request_summary=$summary
created_epoch=$now
delivered_epoch=
phase=awaiting_report
turn_seen_busy=0
request_turn_completed_epoch=
request_turnend_signature=
recovery_turnend_signature=
reconciled_epoch=
reconciled_reported_epoch=
recovery_attempted_epoch=
recovery_sender_pid=
recovery_sender_identity=
recovery_sent_epoch=
recovery_delivery_outcome=
recovery_turn_seen_busy=0
recovery_turn_completed_epoch=
escalated_epoch=
resolved_epoch=
resolved_via=
wrong_home_hits=0
wrong_home_sightings=
wrong_home_scan_signature=
grace_secs=$(fm_pending_reply_grace_secs)
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec" || return 1
  printf '%s' "$corr"
}

# Mark delivery success for an existing expectation. Never resolves.
# Also anchors request_turnend_signature at first delivery so the sbx
# completion source can read a later turn-ended change as request-turn
# completion; a late reconciled delivery may anchor a post-completion
# signature, which only delays completion (fail-safe), never fakes it.
fm_pending_reply_mark_delivered() {  # <state-dir> <corr_id> [confirmed-epoch]
  local state=$1 corr=$2 confirmed_epoch=${3-} rec phase delivered now task_id
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|delivery_unknown|recovery_sending|recovery_sent|escalated|resolved) ;;
    *) return 1 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    now=${confirmed_epoch:-$(fm_pending_reply_now)}
    fm_pending_reply_set "$rec" delivered_epoch "$now" || return 1
    task_id=$(fm_pending_reply_get "$rec" task_id)
    fm_pending_reply_set "$rec" request_turnend_signature \
      "$(fm_pending_reply_turnend_signature "$state" "$task_id")" || return 1
  fi
  if [ "$phase" = delivery_unknown ]; then
    fm_pending_reply_set "$rec" phase awaiting_report || return 1
  fi
  return 0
}

fm_pending_reply_delivery_confirmation_path() {  # <state-dir> <corr_id>
  printf '%s/.delivery-confirmed-%s' "$(fm_pending_reply_dir "$1")" "$2"
}

fm_pending_reply_write_delivery_confirmation() {  # <state-dir> <corr_id> <state> <value>
  local pending_state=$1 corr=$2 delivery_state=$3 value=$4 marker dir tmp
  marker=$(fm_pending_reply_delivery_confirmation_path "$pending_state" "$corr")
  dir=$(dirname "$marker")
  mkdir -p "$dir" || return 1
  tmp="$marker.tmp.$$"
  printf '%s=%s\n' "$delivery_state" "$value" > "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker"
}

fm_pending_reply_prepare_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 0
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  [ -f "$marker" ] && return 0
  now=$(fm_pending_reply_now)
  fm_pending_reply_write_delivery_confirmation "$state" "$corr" attempted "$now"
}

fm_pending_reply_confirm_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 now marker
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  if ! fm_pending_reply_prepare_delivery "$state" "$corr"; then
    return 1
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_write_delivery_confirmation "$state" "$corr" confirmed "$now" || return 1
  if fm_pending_reply_mark_delivered "$state" "$corr" "$now"; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  return 2
}

fm_pending_reply_reconcile_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker entry delivery_state value epoch
  local grace now age phase
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -n "$delivered" ]; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  [ -f "$marker" ] || return 1
  entry=$(cat "$marker" 2>/dev/null || true)
  delivery_state=${entry%%=*}
  value=${entry#*=}
  case "$delivery_state" in
    confirmed)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      fm_pending_reply_mark_delivered "$state" "$corr" "$epoch" || return 1
      rm -f "$marker" 2>/dev/null || true
      return 0
      ;;
    attempted)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      grace=$(fm_pending_reply_get "$rec" grace_secs)
      case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
      now=$(fm_pending_reply_now)
      age=$((now - epoch))
      [ "$age" -ge "$grace" ] || return 1
      phase=$(fm_pending_reply_get "$rec" phase)
      [ "$phase" = awaiting_report ] || return 1
      fm_pending_reply_set "$rec" phase delivery_unknown || return 1
      return 0
      ;;
  esac
  return 1
}

# Drop an undelivered expectation after a failed send so transport failure does
# not masquerade as a missed report later.
fm_pending_reply_discard_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 0
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  rm -f "$marker" 2>/dev/null || true
  rm -f "$rec"
}

# 0 if a status line is a correlated acknowledgement for <corr_id>.
# Accepts short status replies and status lines that point at a document.
# Unrelated verbs without the token never match. Stale/wrong corr never match.
# The parent's own pending-reply-missed escalation line must not self-resolve:
# it names the request with pending-reply-id= rather than corr=.
fm_pending_reply_line_resolves() {  # <line> <corr_id>
  local line=$1 corr=$2
  [ -n "$line" ] && [ -n "$corr" ] || return 1
  case "$line" in
    *pending-reply-missed*) return 1 ;;
  esac
  fm_pending_reply_text_has_corr "$line" "$corr"
}

# Scan a status file for a correlated resolve. Prints the matching line or empty.
fm_pending_reply_find_resolve_line() {  # <status-file> <corr_id>
  local status_file=$1 corr=$2 line
  [ -f "$status_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if fm_pending_reply_line_resolves "$line" "$corr"; then
      printf '%s' "$line"
      return 0
    fi
  done < "$status_file"
  return 0
}

# Full-attribute change signature of a file, following symlinks (-L): an sbx
# task's parent state/<id>.status is a symlink onto the signal-bridge mount
# (bin/fm-spawn.sh's sbx branch), and the TARGET's change is what the rescan
# gates must see - the link's own lstat attributes never change, which froze
# try_resolve's rescan gate for any reply landing after the first scan.
# -L is load-bearing exactly as in fm_pending_reply_turnend_signature below.
# The [ -f ] gate follows symlinks, so a dangling link reports missing.
fm_pending_reply_file_signature() {  # <path>
  local path=$1
  [ -f "$path" ] || { printf 'missing'; return 0; }
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -L -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null || printf 'unreadable'
  else
    LC_ALL=C stat -L -c '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null || printf 'unreadable'
  fi
}

# size:mtime signature of a task's turn-ended signal, following symlinks (-L):
# an sbx task's state/<id>.turn-ended is a symlink onto the signal-bridge
# mount, and the TARGET's change is the signal - -L is load-bearing exactly as
# in bin/fm-watch.sh's stat_sig. The [ -e ] gate (which follows symlinks)
# reports a dangling link as missing, because macOS stat -L on a dangling link
# signs the link itself with rc 0 (bin/fm-watch.sh scan_sbx_beacon).
fm_pending_reply_turnend_signature() {  # <state-dir> <task_id>
  local path="$1/$2.turn-ended"
  [ -e "$path" ] || { printf 'missing'; return 0; }
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -L -f '%z:%Fm' "$path" 2>/dev/null || printf 'unreadable'
  else
    LC_ALL=C stat -L -c '%s:%Y' "$path" 2>/dev/null || printf 'unreadable'
  fi
}

fm_pending_reply_status_set_signature() {  # <status-dir>
  local status_dir=$1 status_file signature
  {
    for status_file in "$status_dir"/*.status; do
      [ -f "$status_file" ] || continue
      signature=$(fm_pending_reply_file_signature "$status_file")
      printf '%s:%s:%s\n' "${#status_file}" "$status_file" "$signature"
    done
  } | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}'
}

# Classify how a resolving line acknowledged the request.
fm_pending_reply_resolve_via_of_line() {  # <line>
  local line=$1
  case "$line" in
    *data/*report*|*report.md*|*document*|*pointer*)
      printf 'document'
      ;;
    *via-helper*|*fm-secondmate-report*)
      printf 'helper'
      ;;
    *)
      printf 'status'
      ;;
  esac
}

# Idempotently resolve an expectation from a correlated parent report.
# Returns 0 when the record is resolved after the call (already or newly).
fm_pending_reply_try_resolve() {  # <state-dir> <corr_id> [status-file-override]
  local state=$1 corr=$2 status_override=${3-}
  local rec phase delivered marker delivery_entry delivery_state status_file signature previous line via now
  local unconfirmed=0
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = resolved ]; then
    return 0
  fi
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
    [ -f "$marker" ] || return 1
    delivery_entry=$(cat "$marker" 2>/dev/null || true)
    delivery_state=${delivery_entry%%=*}
    case "$delivery_state" in attempted|confirmed) ;; *) return 1 ;; esac
    unconfirmed=1
  fi
  status_file=${status_override:-$(fm_pending_reply_get "$rec" parent_status)}
  if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
    signature=$(fm_pending_reply_file_signature "$status_file")
    previous=$(fm_pending_reply_get "$rec" parent_status_scan_signature)
    [ "$signature" != "$previous" ] || return 1
  fi
  line=$(fm_pending_reply_find_resolve_line "$status_file" "$corr")
  if [ -z "$line" ]; then
    if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
      fm_pending_reply_set "$rec" parent_status_scan_signature "$signature" || return 1
    fi
    return 1
  fi
  via=$(fm_pending_reply_resolve_via_of_line "$line")
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" phase resolved || return 1
  if [ -z "$delivered" ]; then
    fm_pending_reply_mark_delivered "$state" "$corr" "$now" || return 1
    rm -f "$marker" 2>/dev/null || true
  fi
  fm_pending_reply_set "$rec" resolved_epoch "$now" || return 1
  fm_pending_reply_set "$rec" resolved_via "$via" || return 1
  return 0
}

# Observe backend busy/idle evidence for the active turn without reading chat.
# busy_state must be one of: busy | idle | unknown.
fm_pending_reply_observe_busy() {  # <state-dir> <corr_id> <busy_state>
  local state=$1 corr=$2 busy_state=$3
  local rec phase delivered now seen completed field_seen field_completed
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sent) ;;
    *) return 0 ;;
  esac
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  if [ "$phase" = awaiting_report ]; then
    field_seen=turn_seen_busy
    field_completed=request_turn_completed_epoch
  else
    field_seen=recovery_turn_seen_busy
    field_completed=recovery_turn_completed_epoch
  fi
  seen=$(fm_pending_reply_get "$rec" "$field_seen")
  completed=$(fm_pending_reply_get "$rec" "$field_completed")
  case "$busy_state" in
    busy)
      if [ "$seen" != 1 ]; then
        fm_pending_reply_set "$rec" "$field_seen" 1 || return 1
      fi
      ;;
    idle)
      if [ -z "$completed" ]; then
        # Prefer a busy->idle transition. Also accept a pure idle after delivery
        # when the first observation already missed the busy window (fast turns).
        if [ "$seen" = 1 ] || [ "$seen" = 0 ]; then
          now=$(fm_pending_reply_now)
          fm_pending_reply_set "$rec" "$field_completed" "$now" || return 1
        fi
      fi
      ;;
    unknown)
      # No independent proof; leave completion unset.
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

fm_pending_reply_fallback_idle_eligible() {  # <record-path>
  local rec=$1 phase start seen grace now age
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report)
      start=$(fm_pending_reply_get "$rec" delivered_epoch)
      seen=$(fm_pending_reply_get "$rec" turn_seen_busy)
      ;;
    recovery_sent)
      start=$(fm_pending_reply_get "$rec" recovery_sent_epoch)
      seen=$(fm_pending_reply_get "$rec" recovery_turn_seen_busy)
      ;;
    *) return 1 ;;
  esac
  [ "$seen" = 1 ] && return 0
  grace=$(fm_pending_reply_get "$rec" grace_secs)
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
  now=$(fm_pending_reply_now)
  age=$((now - start))
  [ "$age" -ge "$grace" ]
}

fm_pending_reply_backend_observation() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected_label=${3-} native tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$native" in
    busy|idle) printf '%s' "$native"; return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 "$expected_label" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'busy'
  else
    printf 'fallback-idle'
  fi
}

fm_pending_reply_busy_state_from_observation() {  # <record-path> <observation>
  local rec=$1 observation=$2
  case "$observation" in
    busy|idle|unknown) printf '%s' "$observation" ;;
    fallback-idle)
      if fm_pending_reply_fallback_idle_eligible "$rec"; then
        printf 'idle'
      else
        printf 'unknown'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

# Turn-boundary observation for an sbx-backed task, from host stats only (the
# header's "sbx completion source"). Compares the current turn-ended signature
# against the anchor snapshotted for the phase's turn (delivery for
# awaiting_report, confirmed recovery send for recovery_sent). Prints idle on a
# positive signature change (a turn completed since the anchor), otherwise
# unknown; never busy, and never a backend CLI call. No anchor, or a missing or
# unreadable turn-ended file, is no independent proof - unknown, so completion
# stays unset. Per-record, not per-task: two records for one task anchor
# different turns, so the tick's per-task observation cache does not apply.
fm_pending_reply_sbx_busy_state() {  # <state-dir> <record-path>
  local state=$1 rec=$2 phase anchor task_id current
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report) anchor=$(fm_pending_reply_get "$rec" request_turnend_signature) ;;
    recovery_sent) anchor=$(fm_pending_reply_get "$rec" recovery_turnend_signature) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  [ -n "$anchor" ] || { printf 'unknown'; return 0; }
  task_id=$(fm_pending_reply_get "$rec" task_id)
  current=$(fm_pending_reply_turnend_signature "$state" "$task_id")
  case "$current" in
    missing|unreadable) printf 'unknown'; return 0 ;;
  esac
  if [ "$current" != "$anchor" ]; then
    printf 'idle'
  else
    printf 'unknown'
  fi
}

# Explicit turn-completion proof (for tests and turn-end backends that surface
# a completion event without a busy/idle pair).
fm_pending_reply_mark_turn_completed() {  # <state-dir> <corr_id> [which: request|recovery]
  local state=$1 corr=$2 which=${3:-request}
  local rec phase field now
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$which" in
    request) field=request_turn_completed_epoch ;;
    recovery) field=recovery_turn_completed_epoch ;;
    *) return 2 ;;
  esac
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" "$field" "$now" || return 1
  # Keep phase consistent with which turn completed.
  if [ "$which" = recovery ] && [ "$phase" = awaiting_report ]; then
    : # recovery completion only meaningful after recovery_sent
  fi
  return 0
}

# Build the one automatic recovery message for a pending record.
fm_pending_reply_recovery_message() {  # <record-path>
  local rec=$1 corr summary token msg
  corr=$(fm_pending_reply_get "$rec" corr_id)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  token=$(fm_pending_reply_corr_token "$corr")
  msg="REPOST REQUIRED: previous marked request had no correlated parent report. Reply on the parent status channel including ${token}. Original request: ${summary}"
  fm_pending_reply_embed_corr "$msg" "$corr" msg
  printf '%s' "$msg"
}

# Can a recovery steer issued from THIS context actually reach the task's
# endpoint? Answers 1 only on a demonstrated environmental no-route, so an
# unknown backend, a missing meta, or a test hook all stay deliverable and the
# send is attempted exactly as before.
# The tick runs on a sandboxed watcher that is denied the host transport
# daemons, and every sbx delivery primitive funnels through an inventory read
# that fails there: the send cannot leave the host regardless of whether the
# guest VM is running or stopped. Asking first is what keeps the single
# recovery attempt from being spent on a send with no route.
# Cost discipline: the sbx probe costs ~10s when denied, so this is called ONCE
# per record, after every eligibility gate has already passed - never per poll.
# Idle supervision keeps its structurally-zero-CLI-calls property.
fm_pending_reply_transport_deliverable() {  # <state-dir> <task-id>
  local state=$1 task_id=$2 meta backend target
  [ -z "${FM_PENDING_REPLY_SEND_HOOK:-}" ] || return 0
  meta="$state/${task_id}.meta"
  [ -f "$meta" ] || return 0
  backend=$(fm_backend_of_meta "$meta") || return 0
  [ -n "$backend" ] || return 0
  target=$(fm_backend_target_of_meta "$meta") || target=
  fm_backend_transport_reachable "$backend" "$target" 2>/dev/null
}

# Deliver the recovery message once. Caller must hold phase awaiting_report with
# turn completed and grace elapsed. Uses FM_PENDING_REPLY_SEND_HOOK when set
# (tests), otherwise invokes fm-send with FM_PENDING_REPLY_EXISTING_CORR so a
# second expectation is not created.
# When this context has no route to the endpoint the send is DEFERRED, not
# attempted: the record keeps its unspent recovery attempt, records why, and
# escalates once so the delivery is owed to a context that can reach the
# transport. Deferral is deliberately one-shot and terminal-by-escalation - the
# missing route is a standing property of the watcher's sandbox, not a
# transient, so retrying would re-spend a ~10s probe every poll forever while
# never succeeding. A late correlated report still resolves the record normally.
fm_pending_reply_send_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed delivered attempted grace now age task_id msg parent_home send_status=0
  local sender_pid sender_identity
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = awaiting_report ] || return 1
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  if [ -n "$attempted" ]; then
    fm_pending_reply_reconcile_recovery "$state" "$corr" || true
    return 1
  fi
  completed=$(fm_pending_reply_get "$rec" request_turn_completed_epoch)
  [ -n "$completed" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 1
  grace=$(fm_pending_reply_get "$rec" grace_secs)
  case "$grace" in ''|*[!0-9]*) grace=$(fm_pending_reply_grace_secs) ;; esac
  now=$(fm_pending_reply_now)
  age=$((now - delivered))
  [ "$age" -ge "$grace" ] || return 1
  task_id=$(fm_pending_reply_get "$rec" task_id)
  parent_home=$(fm_pending_reply_get "$rec" parent_home)
  # Last gate before the attempt is spent: no route means defer, never a
  # claimed-and-failed delivery for a message that was never put on the wire.
  if ! fm_pending_reply_transport_deliverable "$state" "$task_id"; then
    fm_pending_reply_set "$rec" recovery_deferred_epoch "$(fm_pending_reply_now)" || return 1
    fm_pending_reply_set "$rec" recovery_defer_reason "transport-unreachable-from-watcher" || return 1
    fm_pending_reply_set "$rec" phase recovery_deferred || return 1
    return 1
  fi
  msg=$(fm_pending_reply_recovery_message "$rec")
  sender_pid=${BASHPID:-$$}
  sender_identity=$(fm_pending_reply_sender_identity "$sender_pid") || return 1
  fm_pending_reply_set "$rec" recovery_sender_pid "$sender_pid" || return 1
  fm_pending_reply_set "$rec" recovery_sender_identity "$sender_identity" || return 1
  fm_pending_reply_set "$rec" recovery_attempted_epoch "$now" || return 1
  fm_pending_reply_set "$rec" phase recovery_sending || return 1
  if [ -n "${FM_PENDING_REPLY_SEND_HOOK:-}" ]; then
    # Hook receives: task_id message
    # shellcheck disable=SC2086
    if ! eval "$FM_PENDING_REPLY_SEND_HOOK" "$(printf '%q' "$task_id")" "$(printf '%q' "$msg")"; then
      send_status=1
    fi
  else
    if [ -z "$parent_home" ] || [ ! -d "$parent_home" ]; then
      send_status=1
    elif ! env FM_HOME="$parent_home" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
      "$_FM_PENDING_REPLY_LIB_DIR/fm-send.sh" "$task_id" "$msg"; then
      send_status=1
    fi
  fi
  if [ "$send_status" = 0 ]; then
    fm_pending_reply_finish_recovery "$state" "$corr" confirmed
    return $?
  fi
  fm_pending_reply_finish_recovery "$state" "$corr" failed || return 1
  return 1
}

fm_pending_reply_pid_identity() {  # <pid>
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s' "$identity"
}

# Identity string for a recovery sender: the inspectable ps lstart+command
# line when this environment can exec ps, otherwise a self-declared
# "flock-identity pid=<pid> nonce=<nonce>" marker in bin/fm-wake-lib.sh's
# fallback format. A sandboxed watcher that cannot exec ps must still commit
# and send recoveries - identity is crash-reconciliation bookkeeping, never a
# send precondition. A self-declared marker is never re-verifiable, so
# fm_pending_reply_sender_alive treats it as not provably alive and an
# interrupted attempt keeps the fail-safe unknown -> escalate path.
fm_pending_reply_sender_identity() {  # <pid>
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if identity=$(fm_pending_reply_pid_identity "$pid") && [ -n "$identity" ]; then
    printf '%s' "$identity"
    return 0
  fi
  printf 'flock-identity pid=%s nonce=%s' "$pid" "$(fm_pending_reply_new_id)"
}

fm_pending_reply_sender_alive() {  # <record-path>
  local rec=$1 pid expected actual
  pid=$(fm_pending_reply_get "$rec" recovery_sender_pid)
  expected=$(fm_pending_reply_get "$rec" recovery_sender_identity)
  [ -n "$expected" ] || return 1
  # A self-declared ps-less identity can never be re-verified; report the
  # sender as not provably alive so reconciliation escalates (fail-safe).
  case "$expected" in
    'flock-identity '*) return 1 ;;
  esac
  actual=$(fm_pending_reply_pid_identity "$pid") || return 1
  [ "$actual" = "$expected" ]
}

fm_pending_reply_finish_recovery() {  # <state-dir> <corr_id> <confirmed|failed>
  local state=$1 corr=$2 outcome=$3 rec phase now sent task_id
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = recovery_sending ] || return 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome "$outcome" || return 1
  if [ "$outcome" = confirmed ]; then
    sent=$(fm_pending_reply_get "$rec" recovery_sent_epoch)
    if [ -z "$sent" ]; then
      now=$(fm_pending_reply_now)
      fm_pending_reply_set "$rec" recovery_sent_epoch "$now" || return 1
    fi
    fm_pending_reply_set "$rec" recovery_turn_seen_busy 0 || return 1
    fm_pending_reply_set "$rec" recovery_turn_completed_epoch "" || return 1
    # Anchor the recovery-turn turn-ended signature for the sbx completion
    # source: the request turn's own touch happened before this send, so it is
    # baked into the anchor and cannot count as recovery-turn completion.
    task_id=$(fm_pending_reply_get "$rec" task_id)
    fm_pending_reply_set "$rec" recovery_turnend_signature \
      "$(fm_pending_reply_turnend_signature "$state" "$task_id")" || return 1
    fm_pending_reply_set "$rec" phase recovery_sent || return 1
  else
    [ "$outcome" = failed ] || return 1
    fm_pending_reply_set "$rec" phase recovery_failed || return 1
  fi
}

fm_pending_reply_reconcile_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase attempted outcome
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|recovery_sending) ;; *) return 1 ;; esac
  attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch)
  [ -n "$attempted" ] || return 1
  case "$attempted" in *[!0-9]*) return 1 ;; esac
  outcome=$(fm_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$outcome" in
    confirmed) fm_pending_reply_finish_recovery "$state" "$corr" confirmed; return $? ;;
    failed) fm_pending_reply_finish_recovery "$state" "$corr" failed; return $? ;;
    unknown)
      fm_pending_reply_set "$rec" phase recovery_unknown || return 1
      return 0
      ;;
  esac
  fm_pending_reply_sender_alive "$rec" && return 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome unknown || return 1
  fm_pending_reply_set "$rec" phase recovery_unknown || return 1
}

# Escalate once after a missed recovery report or failed delivery outcome.
# Retains the durable unresolved record. Never loops.
fm_pending_reply_maybe_escalate() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed now task_id summary payload parent_status outcome
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = delivery_unknown ]; then
    fm_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(fm_pending_reply_get "$rec" phase)
    [ "$phase" = delivery_unknown ] || return 0
  fi
  case "$phase" in
    recovery_sent)
      completed=$(fm_pending_reply_get "$rec" recovery_turn_completed_epoch)
      [ -n "$completed" ] || return 1
      ;;
    delivery_unknown|recovery_failed|recovery_unknown|recovery_deferred) ;;
    *) return 1 ;;
  esac
  # Resolve wins if a late report arrived between completion and this call.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  task_id=$(fm_pending_reply_get "$rec" task_id)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  # Use pending-reply-id= (not corr=) so this parent-written line cannot be
  # mistaken for a secondmate acknowledgement by fm_pending_reply_line_resolves.
  outcome=$(fm_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$phase" in
    delivery_unknown)
      payload="pending-reply-delivery-unknown: task=${task_id} pending-reply-id=${corr} request=${summary}"
      ;;
    recovery_failed|recovery_unknown)
      payload="pending-reply-recovery-delivery-${outcome}: task=${task_id} pending-reply-id=${corr} request=${summary}"
      ;;
    recovery_deferred)
      # Distinct from a failed delivery on purpose: nothing was sent, so the
      # repost is still owed and must be made from a context that can reach the
      # endpoint. Naming the reason keeps the operator from reading this as a
      # sick secondmate.
      payload="pending-reply-recovery-undeliverable: task=${task_id} pending-reply-id=${corr} reason=$(fm_pending_reply_get "$rec" recovery_defer_reason) request=${summary}"
      ;;
    *) payload="pending-reply-missed: task=${task_id} pending-reply-id=${corr} request=${summary}" ;;
  esac
  [ -n "$parent_status" ] || return 1
  mkdir -p "$(dirname "$parent_status")" 2>/dev/null || return 1
  if ! grep -Fqx "blocked: $payload" "$parent_status" 2>/dev/null; then
    printf 'blocked: %s\n' "$payload" >> "$parent_status" 2>/dev/null || return 1
  fi
  now=$(fm_pending_reply_now)
  fm_pending_reply_set "$rec" escalated_epoch "$now" || return 1
  fm_pending_reply_set "$rec" phase escalated || return 1
  return 0
}

# Detect a correlated report written under the secondmate home (wrong home)
# without treating it as acknowledgement.
fm_pending_reply_detect_wrong_home() {  # <state-dir> <corr_id> <secondmate-home>
  local state=$1 corr=$2 sm_home=$3
  local rec delivered hits sightings snapshot previous status_file line line_no sighting_id phase changed=0
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ -n "$sm_home" ] && [ -d "$sm_home" ] || return 0
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" != resolved ] || return 0
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  snapshot=$(fm_pending_reply_status_set_signature "$sm_home/state")
  previous=$(fm_pending_reply_get "$rec" wrong_home_scan_signature)
  [ "$snapshot" != "$previous" ] || return 0
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  sightings=$(fm_pending_reply_get "$rec" wrong_home_sightings)
  for status_file in "$sm_home"/state/*.status; do
    [ -e "$status_file" ] || continue
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      fm_pending_reply_line_resolves "$line" "$corr" || continue
      sighting_id=$(printf '%s:%s:%s:%s' "${#status_file}" "$status_file" "$line_no" "$line" \
        | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}')
      [ -n "$sighting_id" ] || continue
      case ",$sightings," in
        *",$sighting_id,"*) continue ;;
      esac
      if [ -n "$sightings" ]; then
        sightings="$sightings,$sighting_id"
      else
        sightings=$sighting_id
      fi
      hits=$((hits + 1))
      changed=1
    done < "$status_file"
  done
  if [ "$changed" = 1 ]; then
    fm_pending_reply_set "$rec" wrong_home_sightings "$sightings" || return 1
    fm_pending_reply_set "$rec" wrong_home_hits "$hits" || return 1
  fi
  fm_pending_reply_set "$rec" wrong_home_scan_signature "$snapshot" || return 1
  return 0
}

# One-time visible retirement of pre-upgrade stale sbx records (the header's
# "One-time stale reconciliation"). A record without the
# request_turnend_signature KEY predates the sbx completion source; if it is
# still awaiting_report with a confirmed delivery for a backend=sbx task, no
# code path could ever have completed it, so retire it as reconciled_stale
# rather than letting the new completion source burst-send recovery nags for
# long-dead requests. One summary status line per affected task, deduplicated
# against nothing (an interrupted pass reports its remainder on the next pass).
fm_pending_reply_reconcile_stale() {  # <state-dir>
  local state=$1 dir rec phase delivered task_id meta backend corr now reported
  local i found status_path payload reported_rec
  local -a stale_tasks=() stale_counts=() stale_status_paths=() stale_records=()
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  now=$(fm_pending_reply_now)
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in
      .*) continue ;;
    esac
    phase=$(fm_pending_reply_get "$rec" phase)
    task_id=$(fm_pending_reply_get "$rec" task_id)
    case "$phase" in
      awaiting_report)
        grep -q '^request_turnend_signature=' "$rec" 2>/dev/null && continue
        delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
        [ -n "$delivered" ] || continue
        meta="$state/${task_id}.meta"
        [ -f "$meta" ] || continue
        backend=$(fm_backend_of_meta "$meta")
        [ "$backend" = sbx ] || continue
        corr=$(fm_pending_reply_get "$rec" corr_id)
        [ -n "$corr" ] || corr=$(basename "$rec")
        # A late correlated report still wins over retirement.
        if fm_pending_reply_try_resolve "$state" "$corr"; then
          continue
        fi
        fm_pending_reply_set "$rec" phase reconciled_stale || continue
        fm_pending_reply_set "$rec" reconciled_epoch "$now" || true
        ;;
      reconciled_stale)
        reported=$(fm_pending_reply_get "$rec" reconciled_reported_epoch)
        [ -z "$reported" ] || continue
        [ -n "$task_id" ] || continue
        ;;
      *)
        continue
        ;;
    esac
    found=0
    for ((i = 0; i < ${#stale_tasks[@]}; i++)); do
      [ "${stale_tasks[$i]}" = "$task_id" ] || continue
      stale_counts[i]=$((stale_counts[i] + 1))
      stale_records[i]="${stale_records[$i]}"$'\n'"$rec"
      found=1
      break
    done
    if [ "$found" = 0 ]; then
      stale_tasks+=("$task_id")
      stale_counts+=(1)
      stale_status_paths+=("$(fm_pending_reply_get "$rec" parent_status)")
      stale_records+=("$rec")
    fi
  done
  for ((i = 0; i < ${#stale_tasks[@]}; i++)); do
    status_path=${stale_status_paths[$i]}
    [ -n "$status_path" ] || status_path="$state/${stale_tasks[$i]}.status"
    payload="pending-reply-stale-reconciled: task=${stale_tasks[$i]} retired=${stale_counts[$i]} pre-upgrade marked requests had no correlated report and were retired as stale (not answered) by the pending-reply guard upgrade"
    mkdir -p "$(dirname "$status_path")" 2>/dev/null || continue
    printf 'blocked: %s\n' "$payload" >> "$status_path" 2>/dev/null || continue
    while IFS= read -r reported_rec || [ -n "$reported_rec" ]; do
      [ -n "$reported_rec" ] || continue
      fm_pending_reply_set "$reported_rec" reconciled_reported_epoch "$now" || true
    done <<< "${stale_records[$i]}"
  done
  return 0
}

# One reconciliation tick for a single record: resolve, observe, recover, escalate.
# busy_state is busy|idle|unknown for the secondmate endpoint.
# secondmate_home may be empty when unknown.
fm_pending_reply_tick_one() {  # <state-dir> <corr_id> <busy_state> [secondmate-home]
  local state=$1 corr=$2 busy_state=$3 sm_home=${4-}
  local rec phase delivered
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ "$(fm_pending_reply_get "$rec" phase)" != reconciled_stale ] || return 0
  fm_pending_reply_reconcile_delivery "$state" "$corr" || true
  phase=$(fm_pending_reply_get "$rec" phase)
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    case "$phase" in
      delivery_unknown) fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true ;;
      escalated) fm_pending_reply_try_resolve "$state" "$corr" >/dev/null 2>&1 || true ;;
    esac
    return 0
  fi
  # Correlated parent report always wins and is idempotent.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending)
      if [ -n "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
        fm_pending_reply_reconcile_recovery "$state" "$corr" || true
        phase=$(fm_pending_reply_get "$rec" phase)
      fi
      ;;
  esac
  case "$phase" in
    resolved) return 0 ;;
    escalated)
      # Unresolved durable record retained; never auto-delete.
      if [ -n "$sm_home" ]; then
        fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
      fi
      return 0
      ;;
    recovery_sending) return 0 ;;
    recovery_failed|recovery_unknown|recovery_deferred)
      fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      return 0
      ;;
  esac
  if [ -n "$sm_home" ]; then
    fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
  fi
  fm_pending_reply_observe_busy "$state" "$corr" "$busy_state" || true
  # Re-check resolve after observation in case a concurrent status write landed.
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  if [ "$phase" = awaiting_report ]; then
    fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null || true
  fi
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    recovery_sent|recovery_failed|recovery_unknown|recovery_deferred)
      fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Scan every pending record for this parent state. Safe to call every poll.
# Never scrapes secondmate conversation; uses only parent status, backend busy
# state, and optional secondmate-home wrong-home path checks.
fm_pending_reply_tick() {  # <state-dir>
  local state=$1 dir rec corr task_id phase delivered meta backend target label busy sm_home
  local observation observation_task found i
  local -a observation_tasks=() observation_values=()
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  fm_pending_reply_reconcile_stale "$state" || true
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in
      .*) continue ;;
    esac
    corr=$(fm_pending_reply_get "$rec" corr_id)
    [ -n "$corr" ] || corr=$(basename "$rec")
    task_id=$(fm_pending_reply_get "$rec" task_id)
    phase=$(fm_pending_reply_get "$rec" phase)
    case "$phase" in
      resolved|reconciled_stale) continue ;;
    esac
    fm_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(fm_pending_reply_get "$rec" phase)
    delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
    if [ -z "$delivered" ]; then
      case "$phase" in
        delivery_unknown|escalated)
          fm_pending_reply_tick_one "$state" "$corr" unknown "" || true
          ;;
      esac
      continue
    fi
    case "$phase" in
      awaiting_report|recovery_sending)
        if [ -n "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
          fm_pending_reply_reconcile_recovery "$state" "$corr" || true
          phase=$(fm_pending_reply_get "$rec" phase)
        fi
        ;;
    esac
    meta="$state/${task_id}.meta"
    if [ "$phase" = escalated ]; then
      if fm_pending_reply_try_resolve "$state" "$corr"; then
        continue
      fi
      if [ -f "$meta" ]; then
        sm_home=$(fm_meta_get "$meta" home)
        if [ -n "$sm_home" ]; then
          fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" || true
        fi
      fi
      continue
    fi
    case "$phase" in
      recovery_failed|recovery_unknown|recovery_deferred)
        fm_pending_reply_tick_one "$state" "$corr" unknown "" || true
        continue
        ;;
    esac
    case "$phase" in
      awaiting_report|recovery_sent) ;;
      *) continue ;;
    esac
    backend=tmux
    target=
    busy=unknown
    sm_home=
    if [ -f "$meta" ]; then
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      sm_home=$(fm_meta_get "$meta" home)
      if [ "$backend" = sbx ]; then
        # Host-stat turn-boundary read; per-record anchors make the per-task
        # observation cache inapplicable (fm_pending_reply_sbx_busy_state).
        busy=$(fm_pending_reply_sbx_busy_state "$state" "$rec")
      elif [ -n "$target" ]; then
        label="fm-$task_id"
        observation=
        found=0
        for ((i = 0; i < ${#observation_tasks[@]}; i++)); do
          observation_task=${observation_tasks[$i]}
          [ "$observation_task" = "$task_id" ] || continue
          observation=${observation_values[$i]}
          found=1
          break
        done
        if [ "$found" = 0 ]; then
          observation=$(fm_pending_reply_backend_observation "$backend" "$target" "$label")
          observation_tasks+=("$task_id")
          observation_values+=("$observation")
        fi
        busy=$(fm_pending_reply_busy_state_from_observation "$rec" "$observation")
      fi
    fi
    fm_pending_reply_tick_one "$state" "$corr" "$busy" "$sm_home" || true
  done
  return 0
}

# True when any open (non-terminal) pending reply exists for a task.
fm_pending_reply_task_has_open() {  # <state-dir> <task_id>
  local state=$1 task_id=$2 dir rec phase tid
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 1
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    tid=$(fm_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task_id" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    case "$phase" in
      resolved|reconciled_stale) continue ;;
    esac
    return 0
  done
  return 1
}
