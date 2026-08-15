# Spawn launch delivery

How a worker's launch reaches its pane, and the evidence behind each part of it.
`bin/fm-spawn.sh` owns the mechanism; this file owns the measurements that shaped it.

## The incident: a startup prompt ate the command (2026-08-13)

`bin/fm-spawn.sh` used to create a window, type `treehouse get` into whatever the login shell put there, then type the environment export and the launch command.

<!-- fm-authority: firstmate-observation 2026-08-13 - measured on the captain's own host, outside any checkout a gate agent can reach -->
oh-my-zsh's auto-update prompt sat at `[oh-my-zsh] Would you like to update? [Y/n]` in every freshly created window.
It consumed the `t` of `treehouse get`, the shell received `reehouse get`, and the spawn died on its bounded wait with `treehouse get did not enter a worktree within 60s`.
Reproduced three times out of three.
It cleared only when oh-my-zsh was updated by hand in another session, which is a workaround with a shelf life: the next thing that prompts at startup reintroduces it, and every fleet member on that host is blocked while it lasts.
<!-- /fm-authority -->

Two approaches were tried against that failure and rejected.

- **A settle-wait before the first send does not work.**
  A stability wait (two consecutive identical captures) reads a calm pane, because an interactive prompt is perfectly stable on screen, and types straight into the question.
- **Sending a bare newline first is unsafe.**
  It answers an unknown question with its default, and the whole point is that we do not know what is being asked.

An earlier reading of this failure as a shell-startup race was wrong: the "same command works once the shell settles" test was confounded, because the first send had already answered the prompt.

## What replaced it

**The worktree is acquired off-pane.**
`treehouse get --lease --lease-holder <id>` runs in fm-spawn's own process, prints the path on stdout, and opens no subshell - the same durable lease `bin/fm-home-seed.sh` already takes for a secondmate home.
No shell prompt can touch it, the 60s cwd poll is gone, and the isolation assertion now runs before any pane exists.
The lease is durable, so it is taken once per task: a respawn reuses the worktree its own metadata records through `worktree_lease=`, and metadata written before this script leased anything is never adopted.

**The launch is one submitted command line, not a keystroke pair.**
Each backend's own "run this command line" primitive carries it (herdr's `pane run`, tmux's `send-keys <text> Enter`), so there is no separate Enter to lose.

**Delivery is confirmed before the task is recorded as started.**
The line is one `&&` chain:

```
test ! -s <sentinel> && printf %s <nonce> > <sentinel>
  && ( cd <worktree> && export GOTMPDIR=... && <launch> )
```

- *Mangled input*: a prompt that swallows leading characters leaves a mangled first word, which exits non-zero and short-circuits the chain - no nonce, and nothing after it ran.
- *Repeated input*: `test ! -s` makes the chain idempotent, so a pane that buffered a retry and replays it later cannot start a second agent.
- *Subshell*: the pane's own shell never enters the worktree (see the teardown finding below).

fm-spawn waits for the nonce, retries a bounded number of times, and on failure prints the pane's last lines, restores the pre-spawn record, and exits non-zero.
`FM_SPAWN_LAUNCH_WAIT`, `FM_SPAWN_LAUNCH_TRIES`, and `FM_SPAWN_LAUNCH_FLUSH_WAIT` tune it; the script's header owns their defaults.

## Per backend

Every spawn-capable backend was inspected, not only the reference one.

| Backend | Worktree acquire | Launch submission | Verified by |
| --- | --- | --- | --- |
| tmux | leased off-pane | `send-keys <line> Enter`, one call instead of a literal send plus a separate Enter | `fm-backend-tmux-smoke`, `fm-tangle-guard` (records the exact call sequence), `fm-spawn-launch-delivery` |
| herdr | leased off-pane | `pane run`, herdr's own execute-a-command-line API | `fm-backend-herdr`, plus the three live lab e2e suites |
| zellij | leased off-pane | its existing command-line send; adapter unchanged | `fm-backend-zellij`, `fm-backend-zellij-smoke` |
| cmux | leased off-pane | its existing command-line send; adapter unchanged | `fm-backend-cmux`, `fm-backend-cmux-smoke` |
| orca | none - Orca owns the worktree it creates | `terminal send --text ... --enter`, one call instead of two | `fm-backend-orca` |
| sbx | none - a secondmate's home IS its worktree | keeps its own verified literal-then-submit shape, because its command-line send carries pending-delivery bookkeeping that belongs to steering; the sentinel lives on the signal-bridge mount, which the guest writes and the host reads | `fm-spawn-sbx`, `fm-backend-sbx`, `fm-secondmate-liveness`, `fm-watch-sbx-signals` |

No adapter gained or lost a primitive: the launch simply moved onto the one each already had for running a command line.

## Findings this change surfaced

Each of these was invisible while nothing verified that a launch landed.

### A herdr pane can echo keystrokes and execute nothing (herdr 0.7.5, 2026-08-14)

A freshly created tab intermittently handed back a pane with no shell reading its pty.
The pane's own read showed the launch line three times over, each followed by a blank line, with no prompt and no output:

```
--- last lines of fm-lab-fm-herdr-present-77476-32243:w1:p2 ---
printf %s '02a8eca8bf587dbd' > '/private/var/folders/.../home/state/anchor.launched' && cd '/Users/lp1/.treehouse/project-f351ef/1/project' && export GOTMPDIR='/tmp/fm-anchor/gotmp' && sh -c 'sleep 120'

printf %s '02a8eca8bf587dbd' > ... (twice more, identical)
--- end ---
```

Under the old code the same pane produced a task recorded as started with no agent in it.
The idempotence guard is what makes the retry safe when that pane later wakes and runs everything it buffered.

### Teardown killed the pane before the backend could close it

`bin/fm-teardown.sh` returns the worktree to the pool *before* it closes the pane, and that return kills every process living inside the worktree.
While the launch `cd`'d the pane's own login shell into the worktree, teardown killed the pane out from under the backend, which could then no longer close it cleanly - measured on a live herdr projection, the dying pane took the captain's focused workspace with it.
`treehouse get`'s subshell used to absorb this: the login shell stayed in the project and only the subshell was in the worktree.
The launch chain's subshell restores exactly that topology.

### A leased slot must not be force-returned on abort

`treehouse return --force` kills whatever lives in the worktree and resets it.
Releasing a leased-but-unused slot that way during spawn abort disturbed a live herdr projection's focus, so the abort path uses a plain `treehouse return`: it refuses rather than kills, costing a held pool slot instead of a surprise.
A spawn that fails after its pane exists never returns the slot at all; it says so and leaves it held for that task.

## Regression coverage

`tests/fm-spawn-launch-delivery.test.sh` drives the real `bin/fm-spawn.sh` against a fake pane backed by a REAL shell, so a command that arrives mangled genuinely does not run.
It covers a prompt that eats the first typed character, a prompt that never clears (must fail loudly and record no started task), a swallowed send, a lost Enter, a pane that replays every buffered retry, and the assertion that the worktree acquire is never typed into a pane.

Fixtures that model a WORKING shell call `tests/fake-launch-ack.sh`, which runs only the sentinel-claiming head of the chain.
Any fixture that drives a ship or scout spawn must also install `fm_fake_treehouse` (tests/lib.sh): the acquire is a real subprocess now, so a fixture that leaves the host's own treehouse first on PATH would run it against the captain's live pool.
