#!/usr/bin/env bash
# Rename this home's state/ marker files from the superseded `tr '.' '_'` key
# fold onto the reversible encoding bin/fm-state-key-lib.sh owns.
#
# The markers are live beacon state - the sbx beat-beacon family and the signal
# scan's .seen- signatures - so this sweep never deletes and never guesses:
#
#   - A legacy key is ambiguous BY CONSTRUCTION (the fold mapped both `a.b` and
#     `a_b` to `a_b`), so a legacy name is resolved only against the task ids
#     and signal filenames this home can actually enumerate from state/. A name
#     that resolves to more than one live owner is REPORTED and left untouched;
#     the sweep never picks one.
#   - A name already in the current scheme - some live owner encodes to it - is
#     left alone unless a different live owner also maps to it under the legacy
#     scheme. Such a cross-scheme overlap is moved to a dot-suffixed inert name,
#     reported, and attributed to neither owner. A task id that is a bare slug
#     encodes to itself, so most homes have nothing to rename at all.
#   - A name with no live owner is dead state from a torn-down task. It is left
#     in place silently rather than deleted; nothing reads it.
#   - A rename that would land on an existing name is reported, not forced.
#
# Errors run one way on purpose. Anything left under a legacy-only name is
# invisible to the new-scheme consumer, so it behaves as absent: the delivery
# breadcrumb goes quiet until the next steer republishes it, a signature marker
# costs one duplicate wake, and the counters rebuild. Each affected mechanism
# recovers on its next natural event. Attributing a marker to the WRONG task
# does not: it can raise a named alarm against a healthy secondmate and latch
# the alarmed marker that suppresses the real one. Under-reporting beats
# misattribution here, so a cross-scheme name must be moved aside or the sweep
# fails.
#
# The transient .sbx-delivery-pending- candidates are deliberately out of scope.
# They are content-free, live only inside one in-flight send, and nothing reads
# them by name except the promotion that holds the exact path and teardown's
# glob. A pre-migration leftover is inert debris, which is a better outcome than
# a sweep that could delete a candidate a running send is about to promote.
#
# Runs at one well-defined safe point: invoked directly by
# bin/fm-session-start.sh while the session holds this home's session lock and
# before supervision is armed. A watcher still running the pre-update code can
# re-create a legacy name after the sweep; that is benign and the next session
# start migrates it again.
#
# Usage: fm-state-key-migrate.sh [--state <dir>]
#   Prints one STATE_KEY_MIGRATION: line per name it refused to resolve, one
#   BOOTSTRAP_INFO: line when it renamed anything, and nothing at all when the
#   home is already current. Exit 1 when state/ is unusable or a cross-scheme
#   name cannot be made inert; exit 2 for invalid arguments.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-state-key-lib.sh
. "$SCRIPT_DIR/fm-state-key-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --state)
      [ "$#" -ge 2 ] || { echo "error: --state needs a directory" >&2; exit 2; }
      STATE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
  exit 0
fi
if [ ! -d "$STATE" ]; then
  echo "error: state path is not a directory: $STATE" >&2
  exit 1
fi

TAB=$'\t'
RENAMED=0
UNSAFE=0

report() {  # <detail>
  echo "STATE_KEY_MIGRATION: $1"
}

move_no_clobber() {  # <source> <destination>
  local source=$1 destination=$2
  if ln -P -- "$source" "$destination" 2>/dev/null; then
    rm -f -- "$source" || return 2
    return 0
  fi
  [ -e "$destination" ] || [ -L "$destination" ] || return 2
  return 1
}

move_aside() {  # <path>
  local source=$1 destination="${1}.state-key-unresolved" suffix=0 rc
  while :; do
    rc=0
    move_no_clobber "$source" "$destination" || rc=$?
    case $rc in
      0)
        printf '%s\n' "${destination##*/}"
        return 0
        ;;
      1)
        suffix=$(( suffix + 1 ))
        destination="${source}.state-key-unresolved.$suffix"
        ;;
      *)
        return 1
        ;;
    esac
  done
}

# --- the namespaces this home can enumerate ---------------------------------
#
# Only a name with live evidence in state/ can resolve a legacy marker. The id
# namespace keys the sbx beacon families; the signal namespace keys .seen-,
# whose marker encodes a whole "<id>.status" / "<id>.turn-ended" basename.

collect_ids() {
  local f base
  for f in "$STATE"/*.meta; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    printf '%s\n' "${base%.meta}"
  done
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    printf '%s\n' "${base%.status}"
  done
  for f in "$STATE"/*.turn-ended; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    printf '%s\n' "${base%.turn-ended}"
  done
}

collect_signals() {
  local f
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
}

# --- key tables --------------------------------------------------------------
#
# Built once per namespace, so resolving a marker is plain string matching
# rather than one encode per marker per name. Deduplicated, because a duplicate
# name would read as two owners and fake an ambiguity.

build_table() {  # <names> <current|legacy>
  local names=$1 mode=$2 name key
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$mode" = current ]; then
      key=$(fm_state_key_encode "$name")
    else
      key=$(fm_state_key_legacy "$name")
    fi
    printf '%s%s%s\n' "$key" "$TAB" "$name"
  done <<EOF
$names
EOF
}

table_owners() {  # <table> <key>: every name whose key is <key>, one per line
  local table=$1 key=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%"$TAB"*}" = "$key" ] || continue
    printf '%s\n' "${line#*"$TAB"}"
  done <<EOF
$table
EOF
}

# --- the sweep ---------------------------------------------------------------

migrate_family() {  # <prefix> <current-table> <legacy-table>
  local prefix=$1 current=$2 legacy=$3
  local f base key current_owners current_owner owners owner count joined new moved rc

  for f in "$STATE/$prefix"*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    key=${base#"$prefix"}
    [ -n "$key" ] || continue

    current_owners=$(table_owners "$current" "$key")
    owners=$(table_owners "$legacy" "$key")
    if [ -n "$current_owners" ]; then
      current_owner=${current_owners%%$'\n'*}
      count=0
      joined=
      while IFS= read -r owner; do
        [ -n "$owner" ] || continue
        [ "$owner" = "$current_owner" ] && continue
        count=$(( count + 1 ))
        joined=${joined:+$joined, }$owner
      done <<EOF
$owners
EOF
      [ "$count" -gt 0 ] || continue

      if moved=$(move_aside "$f"); then
        report "state/$base could be current for $current_owner or legacy for $joined; moved aside as state/$moved"
        continue
      fi
      report "state/$base could be current for $current_owner or legacy for $joined and could not be moved aside"
      UNSAFE=1
      continue
    fi

    # No live owner: dead state from a torn-down task, left alone.
    [ -n "$owners" ] || continue

    count=0
    joined=
    while IFS= read -r owner; do
      [ -n "$owner" ] || continue
      count=$(( count + 1 ))
      joined=${joined:+$joined, }$owner
    done <<EOF
$owners
EOF

    if [ "$count" -gt 1 ]; then
      report "state/$base could name more than one live task ($joined); left untouched until those names no longer collide"
      continue
    fi

    owner=${owners%%$'\n'*}
    new="$prefix$(fm_state_key_encode "$owner")"
    if [ -e "$STATE/$new" ] || [ -L "$STATE/$new" ]; then
      report "state/$base belongs to $owner but state/$new already exists; left untouched"
      continue
    fi
    rc=0
    move_no_clobber "$f" "$STATE/$new" || rc=$?
    case $rc in
      0)
        RENAMED=$(( RENAMED + 1 ))
        ;;
      1)
        report "state/$base belongs to $owner but state/$new already exists; left untouched"
        ;;
      *)
        report "state/$base could not be renamed to state/$new; left untouched"
        ;;
    esac
  done
}

IDS=$(collect_ids | LC_ALL=C sort -u)
SIGNALS=$(collect_signals | LC_ALL=C sort -u)

CURRENT_IDS=$(build_table "$IDS" current)
LEGACY_IDS=$(build_table "$IDS" legacy)
CURRENT_SIGNALS=$(build_table "$SIGNALS" current)
LEGACY_SIGNALS=$(build_table "$SIGNALS" legacy)

while IFS= read -r PREFIX; do
  [ -n "$PREFIX" ] || continue
  migrate_family "$PREFIX" "$CURRENT_IDS" "$LEGACY_IDS"
done < <(fm_state_sbx_marker_prefixes)

migrate_family "$FM_STATE_SEEN_PREFIX" "$CURRENT_SIGNALS" "$LEGACY_SIGNALS"

if [ "$RENAMED" -gt 0 ]; then
  echo "BOOTSTRAP_INFO: migrated $RENAMED state marker name(s) to the reversible key encoding"
fi
[ "$UNSAFE" -eq 0 ] || exit 1
exit 0
