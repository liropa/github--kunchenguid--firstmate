#!/usr/bin/env bash
# fm-tasks-finished.sh - has every live task in a firstmate home finished?
#
# Prints one TAB-separated "<task-id>\t<verb>" line per registered task and exits
# 0 when at least one task is registered and EVERY one of them has finished;
# prints nothing and exits 1 otherwise. A home with no registered task, or one
# that cannot be read, is "cannot assert finished" (exit 1), never a claim.
#
# Usage:
#   fm-tasks-finished.sh [<home>]      # default: $FM_HOME, else this code root
#
# A task counts as finished when it is REGISTERED (state/<id>.meta exists, so the
# task is live rather than torn down) and its newest recorded event is done or
# failed. bin/fm-classify-lib.sh's status_task_finished owns that test - the same
# rule status_open_decisions_live reads, stated once. This script only walks the
# home and reports; it never parses a status line itself.
#
# EVERY, not ANY, is the deliberate reading: the question this answers is "does
# the durable record account for a quiet home", and one still-running task means
# it does not.
#
# WHY THIS IS A SCRIPT rather than an inline test, and why it is a sibling of
# bin/fm-parked-decision.sh rather than a mode of it. bin/backends/sbx.sh's guest
# keep-alive loop calls it from INSIDE the microVM to classify WHY a guest's
# screen was static when the machine was allowed to stop
# (docs/sbx-backend.md "Static-screen classification"). That loop is POSIX sh and
# the verb vocabulary is bash, and a second sh reimplementation of the vocabulary
# is exactly the drift this repo's one-owner rule forbids - so the loop execs the
# guest home's own copy of this file instead. Every secondmate home is a firstmate
# clone with bin/ (bin/fm-home-seed.sh refuses one without it), so the copy is
# always the one version-matched to the status files it is reading. It answers a
# different question from the parked-decision predicate - "is this worker still
# waiting" versus "is this worker done" - and a home can be neither, which is the
# gap the classification reports honestly rather than guessing at. The
# parked-decision predicate may safely default a missing kind to ship because
# that errs toward not pinning. Here the same default would assert that an
# unknown task finished. That false durable record becomes cited history and can
# drive later action, so its cost outweighs the small risk of withholding a
# finished reading from a legacy record.
#
# Pure read: no file is created, moved, or touched, which is what lets the
# keep-alive call it without becoming the guest activity it is trying to observe.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac

HOME_DIR="${1:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="$HOME_DIR/state"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

report=''
found=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || kind=''
  status_file="$STATE/$id.status"
  # One unfinished task is enough: the home is not accounted for.
  status_task_finished "$status_file" "$kind" || exit 1
  report="$report$id"$'\t'"$(status_line_verb "$(last_status_line "$status_file")")"$'\n'
  found=1
done

[ "$found" = 1 ] || exit 1
printf '%s' "$report"
