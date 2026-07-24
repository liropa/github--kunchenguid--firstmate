#!/usr/bin/env bash
# Guest-side counterpart to bin/fm-backlog-handoff.sh's sbx delivery path
# (GitHub issue #11): merge every pending signal-bridge backlog-handoff batch
# into THIS secondmate's own backlog, idempotently.
#
# Why this exists: an sbx clone-mode secondmate runs against its own in-VM
# clone of its home, snapshotted at provisioning - it never re-reads a later
# host-side write into that clone (docs/sbx-backend.md), and the clone-mode
# read-only source mount can itself go stale across a VM stop/resurrect cycle.
# The signal bridge (this home's `.fm-sbx-signals-dir` bind mount) is the one
# surface proven live in both directions regardless of VM lifecycle, so
# fm-backlog-handoff.sh delivers a moved item there as a durable batch
# artifact instead of writing into this clone directly. This script is the
# other half: run it (steered/nudged by the main firstmate, never polled) to
# pull every pending batch into this home's own `data/backlog.md`.
#
# What this script owns: discovering this home's own signal-bridge dir
# (`.fm-sbx-signals-dir`, sibling to `.fm-secondmate-home` - both regular-file
# markers seeded by guest-home provisioning, never symlinks), enumerating
# pending batches, and per-key idempotent skip (a key already present in this
# home's own backlog, under any section, is left alone - already ingested or
# already otherwise known).
# What `tasks-axi mv <id>... --to <backlog>` owns: the same atomic
# byte-exact block move (a whole connected set together, blocked-by links
# preserved) that bin/fm-backlog-handoff.sh delegates to on the host side.
#
# A batch left with nothing still needing merge (every key already present -
# a re-run, or an operator rollback that raced ahead and reclaimed it first)
# is archived as a clean no-op: this script never reports a stale batch as a
# failure. A batch is archived from pending/ to ingested/ only after its
# tasks-axi mv (or its "nothing to merge" check) succeeds, so a run that dies
# partway through a batch leaves it in pending/ for the next run to retry -
# never lost, never double-merged (tasks-axi mv itself is the atomic unit).
#
# Not a secondmate home, or a secondmate home that is not an sbx clone-mode
# guest (no `.fm-sbx-signals-dir`): a clean no-op, exit 0. No pending
# batches: a clean no-op, exit 0. Any batch whose tasks-axi mv fails: reported
# loudly, left in pending/ for retry, and the script exits non-zero after
# attempting every other batch.
# Usage: fm-backlog-ingest.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-key-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-key-lib.sh"
# shellcheck source=bin/fm-backlog-handoff-sbx-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-handoff-sbx-lib.sh"

IDENTITY_MARKER="$FM_HOME/.fm-secondmate-home"
SIGNALS_MARKER="$FM_HOME/.fm-sbx-signals-dir"
OWN_BACKLOG="$DATA/backlog.md"

if [ ! -f "$IDENTITY_MARKER" ]; then
  echo "nothing to ingest: $FM_HOME is not a seeded secondmate home (no .fm-secondmate-home)"
  exit 0
fi
if [ ! -f "$SIGNALS_MARKER" ]; then
  echo "nothing to ingest: $FM_HOME has no signal-bridge marker (.fm-sbx-signals-dir); not an sbx clone-mode guest"
  exit 0
fi

SIGNALS_DIR=$(cat "$SIGNALS_MARKER")
if [ -z "$SIGNALS_DIR" ]; then
  echo "error: $SIGNALS_MARKER is empty; cannot locate the signal bridge" >&2
  exit 1
fi

PENDING_DIR=$(fm_backlog_handoff_pending_dir "$SIGNALS_DIR")
INGESTED_DIR=$(fm_backlog_handoff_ingested_dir "$SIGNALS_DIR")

BATCHES=()
if [ -d "$PENDING_DIR" ]; then
  for f in "$PENDING_DIR"/*.md; do
    [ -f "$f" ] && BATCHES+=("$f")
  done
fi
if [ "${#BATCHES[@]}" -eq 0 ]; then
  echo "nothing to ingest: no pending batches under $PENDING_DIR"
  exit 0
fi

if ! fm_tasks_axi_compatible; then
  echo "error: tasks-axi with atomic multi-ID mv support (0.2.2+) is required to ingest backlog-handoff batches" >&2
  exit 1
fi

mkdir -p "$INGESTED_DIR"

MERGED_TOTAL=0
SKIPPED_TOTAL=0
FAILED_TOTAL=0
for batch in "${BATCHES[@]}"; do
  base=$(basename "$batch")
  KEYS=()
  while IFS= read -r k; do
    [ -n "$k" ] && KEYS+=("$k")
  done < <(fm_backlog_key_list "$batch")

  TO_MERGE=()
  for key in "${KEYS[@]}"; do
    if fm_backlog_key_section "$OWN_BACKLOG" "$key" >/dev/null 2>&1; then
      SKIPPED_TOTAL=$((SKIPPED_TOTAL + 1))
    else
      TO_MERGE+=("$key")
    fi
  done

  if [ "${#TO_MERGE[@]}" -eq 0 ]; then
    # Nothing left in this batch that this home doesn't already have -
    # already ingested by an earlier run, or reclaimed out from under us by
    # an operator rollback. Archive it as the clean no-op it is.
    mv -f "$batch" "$INGESTED_DIR/$base"
    echo "ingested (already present): $base"
    continue
  fi

  mkdir -p "$DATA"
  OWN_CREATED=0
  if [ ! -f "$OWN_BACKLOG" ]; then
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$OWN_BACKLOG"
    OWN_CREATED=1
  fi

  if MV_OUT=$(tasks-axi mv "${TO_MERGE[@]}" --file "$batch" --to "$OWN_BACKLOG" 2>&1); then
    mv -f "$batch" "$INGESTED_DIR/$base"
    MERGED_TOTAL=$((MERGED_TOTAL + ${#TO_MERGE[@]}))
    echo "ingested $base: ${TO_MERGE[*]}"
  else
    if [ "$OWN_CREATED" -eq 1 ]; then
      rm -f "$OWN_BACKLOG"
    fi
    FAILED_TOTAL=$((FAILED_TOTAL + 1))
    echo "error: failed to ingest $base (left in $PENDING_DIR for retry):" >&2
    if [ -n "$MV_OUT" ]; then
      printf '%s\n' "$MV_OUT" >&2
    fi
  fi
done

echo "ingest summary: merged $MERGED_TOTAL item(s), skipped $SKIPPED_TOTAL already-present item(s), $FAILED_TOTAL batch(es) failed"
[ "$FAILED_TOTAL" -eq 0 ]
