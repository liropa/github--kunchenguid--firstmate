#!/usr/bin/env bash
# Behavior tests for the shared tasks-axi wrapper's explicit-backlog-path rule.
# A fleet call must name its backlog file, so a discovered .tasks.toml cannot
# decide which file the command touches (captain decision 3, 2026-09-07).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tasks-axi-lib)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ARGS_FILE="$TMP_ROOT/tasks-axi.args"

# Stands in for tasks-axi so the wrapper's refusal is observable without a real
# backlog: a call that reaches the binary records its arguments.
cat > "$FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$ARGS_FILE'
echo reached-tasks-axi
SH
chmod +x "$FAKEBIN/tasks-axi"

# Runs one wrapper call in a fresh shell that sources the library the way every
# fleet script does, under the same set -eu those scripts use.
run_wrapper() {  # <arg>...
  local script="$TMP_ROOT/call.sh"
  {
    printf 'set -eu\n'
    printf '. %q\n' "$ROOT/bin/fm-tasks-axi-lib.sh"
    printf 'fm_tasks_axi'
    printf ' %q' "$@"
    printf '\n'
  } > "$script"
  PATH="$FAKEBIN:$BASE_PATH" bash "$script"
}

test_call_without_explicit_path_is_refused() {
  local out err status
  : > "$ARGS_FILE"
  out=$(run_wrapper list --limit 5 2>"$TMP_ROOT/refused.err")
  status=$?
  err=$(cat "$TMP_ROOT/refused.err")
  expect_code 2 "$status" "a pathless call must be refused, not run"
  assert_contains "$err" "--file" "the refusal should name the flag the call is missing"
  assert_contains "$err" "list" "the refusal should name the refused command"
  [ -z "$out" ] || fail "a refused call must produce no output, got: $out"
  [ ! -s "$ARGS_FILE" ] || fail "a refused call must never reach tasks-axi: $(cat "$ARGS_FILE")"
  pass "a tasks-axi call without an explicit backlog path is refused before it runs"
}

test_flag_present_but_valueless_is_refused() {
  local status
  : > "$ARGS_FILE"
  run_wrapper list --file >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a --file with no path must be refused"
  [ ! -s "$ARGS_FILE" ] || fail "a valueless --file must never reach tasks-axi"

  : > "$ARGS_FILE"
  run_wrapper list --file= >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "an empty --file= must be refused"
  [ ! -s "$ARGS_FILE" ] || fail "an empty --file= must never reach tasks-axi"
  pass "a --file that names no path is refused like an absent one"
}

test_explicit_path_reaches_tasks_axi() {
  local backlog out
  backlog="$TMP_ROOT/data/backlog.md"
  mkdir -p "$(dirname "$backlog")"

  : > "$ARGS_FILE"
  out=$(run_wrapper list --file "$backlog")
  assert_contains "$out" "reached-tasks-axi" "an explicit path must reach tasks-axi"
  assert_contains "$(cat "$ARGS_FILE")" "--file $backlog" "the path must be passed through unchanged"

  : > "$ARGS_FILE"
  out=$(run_wrapper list "--file=$backlog")
  assert_contains "$out" "reached-tasks-axi" "the --file=<path> spelling must also pass"
  assert_contains "$(cat "$ARGS_FILE")" "--file=$backlog" "the joined spelling must be passed through unchanged"
  pass "both --file spellings pass the call through with its path intact"
}

test_call_without_explicit_path_is_refused
test_flag_present_but_valueless_is_refused
test_explicit_path_reaches_tasks_axi

echo "# all fm-tasks-axi-lib tests passed"
