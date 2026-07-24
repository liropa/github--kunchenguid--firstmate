# shellcheck shell=bash
# bin/fm-backlog-key-lib.sh - shared backlog item-key lookups against the
# `- [ ] <key> ...` / `- [x] <key> ...` header convention `tasks-axi` writes
# and firstmate's `## In flight` / `## Queued` / `## Done` section scaffold.
# Reads only section headings and item header lines - never item bodies - so
# it drives classification (in-flight refusal, already-present idempotency,
# missing-key detection) without re-implementing the block/body move
# semantics `tasks-axi mv` owns.
#
# Sourced by bin/fm-backlog-handoff.sh (host, delivery), bin/fm-backlog-ingest.sh
# (guest, ingestion), and bin/fm-backlog-handoff-status.sh /
# bin/fm-backlog-handoff-rollback.sh (host, recovery), so every reader of a
# backlog-shaped file - the main backlog, a secondmate backlog, or a
# signal-bridge batch artifact - agrees on the same parse.
#
# Usage: . bin/fm-backlog-key-lib.sh

# fm_backlog_key_section <file> <key>: prints the column-0 `## ...` section
# <key>'s `- [ ]`/`- [x]` header line lives under (defaulting to `## Queued`
# for a header above the first section heading), or returns non-zero when no
# header matches <key> in <file>.
fm_backlog_key_section() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# fm_backlog_key_list <file>: every item key in <file> (one per line, file
# order), regardless of section - a plain header enumeration for a caller
# that needs "what keys does this file carry" (a signal-bridge batch
# artifact's contents, for ingest or recovery tooling). Empty output for a
# missing file, never an error - an absent file simply carries no keys.
fm_backlog_key_list() {  # <file>
  local file=$1
  [ -f "$file" ] || return 0
  awk '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      print id
    }
  ' "$file"
}
