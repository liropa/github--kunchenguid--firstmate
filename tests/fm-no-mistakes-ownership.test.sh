#!/usr/bin/env bash
# Static contract tests for crew-owned no-mistakes validation runs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

validate_contract() {
  awk '
    /^### Validate$/ { found = 1; next }
    found && /^### / { exit }
    found { print }
  ' "$ROOT/AGENTS.md"
}

test_worker_owns_synchronous_driver() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" 'The task worker that starts a no-mistakes run drives the pipeline' \
    "Validate contract does not assign the run to its initiating task worker"
  assert_contains "$contract" "owns every \`no-mistakes axi run\` and \`no-mistakes axi respond\` call through the next gate or outcome" \
    "Validate contract does not assign every synchronous driver call to the task worker"
  assert_contains "$contract" 'process every synchronous return until completion or a genuinely new escalation' \
    "Validate contract does not require the task worker to process every synchronous return"
  pass "Validate contract assigns the complete synchronous driver loop to the initiating task worker"
}

test_firstmate_never_responds_for_crew_run() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" "Firstmate never invokes \`no-mistakes axi respond\` for a crew-owned run." \
    "Validate contract permits Firstmate to respond directly for a crew-owned run"
  pass "Validate contract forbids Firstmate from responding directly for a crew-owned run"
}

# The trusted document.instructions block, as no-mistakes reads it: the value of
# the `instructions: |` literal scalar under the top-level `document:` key.
document_instructions() {
  awk '
    /^document:$/ { in_doc = 1; next }
    in_doc && /^[a-z_]+:/ { exit }
    in_doc && /^  instructions: \|$/ { in_block = 1; next }
    in_block && /^ {0,3}[^ ]/ { exit }
    in_block { print }
  ' "$ROOT/.no-mistakes.yaml"
}

# Files that may carry authority markers. Tracked Markdown only - the marker is a
# Markdown comment, and scanning the whole tree would sweep gitignored clones.
marked_files() {
  git -C "$ROOT" ls-files -- '*.md' | sed "s|^|$ROOT/|"
}

test_document_instructions_protect_external_authority() {
  local instructions
  instructions=$(document_instructions)

  [ -n "$instructions" ] || fail ".no-mistakes.yaml declares no document.instructions, so the document step gets no authority rules"

  assert_contains "$instructions" 'fm-authority: captain-decision' \
    "document.instructions does not declare the captain-decision marker"
  assert_contains "$instructions" 'fm-authority: firstmate-observation' \
    "document.instructions does not declare the firstmate-observation marker"
  assert_contains "$instructions" '<!-- /fm-authority -->' \
    "document.instructions does not declare the closing marker, so multi-line passages have no scope"
  assert_contains "$instructions" 'Do not delete, weaken, or rewrite protected content' \
    "document.instructions does not forbid deleting protected content"
  assert_contains "$instructions" 'report one finding' \
    "document.instructions does not route a disputed protected passage to a finding instead of a deletion"
  pass "document.instructions gives the document step the authority signal it cannot infer from a diff"
}

test_document_instructions_keep_duplication_policing() {
  local instructions
  instructions=$(document_instructions)

  # The knob must never become a blanket exemption: no-mistakes appends these
  # rules to its own placement policy and permits narrowing it, never weakening
  # it, so the instructions have to keep saying that duplication still goes.
  assert_contains "$instructions" 'An unmarked duplicate is still a duplicate.' \
    "document.instructions no longer preserves ordinary duplicate removal"
  assert_contains "$instructions" 'never a whole file' \
    "document.instructions lets a marker exempt a whole file rather than a bounded passage"
  pass "document.instructions adds a protected class without weakening duplication policing"
}

# A bare marker is a valid single-line scope, so an opening marker with no
# closer is indistinguishable from an unclosed block and cannot be checked here.
# What is checkable is that every marker names a kind the gate rules declare, a
# date, and a reason - a typo in the kind would silently leave content unguarded.
test_authority_markers_are_well_formed() {
  local file line kind bad_kind="" malformed="" seen=0

  while IFS= read -r file; do
    local fenced=0
    while IFS= read -r line; do
      # A marker inside a fenced block is an illustration of the convention, not
      # a live marker, so the scan must not hold it to the real-marker shape.
      case "$line" in
        '```'*)
          fenced=$((1 - fenced))
          continue
          ;;
      esac
      [ "$fenced" -eq 0 ] || continue
      case "$line" in
        *'<!-- fm-authority:'*) : ;;
        *) continue ;;
      esac
      seen=$((seen + 1))
      kind=$(printf '%s\n' "$line" | sed -n 's/.*<!-- fm-authority: \([a-z-]*\) .*/\1/p')
      case "$kind" in
        captain-decision | firstmate-observation) : ;;
        *) bad_kind="$bad_kind$file: $line"$'\n' ;;
      esac
      printf '%s\n' "$line" | grep -Eq '<!-- fm-authority: [a-z-]+ [0-9]{4}-[0-9]{2}-[0-9]{2} - .+ -->' ||
        malformed="$malformed$file: $line"$'\n'
    done <"$file"
  done < <(marked_files)

  [ "$seen" -gt 0 ] || fail "no authority markers found in tracked Markdown, so the convention is declared but unused"
  [ -z "$bad_kind" ] || fail "authority markers use a kind the gate rules do not declare:"$'\n'"$bad_kind"
  [ -z "$malformed" ] || fail "authority markers are missing a YYYY-MM-DD date or a reason:"$'\n'"$malformed"
  pass "every authority marker names a declared kind, a date, and a reason"
}

test_twice_deleted_content_is_marked() {
  local skill="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"
  local doc="$ROOT/docs/sbx-backend.md"
  local skill_content_lines skill_content_line doc_content_lines doc_content_line
  local observation_content_lines observation_content_line observation_end_lines observation_end_line

  # PR 70: the captain-approved reinforcement line, and the note recording that
  # the captain chose it deliberately. The document step deleted both.
  skill_content_lines=$(grep -nF 'A mid-session `data/captain-shared.md` push takes effect' "$skill" | cut -d: -f1)
  [ "$(printf '%s\n' "$skill_content_lines" | grep -c .)" -eq 1 ] ||
    fail "the captain-approved timing line in secondmate-provisioning is missing or no longer unique"
  skill_content_line=$skill_content_lines
  assert_contains "$(sed -n "$((skill_content_line - 1))p" "$skill")" 'fm-authority: captain-decision' \
    "the captain-approved timing line in secondmate-provisioning carries no adjacent authority marker"

  doc_content_lines=$(grep -nF "By the captain's 2026-08-09 decision" "$doc" | cut -d: -f1)
  [ "$(printf '%s\n' "$doc_content_lines" | grep -c .)" -eq 1 ] ||
    fail "the note recording the captain's skill-one-owner decision is missing or no longer unique"
  doc_content_line=$doc_content_lines
  assert_contains "$(sed -n "$((doc_content_line - 1))p" "$doc")" 'fm-authority: captain-decision' \
    "the note recording the captain's skill-one-owner decision carries no adjacent authority marker"

  # PR 69: the live host observation the document step replaced with its opposite.
  observation_content_lines=$(grep -nF '**What firstmate observed on the host**' "$doc" | cut -d: -f1)
  [ "$(printf '%s\n' "$observation_content_lines" | grep -c .)" -eq 1 ] ||
    fail "firstmate's live host observation start is missing or no longer unique"
  observation_content_line=$observation_content_lines
  assert_contains "$(sed -n "$((observation_content_line - 1))p" "$doc")" 'fm-authority: firstmate-observation' \
    "firstmate's live host observation carries no adjacent authority marker"

  observation_end_lines=$(grep -nF 'its coverage is the hermetic suites alone.' "$doc" | cut -d: -f1)
  [ "$(printf '%s\n' "$observation_end_lines" | grep -c .)" -eq 1 ] ||
    fail "firstmate's live host observation end is missing or no longer unique"
  observation_end_line=$observation_end_lines
  [ "$observation_content_line" -lt "$observation_end_line" ] ||
    fail "firstmate's live host observation boundaries are out of order"
  [ "$(sed -n "$((observation_end_line + 1))p" "$doc")" = '<!-- /fm-authority -->' ] ||
    fail "the multi-line host observation is not closed immediately after its protected content"
  pass "both twice-deleted passages carry the marker that would have protected them"
}

test_marker_convention_is_documented_for_authors() {
  local skill="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"

  assert_grep 'fm-authority: captain-decision' "$skill" \
    "firstmate-coding-guidelines does not show authors the captain-decision marker"
  assert_grep 'fm-authority: firstmate-observation' "$skill" \
    "firstmate-coding-guidelines does not show authors the firstmate-observation marker"
  assert_grep 'default branch' "$skill" \
    "firstmate-coding-guidelines does not warn that a marker is inert until the change lands on the default branch"
  pass "the authoring convention is documented where an author is already required to look"
}

test_worker_owns_synchronous_driver
test_firstmate_never_responds_for_crew_run
test_document_instructions_protect_external_authority
test_document_instructions_keep_duplication_policing
test_authority_markers_are_well_formed
test_twice_deleted_content_is_marked
test_marker_convention_is_documented_for_authors
