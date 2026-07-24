# shellcheck shell=bash
# bin/fm-backlog-handoff-sbx-lib.sh - shared sbx-destination detection and
# signal-bridge path conventions for the backlog-handoff family of scripts:
# fm-backlog-handoff.sh (host, delivery), fm-backlog-ingest.sh (guest,
# ingestion), fm-backlog-handoff-status.sh and fm-backlog-handoff-rollback.sh
# (host, recovery).
#
# An sbx-backed secondmate's own host clone is a point-in-time snapshot the
# guest never re-reads and the clone-mode source mount can be hours stale
# after a VM resurrection (docs/sbx-backend.md; GitHub issue #11). Only the
# signal-bridge mount is a live, guest-writable/host-writable surface, so a
# handoff destination is detected from the recorded task metadata - never by
# probing the clone or guessing - and delivery rides that bridge instead of
# silently writing into a dead clone.
#
# Usage: . bin/fm-backlog-handoff-sbx-lib.sh

FM_BACKLOG_HANDOFF_SBX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || FM_BACKLOG_HANDOFF_SBX_LIB_DIR="."
# shellcheck source=bin/fm-backend.sh
. "$FM_BACKLOG_HANDOFF_SBX_LIB_DIR/fm-backend.sh"

# fm_backlog_handoff_sbx_signals_dir <state-dir> <secondmate-id>: prints the
# recorded signal-bridge directory when <state-dir>/<id>.meta records
# backend=sbx and a non-empty sbx_signals_dir=. Returns rc 1 only when the
# destination is not recorded as sbx-backed at all (no meta or a different
# backend). A malformed sbx record (backend=sbx with missing/empty
# sbx_signals_dir=) returns rc 0 with empty output so callers can refuse
# loudly instead of falling through to the non-sbx path.
fm_backlog_handoff_sbx_signals_dir() {  # <state-dir> <secondmate-id>
  local state=$1 id=$2 meta dir
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  [ "$(fm_backend_of_meta "$meta")" = sbx ] || return 1
  dir=$(fm_meta_get "$meta" sbx_signals_dir)
  printf '%s' "$dir"
}

# The three durable subdirectories under a signal-bridge dir that carry
# backlog-handoff batch artifacts. A batch file's LOCATION is its own status:
# pending/ means not yet merged into the guest's own backlog; ingested/ means
# the GUEST's own tasks-axi mv into its own backlog.md already succeeded;
# rolled-back/ means a HOST operator reclaimed it into the main backlog
# instead (fm-backlog-handoff-rollback.sh) - kept distinct from ingested/ so
# status reporting never implies guest action that never happened. Kept as
# functions so every script in the family names them identically -
# fm-backlog-handoff.sh writes into pending/, fm-backlog-ingest.sh moves a
# consumed batch into ingested/, fm-backlog-handoff-rollback.sh moves a
# reclaimed batch into rolled-back/, and fm-backlog-handoff-status.sh reads
# all three.
fm_backlog_handoff_pending_dir() {  # <signals-dir>
  printf '%s/backlog-handoff/pending' "$1"
}

fm_backlog_handoff_ingested_dir() {  # <signals-dir>
  printf '%s/backlog-handoff/ingested' "$1"
}

fm_backlog_handoff_rolled_back_dir() {  # <signals-dir>
  printf '%s/backlog-handoff/rolled-back' "$1"
}
