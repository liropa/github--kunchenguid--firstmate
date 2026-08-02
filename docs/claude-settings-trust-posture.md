# Claude project-settings trust posture

Branch-carried claude project settings load in a host pool worktree under the primary checkout's repo-root trust grant, with no prompt of any kind.
That includes command-executing `PreToolUse` hooks.
This document records that the fleet accepts that deliberately, the evidence it rests on, and the one claim in the area that is still unverified.

`.agents/skills/harness-adapters/SKILL.md`'s claude section owns the operative dispatch rule (which gates fire where, and how many supervised keypresses to budget).
`docs/sbx-backend.md`'s "Guest claude workspace trust" owns the guest clone case and the grant shape firstmate does seed.
This document owns only the posture: what executes without being chosen, why that is accepted, and what would change the answer.

## Scope

**Claude Code v2.1.220, host/tmux path, measured 2026-08-02.**
Everything below is a reading of that one version on that one launch path.
The sbx guest path was not re-probed in that run, so nothing here extends to it.
Treat the whole document as version-pinned rather than as a standing property of claude, and re-measure before carrying it forward.

Full probe transcripts are in the scout report `data/claude-trust-prompt-scope-reconcile/report.md` (firstmate-private).

## What was measured

- A never-individually-trusted treehouse pool worktree of this repo loaded its branch-carried `[Project]` settings with **no prompt**, under the repo-root grant.
  Claude's own `/hooks` view showed 5 hooks configured for that worktree, 3 of them `PreToolUse`, labelled `[Project]`.
- `/Users/lp1/.claude.json` held 3 project keys and **no** per-worktree keys, despite heavy pool use.
- The only trust field present anywhere in that file is `hasTrustDialogAccepted`.
  There is no separate settings-trust field and no settings-hash field in v2.1.220, so there is nothing for a per-worktree grant to key on even if one were wanted.
- A linked worktree's `git-common-dir` resolves to the primary checkout's `.git`, which is why a single grant on the primary covers every pool worktree of that repo.

Two controls make the null result real rather than a broken rig: an independent git root under the same ancestor tree still prompted, and `--dangerously-skip-permissions` did not suppress the prompt where the prompt does fire.
So the silence is git-root canonicalization, not ancestor inheritance and not the bypass flag.

## The accepted posture

The captain reviewed this and accepted it.
Branch-carried settings execute under the repo-root grant; firstmate adds no per-worktree guard, and the recorded rationale is below.

### This is an attribution problem, not privilege escalation

Workers already launch with permissions bypassed.
A branch-carried hook therefore grants a worker no capability it did not already have.
What changes is **who decides**: code in the branch acts without the agent choosing to run it.
State that distinction precisely whenever this comes up again, because it is the whole basis of the acceptance.
A finding that reframes this as privilege escalation is describing a different thing and should be checked against this paragraph before it is acted on.

### The realistic vector is upstream inflow, not this fleet's own branches

This fleet's branches are written by its own crewmates against briefs firstmate wrote.
This repo is a fork, and upstream commits are merged in, so the realistic way hostile settings would arrive is that inflow.
That path already passes a security review at sync time, which is where the protection actually sits.

### The documentation gap was the more important defect

Before this record existed, the guidance implied a per-worktree guard existed where none fires.
Operating as if a prompt were guarding branch-controlled settings, when no prompt is raised, is worse than knowing the settings load and deciding to accept it.
Closing that gap was judged the higher-value fix, and this document is it.

## What did not change

Firstmate still refuses to pre-seed a per-worktree project-settings trust key.
That refusal is the boundary working, not a gap: the settings file is controlled by the branch the agent was sent to work on, so granting the key would make the agent adopt permissions, hooks, and MCP servers carried by the code under review.
`.agents/skills/harness-adapters/SKILL.md` and `docs/sbx-backend.md` own that rationale in full.
Accepting the host posture is not a reason to revisit the refusal, and a future reader should not close one by weakening the other.

No trust grant and no launch flag changed as a result of this record.

## Unverified: the no-mistakes gate worktree

The reviewer-side protection is the case worth keeping honest, and it is the one claim here that is **not** measured end to end.

**Measured (firstmate, 2026-08-02):** a no-mistakes gate worktree is a linked worktree whose `git-common-dir` is a **separate bare repo** under `~/.no-mistakes/repos/<id>.git`, not the primary checkout.
Those bare repos are independently observable on this host and report `is-bare-repository = true`; no per-run worktree was checked out at the time of writing, so the live linked-worktree reading was not re-observed here.

**Inferred, not measured:** because that common dir is a different repository, the primary's grant does not extend to a gate worktree, so the deliberate protection for the reviewer *appears* intact.

The investigation never triggered a distinct project-settings dialog at all - every dialog it raised was the workspace one.
So whether a separate project-settings gate exists downstream, and what it does in a gate worktree, is unestablished.
Record it at exactly this strength: topology measured, resulting gate behaviour inferred and unverified.
Do not cite it as a fact, and do not let it stand in for a probe.

**Verification outstanding.**
Settling it needs a launch inside a live gate worktree, observed and then killed without accepting any dialog, because accepting one would write the durable grant this posture refuses to seed.
Whoever runs it should record what they actually observed and replace this section; an evidence line that did not come from an observed run does not belong here.

## Dispatch-time detection

Firstmate reports, at spawn, when the branch a worker is dispatched to carries a committed `.claude/settings.json` that differs from the default branch's.
It is detection only: the difference is reported and the dispatch proceeds.
It is silent when there is no difference, and it alters no trust grant and no launch flag.
`bin/fm-spawn.sh`'s header and `report_settings_drift` own the exact mechanics.

This is deliberately not a gate.
Given the posture above, a blocking check would stop ordinary work for a condition the fleet has decided to accept, and a line printed on every ordinary spawn would be filtered out by its readers within a week.
Visibility at the moment of dispatch is the whole product.

## Re-verify when

- Claude Code moves off v2.1.220, especially if its release notes touch trust, project settings, or hook loading.
- A settings-trust or settings-hash field appears in `~/.claude.json` alongside `hasTrustDialogAccepted`.
- The sbx guest path is re-probed, which would let the guest half stop resting on `docs/sbx-backend.md`'s earlier evidence.
- A real probe settles the gate-worktree section above.
