#!/usr/bin/env bash
# tests/backlog-handoff-sbx-helpers.sh - shared fixtures for the
# backlog-handoff sbx-delivery suites (fm-backlog-handoff-sbx,
# fm-backlog-ingest, fm-backlog-handoff-status, fm-backlog-handoff-rollback):
# a main home with an sbx-backed secondmate registered and recorded (main-home
# meta carrying backend=sbx + sbx_signals_dir=), plus its plain host-side
# secondmate home directory - the dead clone GitHub issue #11 says this whole
# family must never write into.

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

# new_sbx_handoff_world <world-dir> <id>: writes <world-dir>/main (registry +
# meta) and <world-dir>/sub (the seeded secondmate home) and
# <world-dir>/signals/<id> (the signal-bridge dir, pre-created so tests can
# choose whether to also mkdir the backlog-handoff subtree). Echoes nothing;
# callers reference the fixed subpaths directly.
new_sbx_handoff_world() {  # <world-dir> <id>
  local w=$1 id=$2 home sub_abs sig
  mkdir -p "$w/main/data" "$w/main/state" "$w/signals/$id"
  home="$w/sub"
  seed_secondmate_home_marker "$home" "$id"
  sub_abs=$(cd "$home" && pwd -P)
  printf -- '- %s - sbx domain (home: %s; scope: sbx domain; projects: alpha; added 2026-07-23)\n' \
    "$id" "$sub_abs" > "$w/main/data/secondmates.md"
  sig="$w/signals/$id"
  fm_write_meta "$w/main/state/$id.meta" \
    "window=sbx:fm-$id" "worktree=$home" "project=$home" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=sbx" "home=$home" "projects=alpha" "sbx_signals_dir=$sig"
}

# make_guest_home <dir> <id> <signals-dir>: a plain directory shaped like the
# secondmate's OWN in-guest home - the two regular-file markers guest-home
# provisioning seeds (identity + signal-bridge path) plus data/.
make_guest_home() {  # <dir> <id> <signals-dir>
  local home=$1 id=$2 sig=$3
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '%s\n' "$sig" > "$home/.fm-sbx-signals-dir"
}
