#!/usr/bin/env bash
# Static regression tests for the response and commit-subject contracts owned
# by AGENTS.md's opening block and section 9.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
GUIDELINES="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"

section_9() {
  awk '
    /^## 9\. Escalation and captain etiquette$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

identity_block() {
  awk '
    /^## 1\. Identity and prime directives$/ { exit }
    { print }
  ' "$AGENTS"
}

test_section_9_owns_positive_translation_contract() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Every captain-facing message must translate internal state into the project outcome, consequence, and next decision." \
    "section 9 does not own the positive captain-facing translation contract"
  assert_contains "$contract" "Use the captain's nouns:" \
    "section 9 does not require captain-owned nouns"
  assert_contains "$contract" "When evidence uses an internal label, rewrite it before sending:" \
    "section 9 does not own the rewrite mapping list"
  pass "section 9 owns the positive captain-facing translation contract"
}

test_scout_remains_allowed_house_vocabulary() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation" \
    "section 9 does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$contract" "scout -> investigation" \
    "section 9 must not map scout to investigation"
  assert_not_contains "$contract" "scout, ship" \
    "section 9 must not add scout to the internal-vocabulary ban"
  assert_not_contains "$contract" "secondmate -> domain supervisor" \
    "section 9 must not map secondmate to domain supervisor"
  pass "scout remains allowed in private captain chat"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(section_9)
  for phrase in \
    "fail-closed" \
    "fails closed" \
    "fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "section 9 does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside and lets work continue when the check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(section_9)
  for phrase in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contract" "$phrase" "section 9 mapping list is missing '$phrase'"
  done
  pass "section 9 maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into captain chat." \
    "section 9 does not reject verbatim internal evidence in captain chat"
  assert_contains "$contract" "Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms" \
    "section 9 does not preserve private evidence precision"
  assert_contains "$contract" "the captain-facing chat summary that points to the report still follows this translation rule" \
    "section 9 does not keep chat summaries plain English"
  pass "captain chat rejects verbatim internal evidence while private reports stay precise"
}

test_outward_facing_skill_points_reference_section_9_owner() {
  assert_grep "using \`AGENTS.md\` section 9's captain-facing translation contract" "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference section 9 at captain handoff"
  assert_grep "Acknowledge** in \`AGENTS.md\` section 9 language" "$AFK" \
    "afk acknowledgement does not reference section 9"
  assert_grep "Captain, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "as decisions from Bearings' Captain's Call section under \`AGENTS.md\` section 9" "$DECISION" \
    "decision relay does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9; do not mention metadata, harness, window, or worktree" "$RECOVERY" \
    "stuck-worker failure does not reference section 9"
  assert_grep "under \`AGENTS.md\` section 9 that the requested worker runtime is not verified yet" "$HARNESS" \
    "runtime fallback does not reference section 9"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep "translate status prefixes and return-channel evidence through \`AGENTS.md\` section 9" "$CODEXAPP" \
    "Codex Desktop result reporting does not reference section 9"
  assert_grep "It supplements \`AGENTS.md\` section 9; apply both, and this public-channel rule wins wherever it is stricter." "$FMX" \
    "X reply safety does not state that it supplements section 9"
  assert_grep "under \`AGENTS.md\` section 9 without firstmate's internal vocabulary" "$UPDATE" \
    "Firstmate update reporting does not reference section 9"
  pass "outward-facing skill handoffs point to the section 9 owner"
}

test_section_9_owner_is_not_duplicated_into_skills() {
  local duplicate_count file
  duplicate_count=0
  for file in "$BOOTSTRAP" "$AFK" "$DECISION" "$RECOVERY" "$HARNESS" "$CODEXAPP" "$UPDATE"; do
    if grep -Fq "When evidence uses an internal label, rewrite it before sending:" "$file"; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done
  [ "$duplicate_count" -eq 0 ] || fail "skills duplicated section 9's mapping owner"
  pass "skills cross-reference section 9 instead of duplicating the mapping list"
}

test_captain_address_is_scoped_to_the_primary_session() {
  local block
  block=$(identity_block)
  assert_contains "$block" "every response you send the captain from this primary firstmate session" \
    "the captain address is not scoped to the primary firstmate session"
  assert_contains "$block" "any other agent that reads this file" \
    "the captain address is not withheld from every other reader of this file"
  assert_contains "$block" "inherits no captain address from it" \
    "the captain address does not state what other readers inherit"
  assert_contains "$block" "a no-mistakes pipeline agent" \
    "the captain address does not name the pipeline agent among the excluded readers"
  assert_not_contains "$block" 'Address the user as "captain" at least once in every response.' \
    "the captain address is still stated without a session scope"
  pass "the captain address is scoped to the primary firstmate session"
}

test_commit_subjects_reject_address_seasoning_and_narration() {
  local block
  block=$(identity_block)
  assert_contains "$block" "never use the address or the seasoning in commits, briefs, PRs, or anything crewmates or other tools read" \
    "the commit exclusion still covers only the nautical seasoning"
  assert_contains "$block" "Every commit subject in this repo follows Conventional Commits, whoever writes it" \
    "AGENTS.md does not own the commit-subject rule for every writer"
  for phrase in \
    "no captain address" \
    "no nautical seasoning" \
    "no narration of the work done"; do
    assert_contains "$block" "$phrase" "the commit-subject rule is missing '$phrase'"
  done
  pass "commit subjects reject the captain address, seasoning, and narration"
}

test_commit_subject_owner_is_cross_referenced_not_duplicated() {
  local phrase
  assert_grep "- Commit subjects follow the rule in \`AGENTS.md\`'s opening block." "$GUIDELINES" \
    "the coding-guidelines skill does not cross-reference the commit-subject owner"
  for phrase in \
    "Conventional Commits" \
    "captain address" \
    "nautical seasoning" \
    "narration"; do
    assert_no_grep "$phrase" "$GUIDELINES" \
      "the coding-guidelines skill duplicates the commit-subject owner with '$phrase'"
  done
  pass "the commit-subject rule is cross-referenced, not duplicated"
}

test_section_9_owns_positive_translation_contract
test_captain_address_is_scoped_to_the_primary_session
test_commit_subjects_reject_address_seasoning_and_narration
test_commit_subject_owner_is_cross_referenced_not_duplicated
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_outward_facing_skill_points_reference_section_9_owner
test_section_9_owner_is_not_duplicated_into_skills
