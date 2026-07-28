# shellcheck shell=bash
# bin/fm-state-key-lib.sh - the single owner of the encoding that embeds a task
# id (or a signal filename) inside a state/ marker filename.
#
# Several watcher and backend markers are named "<fixed-prefix><key>", where the
# key identifies the task the marker belongs to: the sbx beat-beacon family
# (.sbx-beat-te-, .sbx-beat-status-, .sbx-noprogress-, .sbx-stranded-alarmed-,
# .sbx-mount-alarmed-, .sbx-midtask-stop-, .sbx-delivered-, and the transient
# .sbx-delivery-pending- candidates) and the signal scan's .seen- signatures.
# Producer (bin/backends/sbx.sh), consumer (bin/fm-watch.sh), and cleanup
# (bin/fm-teardown.sh) must agree on that key byte for byte, so the transform
# lives here and ONLY here.
#
# THE ENCODING. fm_state_key_encode escapes with `_` as the escape character:
# every byte outside [A-Za-z0-9-] becomes `_` plus its two lowercase hex digits,
# and bytes inside that set pass through unchanged. It is ordinary
# percent-encoding with `_` in place of `%`, chosen because it is the simplest
# transform that is injective (the property the previous `tr '.' '_'` fold
# lacked: it mapped both `a.b` and `a_b` to `a_b`, so two tasks shared one
# marker file) while keeping the properties the marker names depend on:
#
#   - Distinct inputs produce distinct keys, and fm_state_key_decode recovers
#     the exact input bytes from the key.
#   - The key is always one safe path segment: `/` and every other byte outside
#     [A-Za-z0-9-] is escaped, so a key can never traverse a directory, and a
#     leading `.` becomes `_2e`, so the marker's own prefix stays the only
#     leading dot in the filename.
#   - The key never contains `.`, `:` or any other separator-shaped byte. `.` is
#     therefore the one delimiter that is safe between a key and a trailing
#     nonce, which is what .sbx-delivery-pending-<key>.<pid>.<random> uses so
#     bin/fm-teardown.sh's `<key>.*` glob cannot reach another task's candidate.
#   - Length is bounded at three times the input, so a 64-byte task id (the
#     creation limit in bin/fm-pr-lib.sh's fm_task_id_creation_valid) yields at
#     most a 192-byte key - well inside any filesystem's name limit even with a
#     marker prefix and a nonce appended.
#   - A task id that is already a bare slug (letters, digits and hyphens - the
#     shape fm-spawn.sh's callers actually use) encodes to itself, so the common
#     case is byte-identical to the pre-migration name and needs no migration.
#
# Production code only ever ENCODES. fm_state_key_decode is the reversibility
# half of the contract: the tests hold the round-trip property against it, and
# it is the diagnostic path for reading an unfamiliar marker filename back to
# its owner. bin/fm-state-key-migrate.sh deliberately does NOT decode legacy
# names - a legacy key is ambiguous by construction, so decoding one would
# invent an owner rather than resolve it; it resolves legacy names against the
# ids the home can actually enumerate instead.
#
# fm_state_key_legacy reproduces the superseded fold. It exists only so the
# migration has one owner for the old shape too, and no caller outside the
# migration may use it to name a file.
#
# Sourced by bin/fm-watch.sh, bin/fm-teardown.sh, bin/backends/sbx.sh,
# bin/fm-state-key-migrate.sh, and the tests. No side effects on source.
# set -u / set -e safe.
#
# Usage: . bin/fm-state-key-lib.sh

# fm_state_key_encode <text>: print <text> encoded as a marker key. Total - any
# byte sequence encodes, including the empty string (which encodes to itself).
fm_state_key_encode() {  # <text>
  local text=${1-} out='' i n c code esc
  # Byte semantics, so a multibyte character escapes to its individual bytes
  # and decode reproduces them exactly rather than to a codepoint that would
  # not fit two hex digits.
  local LC_ALL=C
  n=${#text}
  i=0
  while [ "$i" -lt "$n" ]; do
    c=${text:i:1}
    case $c in
      [A-Za-z0-9-])
        out=$out$c
        ;;
      *)
        # Bash reports a high byte as a negative char, so mask to 0-255 before
        # formatting; otherwise 0xc3 would render as ffffffffffffffc3.
        printf -v code '%d' "'$c"
        printf -v esc '_%02x' "$(( code & 255 ))"
        out=$out$esc
        ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

# fm_state_key_decode <key>: print the text <key> encodes, or return 1 when
# <key> is not a well-formed key. Refusing is the point: a name produced by any
# other scheme (including the superseded fold) must not decode into a
# plausible-looking lie.
fm_state_key_decode() {  # <key>
  local key=${1-} out='' i n c hex byte
  local LC_ALL=C
  n=${#key}
  i=0
  while [ "$i" -lt "$n" ]; do
    c=${key:i:1}
    case $c in
      _)
        hex=${key:i+1:2}
        case $hex in
          [0-9a-f][0-9a-f]) ;;
          *) return 1 ;;
        esac
        # NUL cannot occur in a bash string, so no encoder output contains _00.
        [ "$hex" != 00 ] || return 1
        printf -v byte '%b' "\\x$hex"
        out=$out$byte
        i=$(( i + 3 ))
        ;;
      [A-Za-z0-9-])
        out=$out$c
        i=$(( i + 1 ))
        ;;
      *)
        return 1
        ;;
    esac
  done
  printf '%s' "$out"
}

# fm_state_key_legacy <text>: print the SUPERSEDED marker key for <text> - every
# `.` folded to `_`. Only bin/fm-state-key-migrate.sh may call this, and only to
# recognize names written before the encoding above existed.
fm_state_key_legacy() {  # <text>
  local text=${1-}
  printf '%s' "${text//./_}"
}

# fm_state_sbx_marker_prefixes: the durable sbx beat-beacon marker prefixes,
# one per line, each named "<prefix><key>". Shared by bin/fm-teardown.sh's
# cleanup and bin/fm-state-key-migrate.sh so the two cannot disagree about which
# families exist. The transient .sbx-delivery-pending- candidates are NOT in
# this list: they carry a trailing nonce, so they are named through
# FM_STATE_SBX_PENDING_PREFIX and matched with the `<key>.` delimiter instead.
fm_state_sbx_marker_prefixes() {
  cat <<'EOF'
.sbx-beat-te-
.sbx-beat-status-
.sbx-noprogress-
.sbx-stranded-alarmed-
.sbx-mount-alarmed-
.sbx-midtask-stop-
.sbx-delivered-
EOF
}

# Transient delivery candidate: FM_STATE_SBX_PENDING_PREFIX<key>.<pid>.<random>.
# The `.` delimiter is load-bearing - an encoded key never contains one, so
# teardown's "<key>." glob matches this task's candidates and no others.
# shellcheck disable=SC2034  # consumed by the scripts that source this library
FM_STATE_SBX_PENDING_PREFIX=.sbx-delivery-pending-

# Signal-scan signature marker: FM_STATE_SEEN_PREFIX<encoded signal filename>.
# The key here encodes a whole "<id>.status" / "<id>.turn-ended" basename, not a
# bare id, so two tasks whose names differ only where the superseded fold was
# lossy no longer share one signature file.
# shellcheck disable=SC2034  # consumed by the scripts that source this library
FM_STATE_SEEN_PREFIX=.seen-
