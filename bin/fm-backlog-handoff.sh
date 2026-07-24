#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format. Delegating the move is the durability end-state: it removes the awk
# that used to re-implement block extraction and insertion here, so the format
# has exactly one parser and cannot drift out of sync (the body-orphaning class
# of bug fixed in PR #401 was exactly that drift).
#
# What this script still owns (never delegated):
#   - resolving the secondmate home from data/secondmates.md;
#   - proving the destination is a genuine seeded secondmate home
#     (.fm-secondmate-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the firstmate repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the secondmate backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# byte-exact (header, body lines, blank separators, and indented pseudo-headings
# such as `  ## Intent`), preserving destination section placement, and moving a
# whole connected set (a blocker and its dependents) atomically with blocked-by
# links preserved. It refuses a move that would strand a dependency across the
# two files; that error is surfaced verbatim and nothing is moved.
#
# Item bodies must use at least two leading spaces. The helper refuses a selected
# item with a single-space or tab-indented continuation rather than risk leaving
# it orphaned, because tasks-axi treats only two-or-more-space lines as body.
# The move needs compatible `tasks-axi` on PATH, including atomic multi-ID `mv`
# (introduced in 0.2.2). Bootstrap requires it fleet-wide, so this works
# everywhere; the `config/backlog-backend=manual` knob only governs firstmate's
# own hand-editing of its own backlog, not this validated helper. Idempotent:
# re-running converges. Atomic: on any move failure nothing moves.
#
# An sbx-backed secondmate home is a clone-mode guest whose OWN backlog.md the
# guest never re-reads from this host's writes (GitHub issue #11), so a
# destination detected as backend=sbx (docs/sbx-backend.md) never gets a direct
# write into its host clone. Instead, the move lands in a durable batch
# artifact on the signal bridge (the one proven-live guest<->host surface),
# and the secondmate is nudged to merge it with `bin/fm-backlog-ingest.sh`.
# That delivery is inherently asynchronous, so success here means "durably
# queued and nudged", never "in the secondmate's own backlog" - verify actual
# ingestion with `bin/fm-backlog-handoff-status.sh`, and recover a
# never-ingested batch with `bin/fm-backlog-handoff-rollback.sh`. Non-sbx
# destinations are entirely unaffected by this path.
# See AGENTS.md project management and task lifecycle.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-key-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-key-lib.sh"
# shellcheck source=bin/fm-backlog-handoff-sbx-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-handoff-sbx-lib.sh"

[ $# -ge 2 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>..." >&2; exit 1; }
ID=$1
shift

secondmate_home() {
  local id=$1 line
  [ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; return 1; }
  line=$(grep -E "^- $id( |$)" "$REG" | tail -1 || true)
  [ -n "$line" ] || { echo "error: secondmate $id is not registered in $REG" >&2; return 1; }
  # Match the (home: ...) field itself; do not require zero parentheses before it.
  # Summary/scope prose often contains parentheticals (e.g. "(id is legacy)"), and
  # ^[^(]* would leave those entries looking like "has no home". Greedy prefix so the
  # last (home: ...) on the line wins. Empty when the field is absent.
  printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' | sed 's/[[:space:]]*$//'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

# sbx-only idempotency: a prior sbx handoff run leaves the moved item in a
# signal-bridge batch file (pending/ until the guest ingests it, ingested/
# after), never in the host clone's backlog.md that the normal ALREADY check
# above reads. Re-running this helper for the same key must see it as already
# queued there rather than falling through to "no backlog item matched these
# keys" - the item is not missing, it is simply not visible from the host
# clone by design (GitHub issue #11).
backlog_key_sbx_queued() {  # <signals-dir> <key>
  local signals_dir=$1 key=$2 dir batch
  for dir in "$(fm_backlog_handoff_pending_dir "$signals_dir")" "$(fm_backlog_handoff_ingested_dir "$signals_dir")"; do
    [ -d "$dir" ] || continue
    for batch in "$dir"/*.md; do
      [ -f "$batch" ] || continue
      fm_backlog_key_section "$batch" "$key" >/dev/null && return 0
    done
  done
  return 1
}

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
SUB_HOME=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_BACKLOG="$SUB_HOME/data/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

# Detect an sbx-backed destination from the MAIN home's own recorded task
# metadata (never by probing the secondmate's clone or its source mount -
# both can be stale or absent). Empty when this destination is not sbx-backed
# (no meta, a different backend, or a malformed sbx record): the rest of this
# script then runs byte-for-byte as it did before this backend existed.
SBX_SIGNALS_DIR=$(fm_backlog_handoff_sbx_signals_dir "$STATE" "$ID" 2>/dev/null || true)

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
for key in "$@"; do
  if fm_backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif [ -n "$SBX_SIGNALS_DIR" ] && backlog_key_sbx_queued "$SBX_SIGNALS_DIR" "$key"; then
    ALREADY+=("$key")
  elif section=$(fm_backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
      "## Queued") TO_MOVE+=("$key") ;;
      "## In flight") IN_FLIGHT+=("$key") ;;
      "## Done") DONE+=("$key") ;;
      *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  if [ -n "$SBX_SIGNALS_DIR" ]; then
    echo "nothing to move: ${ALREADY[*]:-no keys} already queued or ingested via the signal bridge for $ID"
  else
    echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  fi
  exit 0
fi

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if ! fm_tasks_axi_compatible; then
  echo "error: tasks-axi with atomic multi-ID mv support (0.2.2+) is required to move backlog items" >&2
  exit 1
fi

if [ -n "$SBX_SIGNALS_DIR" ]; then
  # sbx destination: never write into the secondmate's host clone - it is a
  # point-in-time snapshot the guest never re-reads (GitHub issue #11).
  # Deliver through the signal bridge instead, the only surface proven live
  # in both directions regardless of VM lifecycle (docs/sbx-backend.md).
  [ -d "$SBX_SIGNALS_DIR" ] || {
    echo "error: recorded signal-bridge dir for $ID does not exist: $SBX_SIGNALS_DIR; nothing was moved." >&2
    exit 1
  }
  PENDING_DIR=$(fm_backlog_handoff_pending_dir "$SBX_SIGNALS_DIR")
  mkdir -p "$PENDING_DIR" || {
    echo "error: cannot create $PENDING_DIR; nothing was moved." >&2
    exit 1
  }
  BATCH_ID="$(printf '%s' "${TO_MOVE[0]}" | tr -c 'A-Za-z0-9_.-' '_')-$(date +%s)-$$"
  BATCH_FILE="$PENDING_DIR/$BATCH_ID.md"
  if [ -e "$BATCH_FILE" ]; then
    # Extremely unlikely collision (same key, same second, same pid reused);
    # regenerate once rather than risk clobbering an in-flight batch.
    BATCH_ID="${BATCH_ID}-$RANDOM"
    BATCH_FILE="$PENDING_DIR/$BATCH_ID.md"
  fi
  [ ! -e "$BATCH_FILE" ] || {
    echo "error: batch artifact $BATCH_FILE already exists; nothing was moved." >&2
    exit 1
  }
  # Same three-section scaffold as the non-sbx path, for the same reason: a
  # fresh file left to tasks-axi's own default gets its `# Backlog` title
  # instead of firstmate's convention, and fm-backlog-ingest.sh's own
  # tasks-axi mv (batch file -> the guest's own backlog.md) expects it.
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$BATCH_FILE"

  if ! MV_OUT=$(tasks-axi mv "${TO_MOVE[@]}" --file "$MAIN_BACKLOG" --to "$BATCH_FILE" 2>&1); then
    rm -f "$BATCH_FILE"
    if [ -n "$MV_OUT" ]; then
      printf '%s\n' "$MV_OUT" >&2
    fi
    echo "error: tasks-axi mv failed; nothing was moved." >&2
    exit 1
  fi

  # The moved item(s) are now durably safe (on the main backlog's side, this
  # is unconditionally atomic and already committed) regardless of what
  # happens next. Nudging the secondmate can still fail - fm-send delivers
  # through the sbx adapter, which may need to resurrect a stopped VM - but a
  # nudge failure never re-touches the batch: the data is not lost, only not
  # yet actioned.
  NUDGE_MSG="BACKLOG_HANDOFF: run \`bin/fm-backlog-ingest.sh\` to merge routed item(s) ${TO_MOVE[*]} (batch $BATCH_ID) into your own backlog, then report as your charter requires."
  NUDGE_OK=1
  NUDGE_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$ID" "$NUDGE_MSG" 2>&1) || NUDGE_OK=0

  # Never claim the item reached $ID's own backlog: an sbx guest only ever
  # observes this host's writes through the signal bridge, and delivery of
  # the nudge is not the same as the secondmate having ingested the batch
  # (a live pane accepting a steer proves nothing about what its agent does
  # with it next).
  echo "queued ${#TO_MOVE[@]} item(s) for $ID via the signal bridge (sbx backend): ${TO_MOVE[*]}"
  echo "  batch: $BATCH_FILE"
  if [ "${#ALREADY[@]}" -gt 0 ]; then
    echo "  already queued or ingested (skipped): ${ALREADY[*]}"
  fi
  echo "  NOT yet confirmed in $ID's own backlog - delivery to an sbx guest is asynchronous by design."
  echo "  verify actual ingestion with: bin/fm-backlog-handoff-status.sh $ID $BATCH_ID"
  if [ "$NUDGE_OK" -eq 1 ]; then
    echo "  nudged $ID to ingest it: $NUDGE_OUT"
    exit 0
  fi
  echo "error: the item is safely queued (no data lost), but nudging $ID failed:" >&2
  printf '%s\n' "$NUDGE_OUT" >&2
  echo "  retry the nudge later with: bin/fm-send.sh $ID '$NUDGE_MSG'" >&2
  echo "  or reclaim it into the main backlog with: bin/fm-backlog-handoff-rollback.sh $ID $BATCH_ID" >&2
  exit 1
fi

# Seed the destination with firstmate's standard three-section scaffold when it
# does not exist yet, so the moved item lands under the right section. (Left to
# create the file itself, tasks-axi mv writes its own `# Backlog` title format,
# which is not firstmate's home-backlog convention.)
mkdir -p "$SUB_HOME/data"
SUB_CREATED=0
if [ ! -f "$SUB_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB_BACKLOG"
  SUB_CREATED=1
fi

# Delegate the move to tasks-axi. Passing the whole in-scope set to one call is a
# single atomic transaction, so a connected set (blocker + dependents) moves
# together and, on any failure, neither backlog's content changes - the only
# cleanup is a scaffold we just created. tasks-axi writes both its success and
# error output to stdout, so capture it and surface it only on failure.
if ! MV_OUT=$(tasks-axi mv "${TO_MOVE[@]}" --file "$MAIN_BACKLOG" --to "$SUB_BACKLOG" 2>&1); then
  if [ "$SUB_CREATED" -eq 1 ]; then
    rm -f "$SUB_BACKLOG"
  fi
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  echo "error: tasks-axi mv failed; nothing was moved." >&2
  exit 1
fi

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
