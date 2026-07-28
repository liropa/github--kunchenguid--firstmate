#!/usr/bin/env bash
# tests/fm-state-key.test.sh - the marker-filename key contract
# (bin/fm-state-key-lib.sh) and the sweep that renames pre-existing markers onto
# it (bin/fm-state-key-migrate.sh).
#
# The guarantees under test:
#   - Distinct task ids produce distinct keys. The superseded `tr '.' '_'` fold
#     did not: `a.b` and `a_b` folded to one name, so two tasks shared one
#     marker file and each could arm, silence, or delete the other's beacons.
#   - A key round-trips: the exact input bytes come back out of the filename.
#   - A key stays one safe path segment with no `/`, no `.`, and no leading dot
#     beyond the marker's own prefix, and is bounded in length.
#   - The migration is idempotent, resolves a legacy name only against ids the
#     home can enumerate, and REPORTS rather than picks when a legacy name maps
#     to more than one live id.
#   - The migration preserves marker content and mtime, because the delivery
#     breadcrumb's mtime IS the acknowledgement clock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-state-key-lib.sh
. "$ROOT/bin/fm-state-key-lib.sh"

MIGRATE="$ROOT/bin/fm-state-key-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-state-key)

new_state() {  # <name>: a state dir under a fresh case root
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s' "$dir/state"
}

migrate() {  # <state>: run the sweep, print its combined output
  "$MIGRATE" --state "$1" 2>&1
}

mtime_of() {  # <file>
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

# --- the collision this change exists to fix --------------------------------

# The defect, stated directly: the superseded fold is not injective, so the two
# ids below named ONE marker file. This assertion fails against that fold and
# passes only against a reversible encoding.
[ "$(fm_state_key_legacy 'a.b')" = "$(fm_state_key_legacy 'a_b')" ] \
  || fail "setup: the superseded fold is supposed to collapse a.b and a_b"
[ "$(fm_state_key_encode 'a.b')" != "$(fm_state_key_encode 'a_b')" ] \
  || fail "a.b and a_b must not share a marker key: both encode to $(fm_state_key_encode 'a.b')"
pass "the a.b / a_b collision the superseded fold produced is gone"

# The same separation must hold across every marker family and the transient
# candidate name, since those are the filenames that actually collided.
for PREFIX in $(fm_state_sbx_marker_prefixes) "$FM_STATE_SBX_PENDING_PREFIX" "$FM_STATE_SEEN_PREFIX"; do
  [ "$PREFIX$(fm_state_key_encode 'a.b')" != "$PREFIX$(fm_state_key_encode 'a_b')" ] \
    || fail "$PREFIX names one file for both a.b and a_b"
done
pass "every marker family names a.b and a_b apart"

# Injectivity over a set built specifically from the characters the fold ate.
COLLIDERS='a.b
a_b
a..b
a__b
a._b
a_.b
.ab
_ab
ab.
ab_
a-b
a.b.status
a_b.status
a.b.turn-ended'
ENCODED=$(while IFS= read -r NAME; do fm_state_key_encode "$NAME"; echo; done <<EOF
$COLLIDERS
EOF
)
TOTAL=$(printf '%s\n' "$COLLIDERS" | grep -c .)
DISTINCT=$(printf '%s\n' "$ENCODED" | LC_ALL=C sort -u | grep -c .)
[ "$TOTAL" = "$DISTINCT" ] || fail "encoding collapsed $TOTAL names into $DISTINCT keys"
pass "every name that the fold collapsed encodes to a distinct key ($TOTAL/$TOTAL)"

# --- round-trip reversibility ------------------------------------------------

ROUNDTRIP="a.b
a_b
plain
sbx-marker-key-collision
a.b.status
weird/id
.leading-dot
trailing.
a b
$(printf 'multi\tbyte')
héllo
_
.
-"
while IFS= read -r NAME; do
  KEY=$(fm_state_key_encode "$NAME")
  BACK=$(fm_state_key_decode "$KEY") || fail "decode refused its own encoding of '$NAME' ($KEY)"
  [ "$BACK" = "$NAME" ] || fail "round-trip lost '$NAME': encoded $KEY, decoded '$BACK'"
done <<EOF
$ROUNDTRIP
EOF
pass "every key decodes back to the exact bytes it was built from"

[ "$(fm_state_key_encode '')" = "" ] || fail "the empty string must encode to itself"
[ "$(fm_state_key_decode '')" = "" ] || fail "the empty key must decode to itself"
pass "the empty name round-trips"

# --- the filename properties the marker names depend on ----------------------

for NAME in 'a.b' '../escape' 'sbx:fm-x' $'new\nline' 'héllo' '.hidden'; do
  KEY=$(fm_state_key_encode "$NAME")
  case $KEY in
    .*) fail "'$NAME' encoded to a key starting with a dot: $KEY" ;;
    *'/'*) fail "'$NAME' encoded to a key containing a path separator: $KEY" ;;
    *'.'*) fail "'$NAME' encoded to a key containing a dot: $KEY" ;;
    *':'*) fail "'$NAME' encoded to a key containing a colon: $KEY" ;;
    *[!A-Za-z0-9_-]*) fail "'$NAME' encoded outside the key alphabet: $KEY" ;;
  esac
  [ "${#KEY}" -le $(( ${#NAME} * 3 )) ] \
    || fail "'$NAME' encoded to ${#KEY} bytes, past the 3x bound"
done
pass "a key is one safe path segment, dot-free, and bounded at three times its input"

# A bare slug encodes to itself. This is what keeps the migration a no-op in
# homes whose task ids are ordinary kebab-case, so almost nothing is renamed.
for NAME in x smx domain sbx-marker-key-collision fm-2ndmate-1; do
  [ "$(fm_state_key_encode "$NAME")" = "$NAME" ] \
    || fail "the bare slug '$NAME' should encode to itself, got $(fm_state_key_encode "$NAME")"
done
pass "a bare-slug id encodes to itself, so its existing markers need no rename"

# Decode refuses anything that is not its own output, so a legacy name can never
# be read back as a confident owner.
for BAD in 'a_b' 'a_' 'a_z9' 'a_2' 'a.b' 'a/b' 'a_00'; do
  ! fm_state_key_decode "$BAD" >/dev/null 2>&1 \
    || fail "decode should refuse the malformed key '$BAD', got $(fm_state_key_decode "$BAD")"
done
pass "decode refuses malformed keys instead of inventing an owner"

# --- migration: the ordinary rename ------------------------------------------

STATE=$(new_state rename)
: > "$STATE/a.b.meta"
: > "$STATE/a.b.status"
printf 'the keep-alive cap expired while in-guest work was still active\n' \
  > "$STATE/.sbx-midtask-stop-a_b"
touch -t 202001010000 "$STATE/.sbx-midtask-stop-a_b"
BEFORE=$(mtime_of "$STATE/.sbx-midtask-stop-a_b")
OUT=$(migrate "$STATE")
NEW="$STATE/.sbx-midtask-stop-$(fm_state_key_encode 'a.b')"
[ -f "$NEW" ] || fail "the legacy marker was not migrated: $OUT / $(ls -a "$STATE")"
[ ! -e "$STATE/.sbx-midtask-stop-a_b" ] || fail "the legacy name should be gone after the rename"
assert_contains "$(cat "$NEW")" "keep-alive cap expired" "the marker's recorded reason was lost"
[ "$(mtime_of "$NEW")" = "$BEFORE" ] \
  || fail "the rename changed the marker mtime, which is the delivery acknowledgement clock"
assert_contains "$OUT" "BOOTSTRAP_INFO: migrated 1 state marker name" "the rename was not reported"
pass "migration renames a legacy marker onto the current key, preserving its content and mtime"

# --- migration: idempotency ---------------------------------------------------

OUT2=$(migrate "$STATE")
[ -z "$OUT2" ] || fail "a second run should be silent, printed: $OUT2"
[ -f "$NEW" ] || fail "a second run removed or renamed an already-current marker"
OUT3=$(migrate "$STATE")
[ -z "$OUT3" ] || fail "a third run should still be silent, printed: $OUT3"
[ -f "$NEW" ] || fail "a third run removed or renamed an already-current marker"
pass "migration is idempotent: repeated runs leave a current marker alone and say nothing"

# --- migration: an ambiguous legacy name is reported, never guessed ----------

STATE=$(new_state ambiguous)
: > "$STATE/a.b.meta"
: > "$STATE/a_b.meta"
: > "$STATE/.sbx-delivered-a_b"
OUT=$(migrate "$STATE")
[ -e "$STATE/.sbx-delivered-a_b" ] \
  || fail "an ambiguous legacy marker must be left exactly where it is"
[ ! -e "$STATE/.sbx-delivered-$(fm_state_key_encode 'a.b')" ] \
  || fail "the sweep guessed a.b for an ambiguous legacy name"
[ ! -e "$STATE/.sbx-delivered-$(fm_state_key_encode 'a_b')" ] \
  || fail "the sweep guessed a_b for an ambiguous legacy name"
assert_contains "$OUT" "STATE_KEY_MIGRATION: state/.sbx-delivered-a_b" "the ambiguity was not reported"
assert_contains "$OUT" "more than one live task" "the report should say why it refused"
assert_contains "$OUT" "a.b" "the report should name the candidate ids"
assert_contains "$OUT" "a_b" "the report should name the candidate ids"
pass "migration reports a legacy name that maps to more than one live id instead of picking one"

STATE=$(new_state cross-scheme)
: > "$STATE/a.b.meta"
: > "$STATE/a_2eb.meta"
printf 'ambiguous\n' > "$STATE/.sbx-delivered-a_2eb"
OUT=$(migrate "$STATE")
[ ! -e "$STATE/.sbx-delivered-a_2eb" ] \
  || fail "a cross-scheme overlap remained visible as a.b's current marker"
[ ! -e "$STATE/.sbx-delivered-$(fm_state_key_encode 'a_2eb')" ] \
  || fail "a cross-scheme overlap was attributed to its legacy owner"
[ "$(cat "$STATE/.sbx-delivered-a_2eb.state-key-unresolved")" = ambiguous ] \
  || fail "a cross-scheme overlap was not preserved under an inert name"
assert_contains "$OUT" "could be current for a.b or legacy for a_2eb" \
  "the cross-scheme ambiguity was not reported"
pass "migration makes a cross-scheme overlap invisible without attributing or deleting it"

# --- migration: names it must not touch --------------------------------------

STATE=$(new_state untouched)
: > "$STATE/live.meta"
: > "$STATE/live.status"
: > "$STATE/.sbx-delivered-retired_task"
: > "$STATE/.sbx-delivery-pending-live-123-456"
OUT=$(migrate "$STATE")
[ -z "$OUT" ] || fail "orphan and transient names should be silent, printed: $OUT"
[ -e "$STATE/.sbx-delivered-retired_task" ] \
  || fail "a marker with no live owner must be left in place, never deleted"
[ -e "$STATE/.sbx-delivery-pending-live-123-456" ] \
  || fail "the transient delivery candidates are deliberately out of the sweep's scope"
pass "migration leaves an ownerless marker and the transient candidates alone, silently"

# A rename that would land on an existing name is reported, not forced.
STATE=$(new_state conflict)
: > "$STATE/a.b.meta"
printf 'legacy\n' > "$STATE/.sbx-delivered-a_b"
printf 'current\n' > "$STATE/.sbx-delivered-$(fm_state_key_encode 'a.b')"
OUT=$(migrate "$STATE")
[ "$(cat "$STATE/.sbx-delivered-$(fm_state_key_encode 'a.b')")" = current ] \
  || fail "the sweep overwrote an existing current marker"
[ -e "$STATE/.sbx-delivered-a_b" ] || fail "the legacy marker should survive a refused rename"
assert_contains "$OUT" "already exists" "the destination conflict was not reported"
pass "migration refuses a rename that would land on an existing name and reports it"

STATE=$(new_state raced-conflict)
: > "$STATE/a.b.meta"
printf 'legacy\n' > "$STATE/.sbx-delivered-a_b"
FAKEBIN="$TMP_ROOT/raced-conflict/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ln" <<'SH'
#!/usr/bin/env bash
set -u
destination=
for argument in "$@"; do
  destination=$argument
done
case "$*" in
  *".sbx-delivered-a_b"*) printf 'racer\n' > "$destination" ;;
esac
exec /bin/ln "$@"
SH
chmod +x "$FAKEBIN/ln"
OUT=$(PATH="$FAKEBIN:$PATH" migrate "$STATE")
[ "$(cat "$STATE/.sbx-delivered-$(fm_state_key_encode 'a.b')")" = racer ] \
  || fail "the sweep overwrote a destination created during the rename"
[ "$(cat "$STATE/.sbx-delivered-a_b")" = legacy ] \
  || fail "the legacy marker disappeared after a raced destination conflict"
assert_contains "$OUT" "already exists" "the raced destination conflict was not reported"
pass "migration atomically refuses a destination created during the rename"

STATE=$(new_state active-watcher)
: > "$STATE/a.b.meta"
printf 'legacy\n' > "$STATE/.sbx-delivered-a_b"
mkdir "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
STATUS=0
OUT=$(migrate "$STATE") || STATUS=$?
expect_code 1 "$STATUS" "migration must refuse an active watcher"
[ "$(cat "$STATE/.sbx-delivered-a_b")" = legacy ] \
  || fail "migration changed marker state while the watcher lock was held"
assert_contains "$OUT" "watcher exclusion could not be acquired" \
  "active watcher refusal was not reported"
[ ! -e "$STATE/$FM_STATE_KEY_MIGRATION_COMPLETE" ] \
  || fail "failed watcher exclusion published migration completion"
pass "migration cannot run while watcher supervision is active"

STATE=$(new_state quarantine-failure)
: > "$STATE/a.b.meta"
: > "$STATE/a_2eb.meta"
printf 'ambiguous\n' > "$STATE/.sbx-delivered-a_2eb"
FAKEBIN="$TMP_ROOT/quarantine-failure/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ln" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *".sbx-delivered-a_2eb"*) exit 1 ;;
esac
exec /bin/ln "$@"
SH
chmod +x "$FAKEBIN/ln"
STATUS=0
OUT=$(PATH="$FAKEBIN:$PATH" migrate "$STATE") || STATUS=$?
expect_code 1 "$STATUS" "migration must fail when a cross-scheme marker cannot be moved aside"
[ -e "$STATE/$FM_STATE_KEY_MIGRATION_BLOCK" ] \
  || fail "failed cross-scheme quarantine did not persist a watcher block"
[ "$(cat "$STATE/.sbx-delivered-a_2eb")" = ambiguous ] \
  || fail "failed cross-scheme quarantine did not preserve the marker"
assert_contains "$OUT" "could not be moved aside" "quarantine failure was not reported"
WATCH_OUT="$TMP_ROOT/quarantine-failure/watch.out"
WATCH_STATUS=0
FM_HOME="${STATE%/state}" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-watch.sh" \
  > "$WATCH_OUT" 2>&1 || WATCH_STATUS=$?
expect_code 1 "$WATCH_STATUS" "watcher must refuse unresolved marker migration"
assert_contains "$(cat "$WATCH_OUT")" "marker-key migration is unresolved" \
  "watcher did not explain its unresolved-migration refusal"
pass "failed cross-scheme quarantine blocks marker consumers"

STATE=$(new_state missing-completion)
WATCH_OUT="$TMP_ROOT/missing-completion/watch.out"
WATCH_STATUS=0
FM_HOME="${STATE%/state}" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-watch.sh" \
  > "$WATCH_OUT" 2>&1 || WATCH_STATUS=$?
expect_code 1 "$WATCH_STATUS" "watcher must require positive marker migration completion"
assert_contains "$(cat "$WATCH_OUT")" "marker-key migration is unresolved" \
  "watcher did not explain its missing-completion refusal"
pass "watcher refuses to consume markers without migration completion"

# --- migration: the signal-scan signatures -----------------------------------

STATE=$(new_state seen)
: > "$STATE/a.b.status"
: > "$STATE/a.b.turn-ended"
printf '12:34\n' > "$STATE/.seen-a_b_status"
printf '56:78\n' > "$STATE/.seen-a_b_turn-ended"
OUT=$(migrate "$STATE")
[ -f "$STATE/.seen-$(fm_state_key_encode 'a.b.status')" ] \
  || fail "the status signature was not migrated: $OUT / $(ls -a "$STATE")"
[ -f "$STATE/.seen-$(fm_state_key_encode 'a.b.turn-ended')" ] \
  || fail "the turn-end signature was not migrated: $OUT / $(ls -a "$STATE")"
assert_contains "$(cat "$STATE/.seen-$(fm_state_key_encode 'a.b.status')")" "12:34" \
  "the signature contents were lost"
pass "migration renames the signal-scan signatures with the same rules"

# The signature namespace carries the collision the same way: two tasks whose
# ids fold together also fold their status filenames together, so both shared
# one signature file and re-signalled each other on every poll.
[ "$(fm_state_key_legacy 'a.b.status')" = "$(fm_state_key_legacy 'a_b.status')" ] \
  || fail "setup: the fold is supposed to collapse a.b.status and a_b.status"
STATE=$(new_state seen-ambiguous)
: > "$STATE/a.b.status"
: > "$STATE/a_b.status"
: > "$STATE/.seen-a_b_status"
OUT=$(migrate "$STATE")
[ -e "$STATE/.seen-a_b_status" ] || fail "an ambiguous signature must be left in place"
assert_contains "$OUT" "STATE_KEY_MIGRATION: state/.seen-a_b_status" \
  "the signature ambiguity was not reported"
assert_contains "$OUT" "a.b.status" "the report should name the candidate signal files"
pass "migration refuses an ambiguous signature name too"

# --- migration: an absent or empty home --------------------------------------

OUT=$(migrate "$TMP_ROOT/nonexistent-home/state")
[ -z "$OUT" ] || fail "a home with no state dir should be silent, printed: $OUT"
STATE=$(new_state empty)
OUT=$(migrate "$STATE")
[ -z "$OUT" ] || fail "an empty state dir should be silent, printed: $OUT"
[ -d "$STATE/$FM_STATE_KEY_MIGRATION_COMPLETE" ] \
  || fail "an empty state migration did not publish completion"
pass "migration is a silent no-op for a home with no state yet"

INVALID="$TMP_ROOT/invalid-state"
printf 'not a directory\n' > "$INVALID"
STATUS=0
OUT=$(migrate "$INVALID") || STATUS=$?
expect_code 1 "$STATUS" "migration must reject a state path that is a file"
assert_contains "$OUT" "state path is not a directory" "the invalid state path was not explained"
BROKEN="$TMP_ROOT/broken-state"
ln -s "$TMP_ROOT/missing-state-target" "$BROKEN"
STATUS=0
OUT=$(migrate "$BROKEN") || STATUS=$?
expect_code 1 "$STATUS" "migration must reject a broken state symlink"
assert_contains "$OUT" "state path is not a directory" "the broken state symlink was not explained"
pass "migration rejects existing unusable state paths"

STATE=$(new_state invalid-completion)
: > "$STATE/$FM_STATE_KEY_MIGRATION_COMPLETE"
STATUS=0
OUT=$(migrate "$STATE") || STATUS=$?
expect_code 1 "$STATUS" "migration must reject an invalid completion marker"
assert_contains "$OUT" "is invalid; watcher remains blocked" \
  "invalid migration completion was not reported"
pass "migration publishes only valid completion proof"

STATE=$(new_state unlocked-bootstrap)
: > "$STATE/a.b.meta"
: > "$STATE/.sbx-delivered-a_b"
FM_HOME="${STATE%/state}" FM_STATE_OVERRIDE="$STATE" FM_PROJECTS_OVERRIDE="${STATE%/state}/projects" \
  FM_CONFIG_OVERRIDE="${STATE%/state}/config" FM_DATA_OVERRIDE="${STATE%/state}/data" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ -e "$STATE/.sbx-delivered-a_b" ] \
  || fail "standalone bootstrap migrated marker state without owning the session lock"
[ ! -e "$STATE/.sbx-delivered-$(fm_state_key_encode 'a.b')" ] \
  || fail "standalone bootstrap produced a current marker without owning the session lock"
pass "standalone bootstrap cannot migrate marker state without the session lock"

STATE=$(new_state locked-bootstrap-active-watcher)
: > "$STATE/a.b.meta"
: > "$STATE/.sbx-delivered-a_b"
printf '%s\n' "$$" > "$STATE/.lock"
mkdir "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
FAKEBIN="$TMP_ROOT/locked-bootstrap-active-watcher/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$FAKEBIN/ps"
OUT=$(CLAUDE_PID="$$" PATH="$FAKEBIN:$PATH" FM_HOME="${STATE%/state}" \
  FM_STATE_OVERRIDE="$STATE" FM_PROJECTS_OVERRIDE="${STATE%/state}/projects" \
  FM_CONFIG_OVERRIDE="${STATE%/state}/config" FM_DATA_OVERRIDE="${STATE%/state}/data" \
  "$ROOT/bin/fm-bootstrap.sh" 2>&1)
[ -e "$STATE/.sbx-delivered-a_b" ] \
  || fail "lock-owning standalone bootstrap migrated while supervision was active"
[ ! -e "$STATE/.sbx-delivered-$(fm_state_key_encode 'a.b')" ] \
  || fail "lock-owning standalone bootstrap published a marker during supervision"
assert_contains "$OUT" "watcher exclusion could not be acquired" \
  "lock-owning standalone bootstrap did not report active supervision"
pass "lock ownership alone cannot migrate while supervision is active"

echo "# fm-state-key.test.sh: all assertions passed"
