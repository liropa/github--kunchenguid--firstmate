#!/usr/bin/env bash
# fm-marker-lib.sh - the from-firstmate marker.
#
# When the MAIN firstmate relays a request or notice to one of its SECONDMATES,
# bin/fm-send.sh prepends this marker to the message text. A secondmate is itself
# a firstmate running in its own home, so without a marker it treats every
# incoming fm-send/tmux line as if its captain typed it and answers
# CONVERSATIONALLY in its own chat. But the main firstmate never reads a
# secondmate's chat: the only main<-secondmate wakeup channel is the status file
# (charter escalation), optionally pointing to a doc for detail. A detailed
# chat-only reply therefore strands, unseen when a reply is required.
#
# The marker lets the secondmate tell its supervisor's traffic apart from a
# message the captain typed directly into its pane:
#
#   - marked   -> from-firstmate traffic. A corr=<id> token means a request
#                 whose answer must use the STATUS/ESCALATION path (a status
#                 line for a terse result, or a doc plus a status pointer - the
#                 scout-report pattern - for a detailed one) so it surfaces to
#                 the main firstmate via the watcher signal. No corr token means
#                 a fire-and-forget notice.
#   - unmarked -> the captain typing directly. Stay conversational, exactly as
#                 before: authoritative captain intervention.
#
# This contract lives in the generated secondmate charter (bin/fm-brief.sh) so it
# travels with the live secondmate, and is summarized in AGENTS.md.
#
# Distinct from the afk daemon marker, on purpose.
# Both terminal-safe markers use U+2063 INVISIBLE SEPARATOR because it has no
# normal keyboard keystroke but travels as UTF-8 text rather than a terminal
# control byte. The away-mode marker is a BARE leading U+2063; this marker begins
# with its human-readable label and places U+2063 after it, so the two cannot
# conflate. The original ASCII 0x1f separator did not survive terminal input
# faithfully: on Herdr 0.7.3 feeding it to a real Pi composer removed marker
# content, so Pi received an unmarked message. docs/herdr-backend.md records both
# incidents and their live proof.
#
# Sourced by bin/fm-send.sh, bin/fm-brief.sh, and the tests. No side effects on
# source. set -u / set -e safe.

# The label field: human-readable, greppable, and distinctive enough that the
# captain would not type it by hand. This is the part the secondmate's LLM reads.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'

# The full marker fm-send prepends to from-firstmate traffic: the label, then
# U+2063 INVISIBLE SEPARATOR (UTF-8 e2 81 a3). The message text follows it.
FM_FROMFIRST_SEPARATOR=$'\xE2\x81\xA3'
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

# fm_message_from_firstmate: 0 (true) if <message> carries the from-firstmate
# marker - it begins with the label immediately followed by U+2063 - and 1
# otherwise. U+2063 has no normal keyboard keystroke, so captain-typed input,
# even when it starts with the visible label text alone, is never matched.
fm_message_from_firstmate() {  # <message>
  case "$1" in
    "$FM_FROMFIRST_MARK"*) return 0 ;;
  esac
  return 1
}

# fm_marker_strip_separators: assign <text> with every marker separator byte
# removed, so the result is the text as a terminal actually RENDERS it.
# U+2063 travels through a pane's input faithfully but is never drawn: a TUI
# composer drops it, so a capture of a marked message does not contain it.
# Measured 2026-09-10 on claude 2.1.267: a composer typed with
# "[fm-from-firstmate]<U+2063>corr=6edc6c2493fafee8 HOLD: ..." captures back as
# "[fm-from-firstmate]corr=6edc6c2493fafee8 HOLD: ..." (docs/sbx-backend.md
# records the exact command and output).
# Any check that matches sent text against captured pane content must pass BOTH
# sides through this first. Matching raw marked text against a pane can never
# succeed, and a backend that reads that failure as "the text never arrived"
# will act on a delivered message as if it were lost.
fm_marker_strip_separators() {  # <text> <result-var>
  local text=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2
  printf -v "$result_var" '%s' "${text//"$FM_FROMFIRST_SEPARATOR"/}"
}

# fm_message_mark_from_firstmate: assign <message> with exactly one leading
# from-firstmate marker. This is the single owner of marker transformation, so
# callers cannot drift on separator bytes or double-prefix an already-marked
# message.
fm_message_mark_from_firstmate() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if fm_message_from_firstmate "$1"; then
    transformed=$message
  else
    transformed="${FM_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}
