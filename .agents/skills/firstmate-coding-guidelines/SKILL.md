---
name: firstmate-coding-guidelines
description: >-
  Agent-only reference for changing firstmate's shared, tracked material per AGENTS.md section 1.
  Use before editing any of that material, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
  Covers the knowledge-placement decision tree, the one-owner rule for contracts, the fm-authority marker for content the no-mistakes document step cannot justify from the diff, the inline-stub pattern for content moved into a skill, AGENTS.md size discipline, trigger hygiene for new skills, and repo style rules (one sentence per line, plain dash, no agent co-author, shellcheck-clean bin scripts, colocated tests, and backend-verification evidence).
user-invocable: false
metadata:
  internal: true
---

# firstmate-coding-guidelines

Load this before changing firstmate's shared, tracked material, as defined by `AGENTS.md` section 1.
It exists because `AGENTS.md` grew from 585 to 958 lines between its last two restructures, entirely from conditional detail added inline instead of routed to its right home.
Applying the rules below on every change is what keeps that from happening again.

## Knowledge-placement decision tree

Before writing a new fact anywhere in this repo, ask where it belongs, in this order.

1. Does the firstmate AGENT need this on every session or every turn to operate?
   If yes: `AGENTS.md`, inline.
2. Does the agent need it only in a nameable situation - a spawn, a recovery, a specific wake type, a specific lifecycle step?
   If yes: an agent-only skill under `.agents/skills/`, plus a one-line trigger pointer left inline in `AGENTS.md` (usually section 13).
3. Is it human/reference detail - a wire format, a verification record, a mechanism narrative, an incident writeup?
   If yes: `docs/`.
4. Is it mechanics - exact flags, exact commands, exact paths?
   If yes: the script's own header comment plus its `--help` output, not prose in `AGENTS.md` or a skill.

Stop at the first tier that answers yes.
Do not place a fact at a more convenient tier than the one this tree gives you.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly once.
Every other mention of it is a one-line cross-reference, never a restatement.
A single deliberate one-line reinforcement at a genuine risk point is allowed, for example a "don't forget X" placed exactly where forgetting X is costly.
Restating the contract's substance a second time is not allowed: the two copies will drift the moment only one is edited.
When you touch a contract, grep the repo for its other mentions and update the cross-references, not duplicate the change into a second full copy.

## Marking content the gate cannot justify from the diff

The no-mistakes document step polices duplication correctly but cannot see authority.
Content whose justification is external to the diff reads to it as unsupported duplication, so it removes exactly the material that most needs keeping: on PR 69 it deleted a live host observation firstmate had instructed the worker to record and replaced it with the opposite claim, and on PR 70 it deleted a one-line reinforcement the captain had approved minutes earlier together with the note recording that the captain chose it deliberately.
Both runs went green afterwards, so passing checks are not a defense here.

Mark such content so the step can recognize it:

```markdown
<!-- fm-authority: captain-decision <date> - <reason> -->
The single line the captain approved.

<!-- fm-authority: firstmate-observation <date> - <reason> -->
A passage recording something observed outside this checkout.
<!-- /fm-authority -->
```

A bare marker protects the one line that follows it; a marker closed by `<!-- /fm-authority -->` protects everything between the two.
Use `captain-decision` for a decision the captain already made, and `firstmate-observation` for a live reading the gate agent cannot reproduce from inside its own checkout.

Mark only content that genuinely has no support in the diff.
The marker is not a way to exempt ordinary prose from review: unmarked duplication is still removed, and a marked passage can still come back as a finding for the captain to judge.
`.no-mistakes.yaml`'s `document.instructions` is the operative copy the gate reads, and it takes effect only from the default branch, so a new marker protects nothing until the change carrying it lands on main.

## Inline-stub pattern

When content moves out of `AGENTS.md` into a skill, decide what stays behind by asking one question: what must survive with no skill loaded?
That is the trigger condition for loading the skill, plus any safety-critical fact that fires on a wake the skill itself is not loaded for.
Everything else - the procedure, the mechanism, the surrounding detail - moves out completely.
Do not leave a partial restatement behind "just in case".
A partial copy is exactly the duplication the one-owner rule forbids.
The model to copy is `AGENTS.md` section 8's "Away-mode stub": it keeps only the marker format, the ownership-transfer rule, and the exit condition inline, and points everything else at the `/afk` skill.

## Size discipline

Apply the decision tree above to every line you are about to add to `AGENTS.md`.
If an addition needs more than a few lines of conditional detail (detail that matters only in a specific situation) or reference detail (a wire format, an exact schema, historical rationale), you are almost certainly adding it to the wrong file.
`AGENTS.md`'s token cost is paid by every session of every fleet member, every time, whether or not that session ever hits the situation the new lines describe.
A skill's cost is paid only by the sessions that actually load it.
When in doubt, write the fact into the skill or doc first, and add only the one-line trigger to `AGENTS.md`.

## Trigger hygiene

A new skill is dead weight if nothing loads it.
Every new skill needs its load trigger declared inline: section 13 for agent-only reference skills, or the relevant operating section for anything else.
State the trigger as a condition ("load before X", "load on Y wake"), never as a vague pointer.
Briefs for tasks that touch firstmate's own tracked material should tell the crewmate to load this skill.
`bin/fm-brief.sh`'s `REPO` argument is a caller-supplied string with no reliable signal that it names firstmate's own repo, unlike a project registered in `data/projects.md`, so there is no clean point inside the scaffold to detect this case automatically.
Firstmate adds this skill's load instruction to firstmate-repo briefs by hand instead.
`CONTRIBUTING.md`'s "Development" section carries the same instruction as a durable reminder.

## Compatibility and enforcement

Before changing shared tracked behavior, review every affected supported primary harness and runtime backend rather than checking only the adapters active in the current fleet.
Mark an axis not applicable only after inspecting its integration surface, and update the corresponding verification evidence when behavior changes.

For critical safety, routing, startup, and supervision infrastructure, prefer deterministic and idempotent enforcement over relying on agent memory alone.
Keep instructions as the authority and discovery layer, but make repeated execution converge safely and make invalid or unsafe states fail closed wherever the runtime can enforce them.

## Repo style rules

- Put one full sentence per line in tracked Markdown.
- Never wrap multiple sentences onto one physical line.
- Plain dash `-`, never an em dash.
- Never add an agent name as a commit co-author.
- `bin/*.sh` and `bin/backends/*.sh` must pass `shellcheck`.
- Run `bin/fm-lint.sh` before treating a script change as done; it is the single owner of the lint definition (file set, config, and pinned shellcheck version) that CI and the no-mistakes pre-push gate both invoke, and it refuses to run under any other shellcheck version.
- Colocate tests with the existing pattern in `tests/`, name them `<subject>.test.sh`, and extend an existing script rather than inventing a new runner.
- A backend-verification doc (`docs/*-backend.md`) records empirical facts, not assumptions.
- Include the date, version, exact commands run, and exact output.
- Write incidents the same way, as evidence, not narrative alone.
