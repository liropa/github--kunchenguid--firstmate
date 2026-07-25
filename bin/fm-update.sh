#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - one "secondmate <id> guest:" line per sbx-backed secondmate (the in-VM
#     clone's OWN outcome - a host-home line above never implies the guest
#     advanced; bin/backends/sbx.sh owns the sync mechanics)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- sbx guest clones --------------------------------------------------------
# An sbx secondmate's HOST clone (swept above) is only the sync SOURCE: the
# guest runs a private in-VM clone that clone mode snapshotted at provisioning
# and that no host-side fast-forward ever reaches (fork issue #20). Report the
# GUEST outcome for every sbx-backed secondmate so the summary never implies a
# host-home advance reached the VM. Detection is the recorded task metadata
# (backend=sbx), never a probe - the backlog-handoff precedent - so a
# registry-only secondmate with no live metadata has no recorded sandbox to
# sync and prints no guest line.

sbx_ready=""
while IFS='|' read -r id home _window meta; do
  [ "$(fm_backend_of_meta "$meta")" = sbx ] || continue
  if [ -z "$sbx_ready" ]; then
    if fm_backend_source sbx >/dev/null 2>&1; then sbx_ready=yes; else sbx_ready=no; fi
  fi
  if [ "$sbx_ready" != yes ]; then
    echo "secondmate $id guest: skipped: sbx adapter failed to load"
    continue
  fi
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id guest: skipped: unsafe home: $VALIDATION_ERROR"
    continue
  fi
  fm_backend_sbx_tracked_sync "secondmate $id guest" "fm-$id" "$id" "$VALIDATED_HOME" "$meta" sweep
done < <(live_secondmate_meta_records "$STATE" "$SECONDMATES_MD")

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
