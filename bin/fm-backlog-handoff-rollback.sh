#!/usr/bin/env bash
# Recovery path for a bin/fm-backlog-handoff.sh sbx delivery that will never
# be ingested (GitHub issue #11) - e.g. the secondmate's sandbox is confirmed
# gone and will not be re-provisioned with the same id. Reclaims every item
# still sitting in a named pending batch back into the MAIN backlog, run from
# the main firstmate home.
#
# Safety: this is an explicit, one-shot operator/firstmate act, never routine
# recovery. Only a batch still in pending/ can be rolled back - an ingested/
# batch already lives in the secondmate's own backlog.md and reclaiming it
# here would duplicate the item without the secondmate's cooperation, so that
# is refused loudly rather than attempted. Refuses just as loudly, with no
# byte moved, if the batch has already been rolled back or is unknown.
#
# Concurrency hazard (documented, not engineered away - this is a rare,
# explicit act, not routine traffic): the batch file is a plain file on the
# signal-bridge mount with no lock. Rolling back a batch the guest is
# concurrently ingesting races two independent `tasks-axi mv` invocations
# against the same file from different processes (host rollback, in-guest
# ingest). Only run this after confirming with `bin/fm-backlog-handoff-status.sh`
# that the batch is genuinely stuck (e.g. the sandbox is confirmed dead), not
# merely slow.
#
# Usage: fm-backlog-handoff-rollback.sh <secondmate-id> <batch-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MAIN_BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-key-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-key-lib.sh"
# shellcheck source=bin/fm-backlog-handoff-sbx-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-handoff-sbx-lib.sh"

[ $# -eq 2 ] || { echo "usage: fm-backlog-handoff-rollback.sh <secondmate-id> <batch-id>" >&2; exit 1; }
ID=$1
BATCH_ID=$2
CASE_BATCH_ID=${BATCH_ID%.md}
case "$CASE_BATCH_ID" in
  ""|*/*|*..*|*[!A-Za-z0-9_.-]*)
    echo "error: invalid batch id $BATCH_ID; expected a basename like <batch-id> or <batch-id>.md containing only A-Z, a-z, 0-9, '_', '.', and '-'; nothing to roll back" >&2
    exit 1
    ;;
esac
case "$BATCH_ID" in
  *.md) ;;
  *) BATCH_ID="$BATCH_ID.md" ;;
esac

SIGNALS_DIR=$(fm_backlog_handoff_sbx_signals_dir "$STATE" "$ID" 2>/dev/null || true)
if [ -z "$SIGNALS_DIR" ]; then
  echo "error: $ID is not a recorded sbx-backed secondmate (no backend=sbx / sbx_signals_dir= in $STATE/$ID.meta); nothing to roll back" >&2
  exit 1
fi

PENDING_DIR=$(fm_backlog_handoff_pending_dir "$SIGNALS_DIR")
INGESTED_DIR=$(fm_backlog_handoff_ingested_dir "$SIGNALS_DIR")
ROLLED_BACK_DIR=$(fm_backlog_handoff_rolled_back_dir "$SIGNALS_DIR")
BATCH_FILE="$PENDING_DIR/$BATCH_ID"

if [ -f "$INGESTED_DIR/$BATCH_ID" ]; then
  echo "error: batch $BATCH_ID was already ingested into $ID's own backlog; rolling it back here would duplicate the item without $ID's cooperation. Reconcile with $ID directly (or its own backlog) instead." >&2
  exit 1
fi
if [ -f "$ROLLED_BACK_DIR/$BATCH_ID" ]; then
  echo "error: batch $BATCH_ID was already rolled back; nothing to do." >&2
  exit 1
fi
if [ ! -f "$BATCH_FILE" ]; then
  echo "error: no pending batch named $BATCH_ID for $ID under $PENDING_DIR" >&2
  exit 1
fi

KEYS=()
while IFS= read -r k; do
  [ -n "$k" ] && KEYS+=("$k")
done < <(fm_backlog_key_list "$BATCH_FILE")

if [ "${#KEYS[@]}" -eq 0 ]; then
  echo "error: batch $BATCH_ID carries no items to reclaim (already drained); check $INGESTED_DIR and $ID's own backlog before deciding this needs further action." >&2
  exit 1
fi

if ! fm_tasks_axi_compatible; then
  echo "error: tasks-axi with atomic multi-ID mv support (0.2.2+) is required to roll back backlog-handoff batches" >&2
  exit 1
fi

if ! MV_OUT=$(tasks-axi mv "${KEYS[@]}" --file "$BATCH_FILE" --to "$MAIN_BACKLOG" 2>&1); then
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  echo "error: tasks-axi mv failed; nothing was moved." >&2
  exit 1
fi

mkdir -p "$ROLLED_BACK_DIR"
mv -f "$BATCH_FILE" "$ROLLED_BACK_DIR/$BATCH_ID"

echo "reclaimed ${#KEYS[@]} item(s) from batch $BATCH_ID back into $MAIN_BACKLOG: ${KEYS[*]}"
echo "  batch archived (drained): $ROLLED_BACK_DIR/$BATCH_ID"
echo "  if $ID's guest later comes back and still has this batch's id in mind, it has nothing left to ingest for it - re-hand-off with bin/fm-backlog-handoff.sh if the item should still go to $ID."
