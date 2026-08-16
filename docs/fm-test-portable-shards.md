# Firstmate portable test shards (Phase 4)

This document records how the two portable parallel CI shards were balanced from measured evidence.
Composition and execution are owned by `bin/fm-test-run.sh` (`--lane portable-parallel-1` / `portable-parallel-2` / `portable-serial` / `portable-serial-1` / `portable-serial-2`).
The proven-isolated candidate set remains owned by `bin/fm-test-isolation-proof.sh`.

## Inputs

| Input | Owner / source |
|---|---|
| Proven-isolated set (30 scripts) | `bin/fm-test-isolation-proof.sh --list` and `docs/fm-test-isolation-proof.md` |
| Phase 1 serial durations | CI timing artifacts `fm-test-timing` from main after #825 / #832 / #834 |
| Real-Herdr family | `bin/fm-test-run.sh --family real-herdr-gated` (dedicated required CI lane) |

Phase 1 averages used for balance (mean of available serial `duration_ms` across those artifacts):

| duration_ms (avg) | script |
|---:|---|
| 29639 | `tests/fm-arm-pretool-check.test.sh` |
| 25402 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19428 | `tests/fm-x-mode.test.sh` |
| 14979 | `tests/fm-cd-pretool-check.test.sh` |
| 9339 | `tests/fm-backend-herdr.test.sh` |
| 6885 | `tests/fm-herdr-lab.test.sh` |
| 5127 | `tests/fm-crew-state.test.sh` |
| 4044 | `tests/fm-pr-merge.test.sh` |
| 3922 | `tests/fm-grok-harness.test.sh` |
| 2492 | `tests/fm-test-run.test.sh` |
| 1901 | `tests/fm-send-popup-settle.test.sh` |
| 1234 | `tests/fm-spawn-batch.test.sh` |
| 851 | `tests/fm-send-strict.test.sh` |
| 791 | `tests/fm-review-diff.test.sh` |
| 627 | `tests/fm-tmux-submit-busy.test.sh` |
| 525 | `tests/fm-brief.test.sh` |
| 321 | `tests/fm-composer-ghost.test.sh` |
| 283 | `tests/fm-dispatch-select.test.sh` |
| 276 | `tests/fm-send-settle.test.sh` |
| 189 | `tests/fm-ensure-agents-md.test.sh` |
| 175 | `tests/fm-supervision-instructions.test.sh` |
| 138 | `tests/fm-instruction-owners.test.sh` |
| 133 | `tests/fm-lint.test.sh` |
| 108 | `tests/fm-pi-primary-types.test.sh` |
| 106 | `tests/fm-nm-test-contract.test.sh` |
| 67 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-captain-translation-contract.test.sh` |
| 48 | `tests/fm-composer-lib.test.sh` |
| 36 | `tests/fm-stow-contract.test.sh` |
| 28 | `tests/fm-no-mistakes-ownership.test.sh` |

## Balancing method

Longest-processing-time (LPT) assignment onto two workers using the Phase 1 averages above.
Do not rebalance alphabetically or by family intuition.
Shard execution order is longest-first so wall-clock tracks the balanced sum.

| Lane | Script count | Sum of Phase 1 averages |
|---|---:|---:|
| `portable-parallel-1` | 15 | 64579 ms (~64.6 s) |
| `portable-parallel-2` | 15 | 64579 ms (~64.6 s) |
| imbalance | | 0 ms |

Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_parallel_1` / `list_portable_parallel_2`).

## Portable serial remainder

`portable-serial` is every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
That keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in (default skip), GUI backends, and other stateful or unproven work serial.
The remainder stays complement-derived, so a newly added stateful test is covered without editing a membership list.

CI runs the remainder as two jobs, `portable-serial-1` and `portable-serial-2`, on two separate runners.

## Splitting the serial remainder across two runners

### Why the split was needed

<!-- fm-authority: firstmate-observation 2026-08-16 - every duration and job wall in this subsection was read from GitHub Actions artifacts and job timings for the named runs; none of it can be reproduced from inside a checkout -->

The remainder had grown into its own cap.
Per-script `duration_ms` sums from the `fm-test-timing-portable-serial` artifact of five `main` runs:

| Run | Head | Serial script sum |
|---|---|---:|
| 31521549528 | `0769882` | 1045998 ms (17m26s) |
| 31532671143 | `8912a22` | 1079957 ms (18m00s) |
| 31819434635 | `aef27dc` | 1093186 ms (18m13s) |
| 31855604632 | `49f8d40` | 1102902 ms (18m23s) |
| 31902522552 | `c1b65de` | 1183467 ms (19m43s) |

On `c1b65de` the job wall was **19m52s** against the 20-minute cap, leaving **8 seconds**.
A tripwire that close to the healthy wall can no longer tell a hang from a healthy run.
The largest single step came from commit `646f6a8`, which replaced `tests/fm-spawn-worktree-settle.test.sh` (4609 ms mean) with `tests/fm-spawn-launch-delivery.test.sh` (179908 ms).

<!-- /fm-authority -->

### Why splitting is not a concurrency change

Two GitHub-hosted runners are separate virtual machines with separate filesystems, process tables, temporary directories, and tmux servers.
Each half still runs one script at a time.
No script in the remainder gains a concurrent neighbour, so no test's isolation properties are relied on and none had to be re-proven.
Only the machine boundary moves.
This is the reason the split was preferred over promoting stateful tests into the parallel shards, which would have traded a slow job for a flaky one.

Both halves therefore need the identical tool setup (pinned ShellCheck, tmux, `tasks-axi`), because either half may hold the test that needs it.
`.github/workflows/ci.yml` keeps the two step lists identical and `tests/fm-test-run.test.sh` asserts that neither half loses a setup step.

### Membership and balance

`list_portable_serial_1` in `bin/fm-test-run.sh` is an explicit six-script list: the five heaviest scripts in the remainder plus one smaller script that closes the gap.
Half 2 is the rest of the remainder.
Only the head is listed so that new tests keep landing in a serial lane by complement, exactly as before the split.

<!-- fm-authority: firstmate-observation 2026-08-16 - the three tables below are arithmetic over per-script duration_ms read from the CI timing artifacts of the named runs, which a gate checkout cannot re-measure -->

Half 1 membership, with the means used to size it:

| duration_ms (mean of 5) | script |
|---:|---|
| 179908 | `tests/fm-spawn-launch-delivery.test.sh` |
| 178736 | `tests/fm-pr-check-security.test.sh` |
| 105457 | `tests/fm-watcher-lock.test.sh` |
| 95985 | `tests/fm-watch-triage.test.sh` |
| 46063 | `tests/fm-bearings-snapshot.test.sh` |
| 14091 | `tests/fm-backend.test.sh` |

Only `tests/fm-spawn-launch-delivery.test.sh` has a single sample, because it first ran on `c1b65de`.
Balance basis is the mean per-script `duration_ms` across the same five runs:

| Lane | Script count | Sum of means |
|---|---:|---:|
| `portable-serial-1` | 6 | 620240 ms |
| `portable-serial-2` | 61 | 621101 ms |
| imbalance | | 861 ms |

Projected onto the current inventory using the `c1b65de` durations alone:

| Lane | Measured on `c1b65de` |
|---|---:|
| whole remainder (before) | 1183467 ms (19m43s) |
| `portable-serial-1` | 603200 ms (10m03s) |
| `portable-serial-2` | 580267 ms (9m40s) |
| serial critical path (after) | 603200 ms (10m03s) |

That is a **49% reduction** in the serial critical path, and it restores about **10 minutes** of headroom under the unchanged 20-minute cap, roughly twice the healthy wall.
The figures above are re-partitions of measured per-script durations, not a new wall-clock reading; the first CI run of the split lanes is the observed confirmation.

<!-- /fm-authority -->

### Confidence beyond one green run

Splitting the remainder changes which tests share a runner, so a test that had passed only because an earlier test in the lane left state behind would newly fail.
One green CI run would not distinguish that from luck, so each half was also run alone before the split shipped.

Half 1 is the load-bearing case.
It is the smaller set, so its six scripts now start with none of the other 61 having run first, which is the largest change in predecessor state anywhere in this split.
Half 2 keeps 61 of the 67 scripts in their original relative order and loses only six predecessors.

<!-- fm-authority: firstmate-observation 2026-08-16 - both runs were executed on the captain's own macOS host with real tmux, outside any checkout a gate agent can reach; local walls are slower than a GitHub runner and are evidence of pass or fail, not of CI duration -->

| Isolated local run | Scripts attempted | Completed | Failed | Local wall |
|---|---:|---:|---:|---:|
| `--lane portable-serial-1` | 6 | 6 | 0 | 836179 ms (13m56s) |
| `--lane portable-serial-2` | 61 | 19 | 1 | stopped, see below |

Half 1 passed completely and is the evidence that matters most.

The half 2 local run could not finish on that host, for a reason specific to the host rather than to the split.
`tests/fm-daemon.test.sh` reaches the real `herdr` binary when one is installed, starts a server, and wedges; it ran for over ten hours before the run was stopped.
CI does not hit this: `bin/fm-install-herdr.sh` runs only in the `tests-herdr` job, so `herdr` is absent from `PATH` in both serial halves and the same test finishes in about 44 seconds there.
The one failure in the 19 completed scripts, `tests/fm-backend-orca.test.sh` (`Orca spawn should fail when metadata cannot be written`), reproduces identically on the unmodified base commit and is likewise a host difference, not a consequence of the split.
Half 2's confirmation therefore comes from CI rather than from a local wall.

Running a serial lane locally on a host with `herdr` installed drives real Herdr lifecycle behavior.
Scaffold such a task's brief with `bin/fm-brief.sh --herdr-lab`, or run only `--lane portable-serial-1`, which contains no test that reaches the real binary.

<!-- /fm-authority -->

### Rebalance trigger

Growth accrues to half 2, because new tests land there by complement.
Rebalance membership when either half passes about **12 minutes** of script time in the timing artifacts, by moving scripts between the head list and the complement using fresh `duration_ms` records.
Do not raise `timeout-minutes` instead.
Raising the cap deletes the tripwire's meaning, and the next real hang would run to the new ceiling before anything noticed.

If a further cut is ever needed, the parallel shards still finish in about a minute against a 10-minute cap and have room to absorb work, but moving any remainder script there first requires a new concurrent isolation proof through `bin/fm-test-isolation-proof.sh`.

<!-- /fm-authority -->

## Coverage guard

`bin/fm-test-run.sh --check-coverage` proves:

1. The two portable parallel shards are a partition of the proven-isolated set.
2. Proven-isolated embeds match `bin/fm-test-isolation-proof.sh --list`.
3. Union of portable parallel shards + portable serial + real-Herdr family equals the complete `tests/*.test.sh` inventory.
4. Those four partitions are pairwise disjoint (no missing scripts, no duplicates).
5. `portable-serial-1` and `portable-serial-2` are themselves a partition of `portable-serial`, so the split can neither drop a script nor run one twice.

`--lane portable-serial-1` additionally refuses at selection time if the head list names a script that has left the remainder, rather than running it in both a serial half and a parallel shard.

CI runs that guard as a required job (`test-coverage`).

## Timing artifacts

Every portable shard, both portable serial halves, and the Herdr lane upload their runner-generated timing JSON even when the behavior run reports failures.
The dependent aggregate job runs after all five lanes, combines every available lane JSON through `bin/fm-test-run.sh --aggregate-json`, and uploads one summary artifact for critical-path review.
The workflow in `.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | Measured shard sum ~1 min; hang tripwire with margin |
| portable serial 1/2 | 20 | Measured ~10 min per half after the split; hang tripwire at roughly twice the healthy wall |
| Herdr | 40 | Unchanged hang tripwire for the real-Herdr lane |

Timeouts remain hang tripwires, not expected healthy ends of green suites.
Do not raise them as a substitute for green results, retries, or weaker assertions.
When a lane grows into its cap, redistribute the work and record the new measurement, as the serial split above did.

<!-- fm-authority: firstmate-observation 2026-08-16 - the three lint job walls were read from GitHub Actions job timings and cannot be reproduced from inside a checkout -->
`Lint shell scripts` carries its own 20-minute cap and was observed at 13m58s, 14m08s, and 14m19s in the three most recent `main` runs (31902522552, 31855604632, 31819434635).
It is trending the same way and will need its own treatment.
This document covers the serial behavior lane only; nothing here changes the lint job.
<!-- /fm-authority -->

## What this phase does not do

- Does not expand the proven-isolated set without a new concurrent isolation proof.
- Does not parallelize watcher, AFK, real Herdr, real tmux, or other stateful families.
  Splitting the remainder across two runners leaves every one of them running alone.
- Does not change what any test asserts, and does not skip or delete a test to buy wall-clock.
- Does not start rollout verification; that waits until this PR is green and merged.
