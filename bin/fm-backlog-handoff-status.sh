#!/usr/bin/env bash
# Read-only ground-truth check for an sbx-backed bin/fm-backlog-handoff.sh
# delivery (GitHub issue #11): report whether a batch sitting on the signal
# bridge has actually been merged into the secondmate's own backlog, or is
# still waiting.
#
# A batch's LOCATION on the signal bridge is its own status, set only by the
# guest's own bin/fm-backlog-ingest.sh (a batch moves from pending/ to
# ingested/ only after that guest's own tasks-axi mv into its own backlog.md
# succeeds) - this never depends on the secondmate's own status replies, so it
# stays correct even if a reply is lost, malformed, or never sent.
#
# Usage: fm-backlog-handoff-status.sh <secondmate-id> [batch-id]
#   With a batch-id: reports just that batch (pending / ingested / unknown)
#   and the keys it carries.
#   Without: lists every pending and ingested batch for the secondmate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backlog-key-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-key-lib.sh"
# shellcheck source=bin/fm-backlog-handoff-sbx-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-handoff-sbx-lib.sh"

[ $# -ge 1 ] || { echo "usage: fm-backlog-handoff-status.sh <secondmate-id> [batch-id]" >&2; exit 1; }
ID=$1
BATCH_ID=${2:-}

SIGNALS_DIR=$(fm_backlog_handoff_sbx_signals_dir "$STATE" "$ID" 2>/dev/null || true)
if [ -z "$SIGNALS_DIR" ]; then
  echo "error: $ID is not a recorded sbx-backed secondmate (no backend=sbx / sbx_signals_dir= in $STATE/$ID.meta); this status tool only applies to signal-bridge batches" >&2
  exit 1
fi

PENDING_DIR=$(fm_backlog_handoff_pending_dir "$SIGNALS_DIR")
INGESTED_DIR=$(fm_backlog_handoff_ingested_dir "$SIGNALS_DIR")
ROLLED_BACK_DIR=$(fm_backlog_handoff_rolled_back_dir "$SIGNALS_DIR")

report_batch() {  # <label> <file>
  local label=$1 file=$2 keys
  keys=$(fm_backlog_key_list "$file" | tr '\n' ' ')
  keys=${keys% }
  printf '%s\t%s\t%s\n' "$label" "$(basename "$file")" "${keys:-<no keys found>}"
}

if [ -n "$BATCH_ID" ]; then
  CASE_BATCH_ID=${BATCH_ID%.md}
  case "$CASE_BATCH_ID" in
    ""|*/*|*..*|*[!A-Za-z0-9_.-]*)
      echo "error: invalid batch id $BATCH_ID; expected a basename like <batch-id> or <batch-id>.md containing only A-Z, a-z, 0-9, '_', '.', and '-'; nothing to report" >&2
      exit 1
      ;;
  esac
  case "$BATCH_ID" in
    *.md) ;;
    *) BATCH_ID="$BATCH_ID.md" ;;
  esac
  if [ -f "$PENDING_DIR/$BATCH_ID" ]; then
    echo "pending: $ID has not yet ingested this batch"
    report_batch pending "$PENDING_DIR/$BATCH_ID"
    exit 0
  fi
  if [ -f "$INGESTED_DIR/$BATCH_ID" ]; then
    echo "ingested: $ID's own backlog-ingest already merged this batch"
    report_batch ingested "$INGESTED_DIR/$BATCH_ID"
    exit 0
  fi
  if [ -f "$ROLLED_BACK_DIR/$BATCH_ID" ]; then
    echo "rolled-back: a main-home operator reclaimed this batch into the main backlog"
    report_batch rolled-back "$ROLLED_BACK_DIR/$BATCH_ID"
    exit 0
  fi
  echo "unknown: no batch named $BATCH_ID under $SIGNALS_DIR/backlog-handoff (pending/, ingested/, or rolled-back/)" >&2
  exit 1
fi

PENDING_COUNT=0
if [ -d "$PENDING_DIR" ]; then
  for f in "$PENDING_DIR"/*.md; do
    [ -f "$f" ] || continue
    report_batch pending "$f"
    PENDING_COUNT=$((PENDING_COUNT + 1))
  done
fi
INGESTED_COUNT=0
if [ -d "$INGESTED_DIR" ]; then
  for f in "$INGESTED_DIR"/*.md; do
    [ -f "$f" ] || continue
    report_batch ingested "$f"
    INGESTED_COUNT=$((INGESTED_COUNT + 1))
  done
fi
ROLLED_BACK_COUNT=0
if [ -d "$ROLLED_BACK_DIR" ]; then
  for f in "$ROLLED_BACK_DIR"/*.md; do
    [ -f "$f" ] || continue
    report_batch rolled-back "$f"
    ROLLED_BACK_COUNT=$((ROLLED_BACK_COUNT + 1))
  done
fi

echo "---"
echo "$ID: $PENDING_COUNT pending batch(es), $INGESTED_COUNT ingested batch(es), $ROLLED_BACK_COUNT rolled-back batch(es)"
