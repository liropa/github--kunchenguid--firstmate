#!/usr/bin/env bash
# fm-parked-decision.sh - is any live task in a firstmate home sitting on an
# unanswered decision?
#
# Prints one TAB-separated "<task-id>\t<key>\t<verb>\t<summary>" line per parked
# decision and exits 0; prints nothing and exits 1 when nothing is parked. A
# home that cannot be read is "nothing parked" (exit 1), never a pin.
#
# Usage:
#   fm-parked-decision.sh [<home>]     # default: $FM_HOME, else this code root
#
# A task counts as parked when it is REGISTERED (state/<id>.meta exists, so the
# task is live rather than torn down) and its status stream still carries an open
# keyed decision. bin/fm-classify-lib.sh owns both halves of that test:
# status_open_decisions folds the append-only event log, and
# status_open_decisions_live adds the rule that a finished task is not waiting
# on anything. This script only walks the home and reports; it never parses a
# status line itself, so there is exactly one statement of the fold contract.
#
# WHY THIS IS A SCRIPT rather than a keep-alive detail. bin/backends/sbx.sh's
# guest keep-alive loop calls it from INSIDE the microVM to decide whether an
# in-guest worker parked on an escalated decision should keep the VM awake
# (docs/sbx-backend.md "Parked-decision arm"). That loop is POSIX sh and the
# fold is bash, and a second sh reimplementation of the fold is exactly the
# drift this repo's one-owner rule forbids - so the loop execs the guest home's
# own copy of this file instead. Every secondmate home is a firstmate clone with
# bin/ (bin/fm-home-seed.sh refuses one without it), so the copy is always the
# one version-matched to the status files it is reading.
#
# Pure read: no file is created, moved, or touched, which is what lets the
# keep-alive call it on a poll path without becoming the guest activity it is
# trying to observe.
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

found=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  status_file="$STATE/$id.status"
  [ -f "$status_file" ] || continue
  kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || kind=''
  [ -n "$kind" ] || kind=ship
  open=$(status_open_decisions_live "$status_file" "$kind") || continue
  [ -n "$open" ] || continue
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\t%s\n' "$id" "$line"
    found=1
  done <<EOF
$open
EOF
done

[ "$found" = 1 ]
