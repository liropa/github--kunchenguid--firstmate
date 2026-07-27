#!/usr/bin/env bash
# bin/backends/sbx.sh - the Docker Sandboxes (sbx) session-provider adapter.
#
# EXPERIMENTAL, secondmate-only. Each sbx task is one clone-mode microVM
# ("sandbox") running the secondmate agent inside an in-VM tmux session; the
# host supervises it through plain files on a bind-mounted read-write signal
# directory (the "signal bridge"), never through per-poll `sbx exec` calls.
# Design: agent-dotfiles docs/firstmate-sbx-secondmate-event-bridge.md (rev 2,
# v1 file-signal route). Empirical CLI facts: docs/sbx-backend.md.
#
# Targets are recorded as `window=sbx:<sandbox-name>` where the sandbox name is
# the task's window label (fm-<id>), so fm_backend_resolve_selector's explicit
# "<contains-colon> passes through" arm routes them here untouched.
#
# Key properties, in the order they matter:
#   - The liveness verdict (fm_backend_sbx_agent_alive) maps sbx state onto the
#     upstream alive|dead|unknown contract with `stopped` = ALIVE (sbx
#     auto-stops idle sandboxes; disk state is intact and the VM restarts in
#     ~1.5-2 s, so respawning a stopped secondmate would destroy a healthy one)
#     and CLI error/ambiguity = UNKNOWN, never dead (a docker/CLI hiccup must
#     not trigger a fleet-wide respawn of duplicate supervisors).
#   - Reads are state-gated: `sbx exec` AUTO-STARTS a stopped sandbox
#     (verified), so every probe-shaped operation (capture, busy reads) first
#     checks `sbx ls` state - one cheap host CLI call - and refuses to exec a
#     sandbox that is not running. Routine triage of an idle-stopped secondmate
#     must never churn its VM.
#   - Steering owns resurrection: auto-stop kills the guest PROCESS TREE (the
#     agent, its tmux server, any in-guest daemons die; only disk survives), so
#     the first send after a stop must rebuild the stack - start the VM, then
#     relaunch tmux + the agent in its harness's resume mode - before
#     delivering (fm_backend_sbx_ensure_stack).
#
# The v2 event layer (events_capable / wait_transition / commit/clear) is
# deliberately absent; when its latency trigger fires, those functions slot in
# below fm_backend_sbx_ensure_stack without touching the v1 surface (see the
# design doc §9).

# Beat freshness horizon: a signal-bridge beat file younger than this means the
# secondmate was actively working moments ago, so liveness is `alive` without
# any sbx CLI call at all.
FM_SBX_BEAT_GRACE=${FM_SBX_BEAT_GRACE:-300}

# Root of the per-secondmate signal-bridge mounts (one RW-mounted directory per
# secondmate id, created by fm-spawn.sh at provision). Same absolute path on
# host and guest - virtiofs mounts preserve the host path (verified).
FM_SBX_SIGNALS_ROOT=${FM_SBX_SIGNALS_ROOT:-$HOME/dev/fm-signals}

# Settle time after a resurrection relaunch before the caller's message is
# delivered, so the resumed agent's composer exists to receive it.
FM_SBX_RESURRECT_SETTLE=${FM_SBX_RESURRECT_SETTLE:-8}

# After the settle, resurrection additionally waits for the resumed TUI to
# stop redrawing before delivering - up to this many 2 s capture polls (see
# fm_backend_sbx_ensure_stack; 0 disables the poll, unit tests do).
FM_SBX_RESURRECT_READY_TRIES=${FM_SBX_RESURRECT_READY_TRIES:-15}

# Cap (seconds) on how long a keep-alive exec pins the VM waiting for the
# guest to go idle (fm_backend_sbx_keepalive). 0 disables keep-alives
# entirely (unit tests do).
FM_SBX_KEEPALIVE_MAX=${FM_SBX_KEEPALIVE_MAX:-7200}

# Poll interval (seconds) for the keep-alive's in-guest activity loop.
FM_SBX_KEEPALIVE_POLL=${FM_SBX_KEEPALIVE_POLL:-5}

# Horizon (seconds) within which an in-guest signal-file advance (a child
# worker's status/turn-ended write under the guest home's state/) still counts
# as live worker activity, and the freshness bound for the host-visible
# <id>.guest-active breadcrumb the keep-alive maintains. Bridges a worker's
# short between-turns gaps without pinning a genuinely idle guest.
FM_SBX_GUEST_ACTIVE_WINDOW=${FM_SBX_GUEST_ACTIVE_WINDOW:-120}

# Wait (seconds) after a suspicious keep-alive exit before the wrapper reads
# the sandbox state once: covers the measured 45-100 s post-disconnect
# auto-stop grace, so the wrapper classifies the settled outcome (stopped)
# rather than the transition.
FM_SBX_MIDTASK_STOP_SETTLE=${FM_SBX_MIDTASK_STOP_SETTLE:-120}

# In-guest tmux session name. One secondmate per sandbox, so a fixed session
# name with the task's fm-<id> window is unambiguous within each VM.
FM_SBX_GUEST_SESSION=${FM_SBX_GUEST_SESSION:-fm}

# Clone mode's read-only live bind mount of the host home inside the guest.
# The path is an sbx implementation detail, not a documented upstream contract
# (verified live, Gate P1 2026-07-21; agent-dotfiles
# docs/firstmate-sbx-guest-home-provisioning.md §3/§8) - so spawn probes it
# right after create and refuses loudly on drift, and an upstream rename is
# this one-line config fix rather than a code change.
FM_SBX_SOURCE_MOUNT=${FM_SBX_SOURCE_MOUNT:-/run/sandbox/source}

# The guest-home provisioning pass links each declared FM_INHERITABLE_CONFIG
# item plus the shared captain file; fm-config-inherit-lib.sh owns both
# declarations (the single declared list), and this adapter is sourced
# standalone by fm-send/fm-crew-state where that lib is otherwise absent.
if [ -z "${FM_INHERITABLE_CONFIG:-}" ] || [ -z "${FM_SHARED_CAPTAIN_REL:-}" ]; then
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../fm-config-inherit-lib.sh"
fi

fm_backend_sbx_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

# fm_backend_sbx_shell_quote: single-quote <s> for a guest shell command line
# (same form as fm-spawn.sh's shell_quote; duplicated here because the adapter
# is sourced standalone by fm-send/fm-crew-state, where fm-spawn's helpers are
# out of scope).
fm_backend_sbx_shell_quote() {  # <s>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_backend_sbx_name_of_target: `sbx:<name>` -> `<name>`. A bare name (no
# prefix) passes through, defensively.
fm_backend_sbx_name_of_target() {  # <target>
  local t=$1
  printf '%s' "${t#sbx:}"
}

# fm_backend_sbx_task_of_target: the task id behind a target, from the fm-<id>
# sandbox-name convention. Empty (rc 1) for a non-fm-* name - callers that
# need the id (beat probe, meta lookup) skip those steps rather than guessing.
fm_backend_sbx_task_of_target() {  # <target>
  local name
  name=$(fm_backend_sbx_name_of_target "$1")
  case "$name" in
    fm-?*) printf '%s' "${name#fm-}" ;;
    *) return 1 ;;
  esac
}

# fm_backend_sbx_state: one cheap host-side read of <name>'s sandbox state.
# Never execs into the sandbox. Prints exactly one of:
#   running - the sandbox VM is up.
#   stopped - present but auto-stopped/stopped; disk state intact, resumable.
#   absent  - `sbx ls` answered authoritatively and the name is NOT in the
#             inventory: the sandbox is confirmed gone.
#   error   - the CLI failed, its JSON did not parse, or the status vocabulary
#             is unrecognized: NOT a confirmed absence.
# The absent-vs-error split is the whole point: only a parse-clean listing
# that positively lacks the name may ever become a `dead` liveness verdict.
fm_backend_sbx_state() {  # <name>
  local name=$1 out st
  command -v sbx >/dev/null 2>&1 || { printf 'error'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'error'; return 0; }
  out=$(sbx ls --json 2>/dev/null) || { printf 'error'; return 0; }
  st=$(printf '%s' "$out" | jq -r --arg n "$name" \
    '.sandboxes[] | select(.name == $n) | .status' 2>/dev/null) || { printf 'error'; return 0; }
  case "$st" in
    running) printf 'running' ;;
    stopped) printf 'stopped' ;;
    '')      printf 'absent' ;;
    *)       printf 'error' ;;
  esac
}

# fm_backend_sbx_transport_reachable: 0 when THIS process context can reach the
# sbx control plane at all, 1 when it demonstrably cannot. A confirmed-absent
# sandbox is REACHABLE (the inventory answered; the target is simply gone) -
# only an unreadable inventory means no route. The distinction matters because
# every steering primitive below funnels through fm_backend_sbx_ensure_stack,
# whose first act is this same inventory read: a caller with no route cannot
# deliver to a running sandbox any more than to a stopped one, so "unreachable"
# is a property of the CALLER, never of the target's power state.
# Live cause on this host: a sandboxed caller (the watcher's context) is denied
# the daemon socket, so `sbx` decides no daemon is running, tries to start its
# own, finds the real one's pid file and gives up after ~10s. Callers must
# therefore spend this probe only when they are about to steer, never per poll.
fm_backend_sbx_transport_reachable() {  # <name>
  [ "$(fm_backend_sbx_state "$1")" != error ]
}

# fm_backend_sbx_mtime: portable file mtime in epoch seconds (BSD stat -f on
# macOS, GNU stat -c on Linux CI). Empty output + rc 1 when unreadable.
fm_backend_sbx_mtime() {  # <file>
  local f=$1 m
  [ -e "$f" ] || return 1
  if m=$(stat -f %m "$f" 2>/dev/null); then
    printf '%s' "$m"
    return 0
  fi
  if m=$(stat -c %Y "$f" 2>/dev/null); then
    printf '%s' "$m"
    return 0
  fi
  return 1
}

# fm_backend_sbx_beat_fresh: 0 when <id>'s signal-bridge beat file was touched
# within FM_SBX_BEAT_GRACE seconds - the guest's turn-end hook touches it on
# every turn boundary, so a fresh beat means "actively working right now".
fm_backend_sbx_beat_fresh() {  # <id>
  local id=$1 beat m now
  beat="$FM_SBX_SIGNALS_ROOT/$id/$id.beat"
  m=$(fm_backend_sbx_mtime "$beat") || return 1
  now=$(date +%s)
  [ $((now - m)) -le "$FM_SBX_BEAT_GRACE" ]
}

# fm_backend_sbx_target_present: pane-PRESENCE-equivalent existence check for
# the generic fm_backend_target_exists dispatcher and fm-crew-state.sh's
# pane_readable. A stopped sandbox IS present (resumable endpoint); only a
# confirmed-absent or unreadable inventory fails. Never execs (a capture-based
# presence read would auto-start a stopped VM).
fm_backend_sbx_target_present() {  # <target> [expected-label]
  local name
  name=$(fm_backend_sbx_name_of_target "$1")
  case "$(fm_backend_sbx_state "$name")" in
    running|stopped) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_sbx_agent_alive: CONFIDENT liveness on the upstream three-valued
# contract (bin/fm-backend.sh's fm_backend_agent_alive; the session-start
# secondmate-liveness sweep acts only on `dead`). Mapping, in probe order:
#   fresh beat       -> alive    (host stat only; no sbx CLI call at all)
#   state running    -> alive
#   state stopped    -> alive    (idle-resumable: auto-stop is HEALTHY; a
#                                 respawn here would destroy intact state)
#   state absent     -> dead     (parse-clean inventory positively lacks the
#                                 name: truly gone, sweep may re-provision)
#   state error      -> unknown  (NEVER dead: a transient docker/CLI failure
#                                 must not trigger a duplicate-supervisor
#                                 respawn - the exact failure the upstream
#                                 contract exists to prevent)
fm_backend_sbx_agent_alive() {  # <target>
  local target=$1 id
  if id=$(fm_backend_sbx_task_of_target "$target"); then
    if fm_backend_sbx_beat_fresh "$id"; then
      printf 'alive'
      return 0
    fi
  fi
  case "$(fm_backend_sbx_state "$(fm_backend_sbx_name_of_target "$target")")" in
    running|stopped) printf 'alive' ;;
    absent)          printf 'dead' ;;
    *)               printf 'unknown' ;;
  esac
}

# fm_backend_sbx_guest_tmux_target: the in-guest tmux pane a task's agent runs
# in: session FM_SBX_GUEST_SESSION, window named like the sandbox (fm-<id>).
fm_backend_sbx_guest_tmux_target() {  # <name>
  printf '%s:%s' "$FM_SBX_GUEST_SESSION" "$1"
}

# fm_backend_sbx_capture: bounded plain-text capture of the agent's in-guest
# tmux pane. STATE-GATED: `sbx exec` auto-starts a stopped sandbox, so this
# refuses (rc 1, no output) unless the sandbox is ALREADY running - a stopped
# secondmate is by definition not provably working and must be classified from
# its status log alone, with its VM left stopped (design §7.3). The exec cost
# of a running-sandbox capture is bounded by signal frequency, not poll
# frequency (secondmates are exempt from the watcher's stale-pane scans).
fm_backend_sbx_capture() {  # <target> <lines> [expected-label]
  local target=$1 lines=$2 name
  name=$(fm_backend_sbx_name_of_target "$target")
  [ "$(fm_backend_sbx_state "$name")" = running ] || return 1
  sbx exec "$name" -- tmux capture-pane -p -t "$(fm_backend_sbx_guest_tmux_target "$name")" -S -"$lines"
}

# fm_backend_sbx_kill: remove the task's sandbox, best-effort (the generic
# fm_backend_kill contract: a gone target is not an error). `sbx rm --force`
# DESTROYS the whole VM including its disk (the in-guest home clone's private
# data/ and any unlanded in-guest work). Callers own the landed-work
# authority: the liveness sweep only reaches this after a confident `dead`
# (the sandbox is already absent - a no-op here), and explicit teardown/retire
# of an sbx secondmate must verify its work landed BEFORE killing, exactly as
# fm-teardown.sh's contract requires. --force is required non-interactively
# (the confirmation prompt otherwise dies on "stdin is not a terminal").
fm_backend_sbx_kill() {  # <target>
  local name
  name=$(fm_backend_sbx_name_of_target "$1")
  sbx rm --force "$name" 2>/dev/null || true
}

# fm_backend_sbx_unlanded_work: does <target>'s guest hold work that
# fm_backend_sbx_kill's `sbx rm --force` would destroy? This is the in-VM half
# of fm-teardown.sh's landed-work contract: a secondmate's real work lives in
# the in-guest clone at the SAME absolute path as the recorded home= (clone
# mode), which the host worktree safety check cannot see. Mirrors that check,
# reaching inside the VM. Prints a human-readable reason and returns:
#   0  safe to destroy - the guest is clean and every commit is on a remote,
#      OR the sandbox is confirmed ABSENT (already gone - nothing to lose).
#   1  UNSAFE - the guest holds uncommitted changes, or commits that live
#      nowhere but the VM disk, OR the state could not be verified (fail-safe:
#      an unreadable sandbox or a git error is NEVER treated as clean).
# Unlike routine triage, this inspects a STOPPED VM too (its disk holds the
# work), and `sbx exec` auto-starts it - acceptable because retire/teardown is
# an explicit, one-shot, captain-initiated act, not a poll, and the VM is about
# to be destroyed or deliberately preserved either way. No PR-merged /
# content-in-default fallback like the host ship check: a secondmate lands by
# pushing, and reproducing gh/PR resolution inside the VM is out of scope - the
# captain confirms a squash-merged-but-unpushed guest with --force.
fm_backend_sbx_unlanded_work() {  # <target> <home>
  local target=$1 home=$2 name state dirty unpushed
  name=$(fm_backend_sbx_name_of_target "$target")
  if [ -z "$home" ]; then
    printf 'cannot verify in-guest work for %s: no home path recorded in meta' "$name"
    return 1
  fi
  state=$(fm_backend_sbx_state "$name")
  case "$state" in
    absent) return 0 ;;
    running|stopped) ;;
    *)
      printf 'cannot verify in-guest work for %s: sandbox state is unreadable (%s)' "$name" "$state"
      return 1
      ;;
  esac
  # Uncommitted changes are never landed. This intentionally diverges from the
  # host worktree check's untracked-file filters: a clean sbx guest already
  # hides its seeded files from git (`.claude/settings.local.json` is in
  # `.git/info/exclude`, the brief is under ignored `data/`), and
  # `.fm-grok-turnend` is not created by the claude/codex-only sbx backend.
  # Any status output is therefore genuine in-guest work that `sbx rm --force`
  # would destroy.
  if ! dirty=$(sbx exec "$name" -- git -C "$home" status --porcelain 2>/dev/null); then
    printf 'cannot verify in-guest work for %s: git status failed in %s' "$name" "$home"
    return 1
  fi
  if [ -n "$dirty" ]; then
    printf 'sandbox %s has uncommitted changes in %s' "$name" "$home"
    return 1
  fi
  # Commits reachable from HEAD but from no remote-tracking branch (a fork
  # counts as a remote) exist nowhere but the VM disk.
  if ! unpushed=$(sbx exec "$name" -- git -C "$home" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    printf 'cannot verify in-guest work for %s: git log failed in %s' "$name" "$home"
    return 1
  fi
  if [ -n "$unpushed" ]; then
    printf 'sandbox %s has commits not on any remote in %s' "$name" "$home"
    return 1
  fi
  return 0
}

# --- agent flavor vs driver harness -----------------------------------------
#
# `sbx create <agent>` picks the sandbox's credential wiring, not the CLI
# firstmate launches in the guest pane. The flavor and driver are therefore
# resolved separately.
#
# FM_SBX_AGENT pins the flavor independently, exactly as FM_SBX_TEMPLATE pins
# the template image; unset or empty resolves to the driver's own flavor.
# docs/sbx-backend.md "Agent flavor vs driver harness" owns the supported
# matrix and its measured evidence.
#
# sbx itself only WARNS on a template/agent mismatch and creates the sandbox
# anyway, so an unusable pairing has to be refused here - before a VM exists -
# rather than discovered when the guest 401s on its first authenticated call.

# fm_backend_sbx_harnesses_for_agent: the driver harnesses an agent flavor's
# credential wiring serves in-guest. An unsupported flavor answers nothing
# and rc 1; docs/sbx-backend.md owns the matrix and evidence.
fm_backend_sbx_harnesses_for_agent() {  # <agent>
  case "$1" in
    claude) printf 'claude' ;;
    codex)  printf 'claude codex' ;;
    *) return 1 ;;
  esac
}

# fm_backend_sbx_agent_for_harness: the agent flavor to create the sandbox
# with for <harness>, honoring the FM_SBX_AGENT pin and refusing any pairing
# whose credentials cannot serve the driver.
fm_backend_sbx_agent_for_harness() {  # <harness>
  local harness=$1 agent served
  case "$harness" in
    claude) agent=${FM_SBX_AGENT:-claude} ;;
    codex)  agent=${FM_SBX_AGENT:-codex} ;;
    *)
      echo "error: harness '$harness' is not verified on the sbx backend (supported: claude codex)" >&2
      return 1
      ;;
  esac
  served=$(fm_backend_sbx_harnesses_for_agent "$agent") || {
    echo "error: FM_SBX_AGENT='$agent' is not a supported sbx agent flavor (supported: claude codex)" >&2
    return 1
  }
  case " $served " in
    *" $harness "*) ;;
    *)
      echo "error: sbx agent flavor '$agent' cannot serve a '$harness' driver: that flavor wires only its own vendor credential into the guest, so in-guest $harness has no resolvable auth token and fails its first authenticated call (this flavor serves: $served; measured 2026-07-27, docs/sbx-backend.md 'Agent flavor vs driver harness'). Set FM_SBX_AGENT to a flavor that serves $harness, or drive this sandbox with $agent." >&2
      return 1
      ;;
  esac
  printf '%s' "$agent"
}

# --- launch / resume templates ----------------------------------------------
#
# The guest-side launch commands live HERE, not in fm-spawn.sh's host
# launch_template(): sbx secondmates diverge from host secondmates in exactly
# the signal wiring (host secondmates signal through their home's own
# infrastructure; sbx secondmates must touch the signal-bridge mount on every
# turn boundary), and the resume variants must sit next to the launch variants
# so resurrection can never drift from spawn.
#
# Supported harnesses are the intersection of the liveness sweep's verified
# list (claude|codex|opencode|pi|grok), sbx's installable agents, and what has
# a verified turn-end + resume shape on this backend: claude and codex.
# Everything else is refused loudly at spawn (never dispatch on an unverified
# adapter - AGENTS.md section 4).

# fm_backend_sbx_launch_template: the initial in-guest launch command for a
# freshly provisioned sbx secondmate. Placeholders __BRIEF__, __TURNEND__,
# __BEAT__, __MODELFLAG__, __EFFORTFLAG__ are substituted by fm-spawn.sh
# (brief/turn-end/beat resolve to GUEST-visible paths: the brief copy inside
# the clone and the signal-bridge mount files). claude's turn-end signal is a
# Stop hook written into the guest clone by fm-spawn (it cannot ride the
# launch command); codex's rides `-c notify=[...]`, touching turn-ended AND
# beat in one hook - both files, every turn boundary (design §6.1).
# codex additionally carries --dangerously-bypass-hook-trust (verified live,
# codex 0.142.5): the home clone ships .codex/hooks.json, and codex's
# hook-trust TUI gate would otherwise park the launch on a dialog no one is
# there to answer. Its trusted_hash scheme is codex-internal, so the trust
# cannot be pre-seeded the way fm-spawn seeds directory trust; the bypass
# flag is codex's own escape hatch for automation whose hook sources are
# already vetted - here, the home clone this same spawn just provisioned.
fm_backend_sbx_launch_template() {  # <harness>
  # shellcheck disable=SC2016  # single quotes deliberate: $(cat ...) expands in the guest pane
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)  printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__ __BEAT__\"]" "$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

# fm_backend_sbx_resume_template: the relaunch command resurrection uses after
# an auto-stop killed the agent. Session-resume mode, not a fresh brief: the
# agent's conversation state survives on the VM disk. claude's Stop hook
# survives in the clone's .claude/settings.local.json, so resume needs no
# re-wiring; codex's notify= must be re-supplied on the resume command.
fm_backend_sbx_resume_template() {  # <harness> <turnend> <beat>
  local harness=$1 turnend=$2 beat=$3 cmd
  case "$harness" in
    claude) printf '%s' 'claude --continue --dangerously-skip-permissions' ;;
    codex)
      # Built by placeholder substitution into a single-quoted literal, with
      # the signal paths shell-quoted - never via a printf FORMAT string:
      # bash's printf rewrites \" escapes inside the format, which strips the
      # notify JSON's quoting; the guest shell then word-splits the paths
      # into phantom positional args, which `codex resume --last` rejects
      # ("--last cannot be used with '[PROMPT]'", verified live). The launch
      # template passes its string as a %s argument for the same reason.
      # shellcheck disable=SC2016  # single quotes deliberate: the notify JSON must reach the guest verbatim
      cmd='codex resume --last --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__ __BEAT__\"]"'
      cmd=${cmd/__TURNEND__/$(fm_backend_sbx_shell_quote "$turnend")}
      cmd=${cmd/__BEAT__/$(fm_backend_sbx_shell_quote "$beat")}
      printf '%s' "$cmd"
      ;;
    *) return 1 ;;
  esac
}

# --- keep-alive: pin the VM through guest work -------------------------------

# fm_backend_sbx_keepalive_script: print the guest-side sh loop the keep-alive
# exec runs, factored out so tests can exercise the pin/release logic directly
# (a fake tmux plus real files) without a sandbox. Args after the _ argv0:
#   $1 turn-ended mount file    $2 max pin seconds   $3 poll seconds
#   $4 activity window seconds  $5 guest home path ('' skips the state probe)
#   $6 busy-pane regex
# Pin/release contract (docs/sbx-backend.md "Steering and resurrection"):
#   - Pin at least until the turn-ended mount file advances past its delivery
#     baseline (the original v1 condition: the delivered turn must not die).
#   - Past that, keep pinning while the guest shows WORK: any tmux pane whose
#     visible tail matches the busy regex (the same busy idiom the watcher and
#     the submit verify use), or a status/turn-ended file under the guest
#     home's state/ (an in-guest child worker's signals) touched within the
#     activity window. An in-guest crewmate therefore keeps the VM alive
#     across the secondmate's own turn boundaries (fork issue #12).
#   - Release ("released-idle") once the turn ended AND no work is visible: a
#     genuinely idle guest still auto-stops (stopped-is-healthy stays true).
#     An idle-parked worker TUI - no busy tail, no recent signals - is NOT
#     work and never pins, exactly like the secondmate's own idle TUI.
#   - The cap bounds everything ("capped-active"/"capped-idle"): a wedged or
#     forever-busy-looking guest can never pin the VM past the cap.
#   - While work is visible, touch the mount's <id>.guest-active breadcrumb so
#     the HOST gets a pure-stat view of in-guest activity (the wrapper's
#     mid-task-stop check below, and fm-watch.sh's stranding suppression).
# Plain POSIX sh, GNU-first portable stat (the guest is Linux; the BSD arm
# exists so the host-side unit tests can run the same script on macOS).
fm_backend_sbx_keepalive_script() {
  # shellcheck disable=SC2016  # single quotes deliberate: $1..$6 expand in the guest sh loop, not here
  printf '%s' '
    t=$1 max=$2 poll=$3 window=$4 home=$5 regex=$6
    act=${t%.turn-ended}.guest-active
    mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
    start=$(date +%s)
    base=$(mt "$t")
    while :; do
      now=$(date +%s)
      work=0
      for p in $(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null); do
        if tmux capture-pane -p -t "$p" 2>/dev/null | grep -v "^[[:space:]]*$" | tail -6 | grep -qiE "$regex"; then
          work=1
          break
        fi
      done
      if [ "$work" = 0 ] && [ -n "$home" ]; then
        for f in "$home"/state/*.status "$home"/state/*.turn-ended; do
          [ -e "$f" ] || continue
          [ $((now - $(mt "$f"))) -le "$window" ] || continue
          work=1
          break
        done
      fi
      if [ "$work" = 1 ]; then touch "$act" 2>/dev/null; fi
      if [ $((now - start)) -ge "$max" ]; then
        if [ "$work" = 1 ]; then echo "fm-keepalive capped-active"; else echo "fm-keepalive capped-idle"; fi
        exit 0
      fi
      cur=$(mt "$t")
      if [ "$cur" -gt "$base" ] && [ "$work" = 0 ]; then
        echo "fm-keepalive released-idle"
        exit 0
      fi
      sleep "$poll"
    done'
}

# fm_backend_sbx_keepalive: hold ONE background `sbx exec` open until the
# guest is done working or FM_SBX_KEEPALIVE_MAX elapses. Why this exists:
# Docker Sandboxes' auto-stop is HOST-CONNECTION-based, not guest-workload-
# based - a VM with no live exec/attach stops within roughly a minute even
# with a CPU-busy guest process (verified live; a detached in-guest tmux
# agent gets no protection at all, unlike agent-as-exec rigs where the run
# IS the connection). Without a keeper, any launch or steered turn that
# outlasts the post-disconnect grace is killed mid-work: the turn never
# ends, no signal lands, and the secondmate silently freezes until the next
# steer resurrects it into the same trap. Releasing on the secondmate's own
# turn-end alone re-opened the same trap one level down: an in-guest crewmate
# holds no host connection, so the VM died 45-100 s after the secondmate's
# turn ended and killed the mid-implementation worker (fork issue #12, proven
# three times 2026-07-23). The keeper is the narrow fix: one connection, held
# exactly while the guest shows work (fm_backend_sbx_keepalive_script above),
# self-terminating on the guest side, so an idle VM still auto-stops.
# Fire-and-forget: callers never wait on it, and a keeper left pinned by work
# that never ends is bounded by the cap. Multiple keepers (one per steer) are
# harmless - all release on the same idle reading.
# The host-side wrapper then classifies how the pin ended: a clean idle
# release or an idle cap expiry is silent, while a cap expiry with work still
# active - or an exec death while the guest-active breadcrumb was fresh (an
# explicit stop, a crash) - waits FM_SBX_MIDTASK_STOP_SETTLE, reads the
# sandbox state once (the only sbx CLI call, spent per rare suspicious exit,
# never per poll), and on stopped/absent records the .sbx-midtask-stop marker
# fm-watch.sh's beacon surfaces as a named mid-task-stop alarm. Guest stdout
# is untrusted data: only the fixed fm-keepalive verdict shapes are matched,
# and the breadcrumb is stat'ed, never read.
fm_backend_sbx_keepalive() {  # <name> <id> [home]
  local name=$1 id=$2 home=${3:-} turnend script busy key marker
  [ "$FM_SBX_KEEPALIVE_MAX" -gt 0 ] 2>/dev/null || return 0
  turnend="$FM_SBX_SIGNALS_ROOT/$id/$id.turn-ended"
  script=$(fm_backend_sbx_keepalive_script)
  busy=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}
  key=$(printf '%s' "$id" | tr '.' '_')
  marker="$(fm_backend_sbx_state_dir)/.sbx-midtask-stop-$key"
  (
    trap '' HUP
    out=$(sbx exec "$name" -- sh -c "$script" _ "$turnend" "$FM_SBX_KEEPALIVE_MAX" \
      "$FM_SBX_KEEPALIVE_POLL" "$FM_SBX_GUEST_ACTIVE_WINDOW" "$home" "$busy" 2>/dev/null) || true
    verdict=$(printf '%s\n' "$out" | grep '^fm-keepalive ' | tail -1)
    why=
    case "$verdict" in
      'fm-keepalive released-idle'|'fm-keepalive capped-idle') exit 0 ;;
      'fm-keepalive capped-active')
        why="the keep-alive cap (${FM_SBX_KEEPALIVE_MAX}s) expired while in-guest work was still active"
        ;;
      *)
        # No verdict: the exec died under us. Only suspicious when in-guest
        # work was recently observed through the breadcrumb; a quiet death of
        # an idle keeper is not a captain-facing event.
        m=$(fm_backend_sbx_mtime "${turnend%.turn-ended}.guest-active") || exit 0
        [ $(($(date +%s) - m)) -le "$FM_SBX_GUEST_ACTIVE_WINDOW" ] || exit 0
        why="the VM's connection dropped while in-guest work was active"
        ;;
    esac
    sleep "$FM_SBX_MIDTASK_STOP_SETTLE"
    case "$(fm_backend_sbx_state "$name")" in
      stopped|absent) printf '%s\n' "$why" > "$marker" 2>/dev/null || true ;;
    esac
    exit 0
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

# --- steering: resurrection + delivery (design §8.3) -------------------------

# fm_backend_sbx_guest_tmux_ready: 0 when the guest tmux server is up with the
# expected session. Runs `sbx exec`, so callers must only use it when they
# intend to (re)start the sandbox anyway - this is a steering primitive, not a
# probe (probes use fm_backend_sbx_state).
fm_backend_sbx_guest_tmux_ready() {  # <name>
  sbx exec "$1" -- tmux has-session -t "$FM_SBX_GUEST_SESSION" >/dev/null 2>&1
}

# fm_backend_sbx_ensure_stack: make <target> deliverable, resurrecting the
# guest stack when auto-stop killed it. Auto-stop kills the guest PROCESS TREE
# (agent, tmux server, in-guest daemons); only disk state survives. Sequence:
#   1. refuse a confirmed-absent/unreadable sandbox (rc 1 - nothing to steer);
#   2. `sbx exec` starts a stopped VM as a side effect of the tmux-ready check;
#   3. no tmux server -> rebuild: new tmux session at the recorded home,
#      relaunch the agent with its harness's RESUME command, wait
#      FM_SBX_RESURRECT_SETTLE for the composer, then let the caller deliver.
# In-guest daemons a workflow needs (e.g. the no-mistakes daemon) do NOT come
# back on VM start; the resumed agent restarts them on demand - its brief owns
# that knowledge, not this transport.
fm_backend_sbx_ensure_stack() {  # <target>
  local target=$1 name id meta harness home turnend beat resume fg signals_dir
  local ready_prev ready_now ready_i
  name=$(fm_backend_sbx_name_of_target "$target")
  case "$(fm_backend_sbx_state "$name")" in
    running|stopped) ;;
    absent) echo "error: sandbox $name is not steerable (confirmed absent from the inventory)" >&2; return 1 ;;
    *)
      # NOT a confirmed absence: the inventory itself was unreadable, so this
      # caller has no route to the control plane (a denied daemon socket, or a
      # missing sbx/jq). Naming the two apart matters operationally - absent
      # means the sandbox is gone, unreadable means the CALLER cannot see it
      # and a steer from a context that can reach the daemon would still work.
      echo "error: sandbox $name is not steerable (sbx inventory unreadable from this context; the sbx daemon may be unreachable here)" >&2
      return 1
      ;;
  esac
  if fm_backend_sbx_guest_tmux_ready "$name"; then
    return 0
  fi
  id=$(fm_backend_sbx_task_of_target "$target") || {
    echo "error: cannot resurrect $name: no fm-<id> task naming to resolve meta from" >&2
    return 1
  }
  meta="$(fm_backend_sbx_state_dir)/$id.meta"
  harness=$(fm_meta_get "$meta" harness)
  home=$(fm_meta_get "$meta" home)
  if [ -z "$harness" ] || [ -z "$home" ]; then
    echo "error: cannot resurrect $name: meta $meta lacks harness=/home=" >&2
    return 1
  fi
  signals_dir="$FM_SBX_SIGNALS_ROOT/$id"
  turnend="$signals_dir/$id.turn-ended"
  beat="$signals_dir/$id.beat"
  resume=$(fm_backend_sbx_resume_template "$harness" "$turnend" "$beat") || {
    echo "error: cannot resurrect $name: no resume template for harness '$harness'" >&2
    return 1
  }
  # Re-assert the guest home's provisioned read path before relaunching the
  # agent (guest-home provisioning design §4.3): idempotent, heals guest-side
  # symlink/marker damage, and picks up FM_INHERITABLE_CONFIG items declared
  # since spawn. Resurrect-only cost - routine supervision and live-stack
  # delivery never spend this exec.
  fm_backend_sbx_provision_guest_home "$name" "$home" "$id" "$signals_dir" || {
    echo "error: cannot resurrect $name: guest-home provisioning re-assert failed" >&2
    return 1
  }
  # Tracked-file sync (fork issue #20): advance the guest clone's tracked
  # files to the host clone's default-branch tip before the agent relaunches -
  # the one point in the VM lifecycle where nothing in-guest can be mid-turn.
  # A skip (dirty, diverged, bundle failure) never blocks resurrection: the
  # steer is the priority, and the sweep paths (fm-update.sh, the bootstrap
  # secondmate sweep) report guest staleness durably.
  fm_backend_sbx_tracked_sync "sandbox $name guest" "$name" "$id" "$home" "$meta" resurrect >&2 || true
  sbx exec "$name" -- tmux new-session -d -s "$FM_SBX_GUEST_SESSION" -n "$name" -c "$home" || return 1
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" -l "$resume" || return 1
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" Enter || return 1
  sleep "$FM_SBX_RESURRECT_SETTLE"
  # A resume that dies (bad flags, missing session) drops the pane back to
  # the guest shell, and "delivering" the caller's message there would
  # EXECUTE it as a shell command on the guest (observed live before this
  # check existed). One cheap foreground-process read separates the two: a
  # shell name (or an unreadable pane) means the harness never took the
  # pane, so fail loudly and deliver nothing. Rebuild-path only - the
  # tmux-ready fast path above keeps v1's documented no-read-back posture.
  fg=$(sbx exec "$name" -- tmux display-message -p -t "$(fm_backend_sbx_guest_tmux_target "$name")" '#{pane_current_command}' 2>/dev/null) || fg=
  case "$fg" in
    ''|bash|sh|dash|zsh|ash)
      echo "error: resurrection of $name did not bring harness '$harness' up (pane foreground: ${fg:-unreadable}); refusing to deliver into a dead pane" >&2
      return 1
      ;;
  esac
  # The foreground check proves the harness PROCESS took the pane, not that
  # its TUI accepts input yet: codex's resume spends seconds redrawing the
  # restored conversation and DROPS keys typed into that window (observed
  # live - the fg check passed at settle+8s and the steer vanished into the
  # redraw). Readiness is two consecutive identical pane captures - the same
  # stability idiom the watcher uses for idleness - so no per-harness UI
  # signature is needed. A pane still changing past the cap (e.g. the agent
  # resumed busy) falls through and delivers anyway: a live TUI queues input.
  ready_prev=
  ready_i=0
  while [ "$ready_i" -lt "$FM_SBX_RESURRECT_READY_TRIES" ]; do
    ready_now=$(sbx exec "$name" -- tmux capture-pane -p -t "$(fm_backend_sbx_guest_tmux_target "$name")" -S -5 2>/dev/null) || ready_now=
    if [ -n "$ready_now" ] && [ "$ready_now" = "$ready_prev" ]; then
      break
    fi
    ready_prev=$ready_now
    ready_i=$((ready_i + 1))
    sleep 2
  done
  return 0
}

# Every successful delivery is followed by a fire-and-forget keep-alive: the
# delivered text (a steer, or fm-spawn's launch command - the spawn's sends
# dispatch through these same functions) starts a guest turn, and without a
# pinned connection the auto-stop would kill that turn mid-work (see
# fm_backend_sbx_keepalive). The recorded home= rides along so the keeper's
# guest loop can watch the guest home's state/ for child-worker signal
# advances; an absent meta simply skips that secondary probe. A non-fm-* name
# has no derivable id/signal path, so no keeper - nothing host-side would
# ever see its turn end anyway.
fm_backend_sbx_send_keepalive() {  # <target>
  local target=$1 id home
  id=$(fm_backend_sbx_task_of_target "$target") || return 0
  home=$(fm_meta_get "$(fm_backend_sbx_state_dir)/$id.meta" home) || home=
  fm_backend_sbx_keepalive "$(fm_backend_sbx_name_of_target "$target")" "$id" "$home"
}

fm_backend_sbx_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2 name
  fm_backend_sbx_ensure_stack "$target" || return 1
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" "$key" || return 1
  fm_backend_sbx_send_keepalive "$target"
}

fm_backend_sbx_send_text_line() {  # <target> <text>
  local target=$1 text=$2 name
  fm_backend_sbx_ensure_stack "$target" || return 1
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" "$text" Enter || return 1
  fm_backend_sbx_send_keepalive "$target"
}

fm_backend_sbx_send_literal() {  # <target> <text>
  local target=$1 text=$2 name
  fm_backend_sbx_ensure_stack "$target" || return 1
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" -l "$text" || return 1
  fm_backend_sbx_send_keepalive "$target"
}

# fm_backend_sbx_send_text_submit: type, submit, VERIFY, retry - echo a
# verdict. Verification reads the pane back after Enter, which the first v1
# cut skipped to save a capture exec per steer; the live rig proved it
# necessary: a freshly resumed codex TUI shows stable-looking notices that
# swallow the first keystrokes nondeterministically, so a fire-and-forget
# type+Enter can vanish without a trace while the very same keys land fine
# seconds later (verified live, twice). The check distinguishes the two
# swallow modes: text absent from the pane -> retype from scratch; text
# still sitting in the composer (Enter eaten, pane not busy) -> re-send
# Enter only, never retype (fm-send's no-double-text rule). Only a newly
# visible needle plus the busy signature counts as submitted; ambiguous
# exhausted retries report unknown instead of cleanly claiming delivery.
# Presence means NEWLY appeared, not merely visible: steers routinely share
# the needle prefix (the from-firstmate marker plus a repeated verb), and a
# prior steer's rendered line can stay in captured scrollback.
# Verified live in the 5-secondmate soak: a freshly resumed codex ate the
# typed text, the previous turn's steer line matched the needle, and the
# loop re-Entered an empty composer to a clean "sent" exit while the steer
# was lost. The occurrence count is baselined before typing (one extra
# capture exec per steer); only a count above the baseline is treated as
# composer text.
fm_backend_sbx_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=${3:-3} enter_sleep=${4:-0.4} settle=${5:-1}
  local name pane_t probe base_pane pane tries typed base cur busy
  fm_backend_sbx_ensure_stack "$target" || { printf 'send-failed'; return 1; }
  name=$(fm_backend_sbx_name_of_target "$target")
  pane_t=$(fm_backend_sbx_guest_tmux_target "$name")
  # The verification needle: a text-distinctive prefix long enough to not
  # false-match, short enough to survive composer line-wrapping. Bash
  # substring, not cut -c: the from-firstmate marker is multibyte and a
  # byte-split needle would never match the pane.
  probe=${text//$'\n'/ }
  probe=${probe:0:24}
  # Baseline AFTER ensure_stack: a resume's history re-render repaints old
  # steer lines, and a pre-redraw baseline would attribute them to our type.
  # ensure_stack's ready poll has already settled the pane here.
  base_pane=$(sbx exec "$name" -- tmux capture-pane -p -t "$pane_t" -S - 2>/dev/null) \
    || { printf 'send-failed'; return 1; }
  base=$(printf '%s' "$base_pane" | grep -cF -- "$probe") || base=0
  case "$base" in ''|*[!0-9]*) base=0 ;; esac
  typed=0
  tries=0
  while [ "$tries" -le "$retries" ]; do
    if [ "$typed" -eq 0 ]; then
      sbx exec "$name" -- tmux send-keys -t "$pane_t" -l "$text" \
        || { printf 'send-failed'; return 1; }
      typed=1
    fi
    sbx exec "$name" -- tmux send-keys -t "$pane_t" Enter \
      || { printf 'send-failed'; return 1; }
    sleep "$settle"
    pane=$(sbx exec "$name" -- tmux capture-pane -p -t "$pane_t" -S - 2>/dev/null) || pane=
    if [ -n "$pane" ]; then
      cur=$(printf '%s' "$pane" | grep -cF -- "$probe") || cur=0
      case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
      busy=0
      printf '%s' "$pane" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "${FM_BUSY_REGEX:-esc (to )?interrupt|Working\.\.\.}" && busy=1
      if [ "$cur" -gt "$base" ]; then
        # Text NEWLY visible: submitted if the harness is busy on it;
        # otherwise it is still sitting in the composer - loop re-sends
        # Enter only.
        if [ "$busy" -eq 1 ]; then
          fm_backend_sbx_send_keepalive "$target"
          printf 'submitted'
          return 0
        fi
      elif [ "$tries" -lt "$retries" ]; then
        # No occurrence beyond the baseline: the type vanished unsubmitted
        # (a resume-time notice ate it), and any needle match is a stale
        # scrollback line. Clear partial composer state and retype.
        sbx exec "$name" -- tmux send-keys -t "$pane_t" C-u || true
        typed=0
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -le "$retries" ] && sleep "$enter_sleep"
  done
  # Out of retries with no positive confirmation: the last state read is
  # ambiguous (unreadable pane, or text present but the busy footer never
  # showed). Deliver the conservative verdict and let the caller's fallback
  # policy own it - the text was never typed twice.
  fm_backend_sbx_send_keepalive "$target"
  printf 'unknown'
}

# --- provisioning (fm-spawn.sh's sbx branch) ---------------------------------

# fm_backend_sbx_create_task: create the secondmate's clone-mode sandbox with
# the signal-bridge mount, verify the guest can host the stack, and start the
# in-guest tmux session the launch lands in. The home must be a git checkout
# (clone mode clones it into the VM at the SAME absolute path; only committed
# files arrive - the brief copy and signal wiring are fm-spawn's job).
# FM_SBX_TEMPLATE optionally pins a template image (stock agent images may
# lack tmux, which is refused loudly here) and FM_SBX_AGENT optionally pins
# the agent flavor independently of the driver harness (above). Resolution
# runs FIRST so an unusable flavor/driver pairing refuses before any sandbox,
# signal directory, or guest state exists.
fm_backend_sbx_create_task() {  # <name> <home-abs> <harness> <signals-dir>
  local name=$1 home_abs=$2 harness=$3 signals_dir=$4 agent
  agent=$(fm_backend_sbx_agent_for_harness "$harness") || return 1
  # sbx clone mode refuses linked git worktrees outright ("--clone is not
  # supported when run from a Git worktree", verified live) - and secondmate
  # homes can be exactly that (treehouse-leased homes). Refuse first with the
  # fm-side rule: an sbx secondmate home must be a PLAIN clone (fm-home-seed's
  # git-clone path), never a linked worktree whose .git is a file.
  if [ -f "$home_abs/.git" ]; then
    echo "error: home $home_abs is a linked git worktree (.git is a file); sbx clone mode needs a plain-clone home - seed one with fm-home-seed.sh <id> <path> instead of a treehouse lease (docs/sbx-backend.md)" >&2
    return 1
  fi
  if [ "$(fm_backend_sbx_state "$name")" != absent ]; then
    echo "error: sandbox $name already exists (or sbx state is unreadable); refusing to create over it" >&2
    return 1
  fi
  mkdir -p "$signals_dir" || return 1
  if [ -n "${FM_SBX_TEMPLATE:-}" ]; then
    sbx create --clone --name "$name" -t "$FM_SBX_TEMPLATE" "$agent" "$home_abs" "$signals_dir" >&2 || return 1
  else
    sbx create --clone --name "$name" "$agent" "$home_abs" "$signals_dir" >&2 || return 1
  fi
  # Right after create, prove the clone-mode RO source mount is where the
  # guest-home provisioning pass expects it: the path is an sbx
  # implementation detail, so version drift must be a loud refusal here, not
  # a secondmate whose read-through inheritance silently dangles forever
  # (half-provisioned is worse than no sandbox). AGENTS.md is the one file
  # every firstmate home commits, so its readability proves the mount.
  if ! sbx exec "$name" -- test -r "$FM_SBX_SOURCE_MOUNT/AGENTS.md"; then
    echo "error: sandbox $name has no readable clone-mode source mount at $FM_SBX_SOURCE_MOUNT; guest-home provisioning depends on it (if sbx moved the mount, set FM_SBX_SOURCE_MOUNT; agent-dotfiles docs/firstmate-sbx-guest-home-provisioning.md)" >&2
    return 1
  fi
  if ! sbx exec "$name" -- sh -c 'command -v tmux >/dev/null 2>&1'; then
    echo "error: sandbox $name's template has no tmux; the sbx backend needs an in-guest tmux (pin FM_SBX_TEMPLATE to a template that ships it)" >&2
    return 1
  fi
  sbx exec "$name" -- tmux new-session -d -s "$FM_SBX_GUEST_SESSION" -n "$name" -c "$home_abs" || return 1
  return 0
}

# fm_backend_sbx_guest_write: write stdin to <guest-path> inside the sandbox,
# creating parent directories. Used by fm-spawn to place the brief copy (and
# claude's Stop hook) inside the clone - gitignored files never arrive via
# clone mode, so the private surface a launch needs is seeded explicitly.
fm_backend_sbx_guest_write() {  # <name> <guest-path>
  local name=$1 path=$2
  # shellcheck disable=SC2016  # single quotes deliberate: $1 expands in the guest sh, not here
  sbx exec -i "$name" -- sh -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' _ "$path"
}

# fm_backend_sbx_provision_guest_home: the guest-home provisioning pass
# (agent-dotfiles docs/firstmate-sbx-guest-home-provisioning.md §4). Clone
# mode carries committed files only, so the home's private (gitignored)
# surface is rebuilt in-guest as a READ PATH, not a copy pipeline: each
# declared FM_INHERITABLE_CONFIG item and the shared captain file become
# symlinks onto the clone-mode RO source mount - the live host home the
# convergence points (spawn, bootstrap sweep, fm-config-push) already write -
# so every host-side convergence point keeps the guest's inheritance target in
# one place. The RO source mount is not a runtime delivery channel; it can lag
# host writes after VM lifecycle changes, so proven-live handoff data rides the
# signal bridge instead (docs/sbx-backend.md). A primary-cleared item reads
# ABSENT through its dangling link ([ -f ] fails), byte-for-byte the inherit
# lib's absence mirroring. The .fm-secondmate-home identity marker is the one
# residue seeded as a REGULAR file (fm_root_is_secondmate_home hard-refuses
# [ -L ]), content = the task id. .fm-sbx-signals-dir is a second regular-file
# marker, content = the signal-bridge dir's absolute path: the guest user is
# `agent`, not the host user, so the guest cannot reconstruct
# FM_SBX_SIGNALS_ROOT/<id> from its own $HOME - this marker is how
# bin/fm-backlog-ingest.sh (and any future guest-side signal-bridge consumer)
# finds its own bind mount without guessing. One idempotent exec; spawn runs it
# after the brief seed, and resurrection re-runs it before relaunching the
# agent - healing guest-side link/marker damage (self-blinding only, the mount
# stays RO) and picking up FM_INHERITABLE_CONFIG items declared since spawn.
#
# The same pass also plants the guest shell-profile env snippet
# (docs/sbx-backend.md "Guest shell-profile env"). sbx plants
# CLAUDE_CODE_OAUTH_TOKEN into the guest env once, at sandbox creation, and the
# claude agent does NOT pass it down to the processes it spawns - so an in-guest
# daemon started by the agent (the no-mistakes daemon, observed live 2026-07-23)
# comes up unauthenticated and 401s, while interactive sessions in the same VM
# authenticate fine. The snippet re-supplies it at shell init, which is the only
# seam a stripped child ever crosses. Three properties make that safe:
#   - The value is a PLACEHOLDER, not a credential: the real token is swapped in
#     host-side at the sbx proxy and never enters the VM (agent-dotfiles
#     docs/docker-sandboxes-fit-assessment.md, evidence chain items 1 and 4), so
#     persisting it to a guest file discloses nothing.
#   - It is read from THIS exec's own guest env, never passed as an argument, so
#     the value never reaches the host process table or any host-side log.
#   - Assignment is `:=`, so an operator's own already-set value always wins,
#     whatever the ordering.
# The snippet is sourced from the TOP of each profile, ahead of the stock
# Debian `~/.bashrc` early return for non-interactive shells - the failing case
# is a non-interactive agent child, and an appended export would never run.
fm_backend_sbx_provision_guest_home() {  # <name> <home-abs> <id> <signals-dir>
  local name=$1 home_abs=$2 id=$3 signals_dir=$4
  # shellcheck disable=SC2016  # single quotes deliberate: $1..$5, $HOME, $CLAUDE_CODE_OAUTH_TOKEN and the loops expand in the guest sh, not here
  # shellcheck disable=SC2086  # deliberate word split: FM_INHERITABLE_CONFIG is a declared space-separated list (items never contain whitespace)
  sbx exec "$name" -- sh -c '
    home=$1 src=$2 id=$3 captain=$4 signals=$5; shift 5
    cd "$home" || exit 1
    mkdir -p config data || exit 1
    for item; do
      ln -sfn "$src/config/$item" "config/$item" || exit 1
    done
    ln -sfn "$src/$captain" "$captain" || exit 1
    rm -f .fm-secondmate-home || exit 1
    printf "%s\n" "$id" > .fm-secondmate-home || exit 1
    rm -f .fm-sbx-signals-dir || exit 1
    printf "%s\n" "$signals" > .fm-sbx-signals-dir || exit 1
    tok=${CLAUDE_CODE_OAUTH_TOKEN:-}
    case $tok in *[!A-Za-z0-9._:/+=-]*) tok= ;; esac
    if [ -n "$tok" ] && [ -n "${HOME:-}" ]; then
      snip=$HOME/.fm-sbx-env.sh
      {
        echo "# Managed by firstmate sbx guest provisioning; rewritten on every"
        echo "# spawn and resurrection (docs/sbx-backend.md). Do not edit."
        printf ": \"\${CLAUDE_CODE_OAUTH_TOKEN:=%s}\"\n" "$tok"
        echo "export CLAUDE_CODE_OAUTH_TOKEN"
      } > "$snip" && chmod 600 "$snip" 2>/dev/null
      seed_line="if [ -r \"\$HOME/.fm-sbx-env.sh\" ]; then . \"\$HOME/.fm-sbx-env.sh\"; fi  # firstmate sbx guest env"
      for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        case $f in *.bash_profile) [ -f "$f" ] || continue ;; esac
        [ -e "$f" ] || : > "$f"
        if grep -F ".fm-sbx-env.sh" "$f" 2>/dev/null | grep -vF "$seed_line" >/dev/null; then
          printf "%s\n" "firstmate sbx: $f may not reach non-interactive shells because an unowned .fm-sbx-env.sh source line was found; not moving operator content" >&2
          continue
        fi
        seed_line_no=$(grep -nF "$seed_line" "$f" 2>/dev/null | head -n 1 | cut -d: -f1)
        first_code_no=$(grep -n -v "^[[:space:]]*\($\|#\)" "$f" 2>/dev/null | head -n 1 | cut -d: -f1)
        if [ -n "$seed_line_no" ] && { [ -z "$first_code_no" ] || [ "$seed_line_no" -le "$first_code_no" ]; }; then
          continue
        fi
        {
          printf "%s\n" "$seed_line"
          grep -vF "$seed_line" "$f" || :
        } > "$f.fm-sbx-tmp" && cat "$f.fm-sbx-tmp" > "$f"
        rm -f "$f.fm-sbx-tmp"
      done
    fi
    exit 0
  ' _ "$home_abs" "$FM_SBX_SOURCE_MOUNT" "$id" "$FM_SHARED_CAPTAIN_REL" "$signals_dir" $FM_INHERITABLE_CONFIG
}

# --- tracked-file sync (guest clone fast-forward) -----------------------------
#
# Clone mode snapshots the host home's COMMITTED files into the VM exactly once,
# at provisioning, so the guest clone's tracked surface (AGENTS.md, bin/,
# .agents/skills/) freezes at spawn HEAD while every host-side sync path
# advances only the HOST clone (fork issue #20). fm_backend_sbx_tracked_sync
# closes that gap by fast-forwarding the guest clone itself, mirroring
# ff_target's guards (bin/fm-ff-lib.sh) inside the VM: ff-only, never
# force/merge/stash, skip a dirty, diverged, or wrong-branch guest with a
# printed reason, and never touch the gitignored operational dirs.
#
# Update content travels as a git BUNDLE on the signal-bridge mount - the only
# host<->guest surface proven live in both directions regardless of VM
# lifecycle - with the host clone as the source of truth. The clone-mode RO
# source mount is NEVER a sync source: it can lag host reality by hours after
# a stop/resurrect cycle (docs/sbx-backend.md "Backlog handoff", issue #11).
# The guest side needs only plain git (the same guarantee the teardown
# landed-work probe already relies on), so the first sync into a guest that
# PREDATES this mechanism needs nothing new inside the VM.

# fm_backend_sbx_default_branch: <dir>'s default branch. Duplicated from
# fm-ff-lib.sh's default_branch (namespaced) because this adapter is sourced
# standalone by fm-send/fm-crew-state, where sourcing the ff lib would clobber
# a host script's own same-named helpers - the shell_quote precedent above.
fm_backend_sbx_default_branch() {  # <dir>
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s' "$branch"
      return 0
    fi
  done
  return 1
}

# fm_backend_sbx_sha_valid: 0 when <s> is a full 40-hex commit sha. Everything
# recorded into meta or compared against the host tip must pass this first:
# guest output is untrusted data (a compromised guest owns its own sh/git),
# and a newline-bearing "sha" would otherwise inject meta lines.
fm_backend_sbx_sha_valid() {  # <s>
  case "$1" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# fm_backend_sbx_record_guest_synced: atomically rewrite <meta> so its one
# sbx_guest_synced= line holds <sha> - the guest clone's last VERIFIED HEAD,
# only ever recorded from the guest's own report (spawn's post-create read, or
# a completed sync below). This host-private cache is what lets steady-state
# sweeps report "already current" with zero sbx CLI calls and zero VM churn.
fm_backend_sbx_record_guest_synced() {  # <meta> <sha>
  local meta=$1 sha=$2 dir tmp line
  fm_backend_sbx_sha_valid "$sha" || return 1
  [ -f "$meta" ] || return 1
  dir=$(dirname "$meta")
  tmp=$(mktemp "$dir/.fm-sbx-guest-synced.XXXXXX" 2>/dev/null) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      sbx_guest_synced=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; } ;;
    esac
  done < "$meta"
  printf 'sbx_guest_synced=%s\n' "$sha" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta"
}

# fm_backend_sbx_tracked_sync: fast-forward <name>'s guest clone to the host
# clone's default-branch tip, printing exactly one ff_target-vocabulary
# outcome line ("<label>: updated a..b" / "<label>: already current" /
# "<label>: skipped: <reason>") - callers classify on that line. Always
# returns 0 - a skip is a reported outcome, never a caller failure.
#
# mode selects the safe-point policy (never sync mid-turn):
#   resurrect - the caller (ensure_stack) already holds the VM at the
#               pre-agent-relaunch point; no state gate.
#   sweep     - fm-update.sh / the bootstrap secondmate sweep: a STOPPED VM is
#               the safe point (the agent process tree is dead; the sync exec
#               auto-starts the VM, which auto-stops again after). A running
#               VM may be mid-turn and is skipped with the honest reason -
#               its update lands at the next resurrection. Absent/unreadable
#               skip too (the liveness sweep owns re-provisioning).
#
# The sbx_guest_synced= cache short-circuits BEFORE any state probe or exec,
# so a current guest costs nothing anywhere. A hostile guest faking the
# verdict line can only mis-record its own staleness - self-harm, the same
# class as a guest deleting its own provisioning links.
fm_backend_sbx_tracked_sync() {  # <label> <name> <id> <home> <meta> <resurrect|sweep>
  local label=$1 name=$2 id=$3 home=$4 meta=$5 mode=$6
  local signals default want synced state tracked tmp bundle_path raw out reason
  local old new short_old short_new f

  if [ ! -d "$home" ] || ! git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: host clone is not a git repo"
    return 0
  fi
  default=$(fm_backend_sbx_default_branch "$home") || {
    echo "$label: skipped: cannot determine the host clone's default branch"
    return 0
  }
  want=$(git -C "$home" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null) || want=
  if ! fm_backend_sbx_sha_valid "$want"; then
    echo "$label: skipped: cannot resolve the host clone's $default tip"
    return 0
  fi

  synced=$(fm_meta_get "$meta" sbx_guest_synced)
  if [ -n "$synced" ] && [ "$synced" = "$want" ]; then
    echo "$label: already current"
    return 0
  fi

  if [ "$mode" = sweep ]; then
    state=$(fm_backend_sbx_state "$name")
    case "$state" in
      stopped) ;;
      running)
        echo "$label: skipped: guest VM is running (never synced mid-turn); the update lands at its next restart"
        return 0
        ;;
      absent)
        echo "$label: skipped: sandbox is absent"
        return 0
        ;;
      *)
        echo "$label: skipped: sandbox state is unreadable"
        return 0
        ;;
    esac
  fi

  signals=$(fm_meta_get "$meta" sbx_signals_dir)
  [ -n "$signals" ] || signals="$FM_SBX_SIGNALS_ROOT/$id"
  if [ ! -d "$signals" ]; then
    echo "$label: skipped: signal-bridge dir is missing at $signals"
    return 0
  fi
  tracked="$signals/tracked-sync"
  mkdir -p "$tracked" 2>/dev/null || {
    echo "$label: skipped: cannot create $tracked"
    return 0
  }
  chmod 0755 "$tracked" 2>/dev/null || true
  # One self-contained bundle per host tip, staged tmp+mv so the guest can
  # never read a torn file, world-readable because the guest user (`agent`)
  # is not the host user. ~7 MB per actual update event today - created only
  # on a cache miss, reused across retries of the same tip.
  bundle_path="$tracked/host-$want.bundle"
  if [ ! -f "$bundle_path" ]; then
    tmp=$(mktemp "$tracked/.bundle.XXXXXX" 2>/dev/null) || {
      echo "$label: skipped: cannot stage the update bundle"
      return 0
    }
    if ! git -C "$home" bundle create "$tmp" "refs/heads/$default" >/dev/null 2>&1; then
      rm -f "$tmp"
      echo "$label: skipped: bundle creation failed on the host clone"
      return 0
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$bundle_path" || {
      rm -f "$tmp"
      echo "$label: skipped: cannot publish the update bundle"
      return 0
    }
  fi

  # The in-guest guarded fast-forward: plain git only, the bundle read at the
  # SAME absolute path through the signal-bridge mount. Guards mirror
  # ff_target's, in its order: wrong branch, dirty (tolerating ONLY the two
  # untracked seeded markers, whose .gitignore entries a pre-fix guest's
  # snapshot may predate - the ignore_seed_marker upgrade tolerance), current,
  # diverged/unique commits (is-ancestor), then merge --ff-only. Detached HEAD
  # is allowed, matching the secondmate-home ff contract. Every verdict rides
  # one "fm-sync ..." line so sbx auto-start chatter can never fake a result.
  # shellcheck disable=SC2016  # single quotes deliberate: $1..$4 expand in the guest sh, not here
  raw=$(sbx exec "$name" -- sh -c '
    home=$1 bundle=$2 default=$3 want=$4
    if ! git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "fm-sync skipped: guest home is not a git repo"; exit 0
    fi
    cur=$(git -C "$home" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
    if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
      echo "fm-sync skipped: guest clone is on $cur, expected $default"; exit 0
    fi
    dirty=$(git -C "$home" status --porcelain 2>/dev/null \
      | grep -v -e "^?? .fm-secondmate-home$" -e "^?? .fm-sbx-signals-dir$" | head -1)
    if [ -n "$dirty" ]; then
      echo "fm-sync skipped: dirty guest working tree"; exit 0
    fi
    head=$(git -C "$home" rev-parse HEAD 2>/dev/null)
    if [ -z "$head" ]; then echo "fm-sync skipped: cannot read guest HEAD"; exit 0; fi
    if [ "$head" = "$want" ]; then echo "fm-sync current $head"; exit 0; fi
    if [ ! -r "$bundle" ]; then
      echo "fm-sync skipped: update bundle is not readable in the guest"; exit 0
    fi
    if ! git -C "$home" fetch --quiet "$bundle" "refs/heads/$default" 2>/dev/null; then
      echo "fm-sync skipped: bundle fetch failed in the guest"; exit 0
    fi
    got=$(git -C "$home" rev-parse --verify --quiet FETCH_HEAD 2>/dev/null || echo "")
    if [ "$got" != "$want" ]; then
      echo "fm-sync skipped: bundle tip does not match the host clone"; exit 0
    fi
    if ! git -C "$home" merge-base --is-ancestor "$head" "$want" 2>/dev/null; then
      echo "fm-sync skipped: guest clone diverged from the host clone"; exit 0
    fi
    if ! git -C "$home" merge --ff-only "$want" >/dev/null 2>&1; then
      echo "fm-sync skipped: fast-forward failed in the guest"; exit 0
    fi
    new=$(git -C "$home" rev-parse HEAD 2>/dev/null)
    if [ "$new" != "$want" ]; then
      echo "fm-sync skipped: fast-forward did not land"; exit 0
    fi
    echo "fm-sync updated $head $new"
  ' _ "$home" "$bundle_path" "$default" "$want" 2>/dev/null) || raw=
  out=$(printf '%s\n' "$raw" | grep '^fm-sync ' | tail -1)

  case "$out" in
    'fm-sync updated '*)
      # shellcheck disable=SC2086  # deliberate word split: the verdict is space-delimited
      set -- $out
      old=${3:-}
      new=${4:-}
      if ! fm_backend_sbx_sha_valid "$old" || [ "$new" != "$want" ]; then
        echo "$label: skipped: unrecognized guest response"
        return 0
      fi
      fm_backend_sbx_record_guest_synced "$meta" "$new" || true
      for f in "$tracked"/host-*.bundle; do
        [ -e "$f" ] || continue
        [ "$f" = "$bundle_path" ] || rm -f "$f"
      done
      short_old=$(git -C "$home" rev-parse --short "$old" 2>/dev/null) || short_old=$(printf '%s' "$old" | cut -c1-7)
      short_new=$(git -C "$home" rev-parse --short "$new" 2>/dev/null) || short_new=$(printf '%s' "$new" | cut -c1-7)
      echo "$label: updated $short_old..$short_new"
      ;;
    'fm-sync current '*)
      # shellcheck disable=SC2086  # deliberate word split: the verdict is space-delimited
      set -- $out
      if [ "${3:-}" != "$want" ]; then
        echo "$label: skipped: unrecognized guest response"
        return 0
      fi
      fm_backend_sbx_record_guest_synced "$meta" "$want" || true
      for f in "$tracked"/host-*.bundle; do
        [ -e "$f" ] || continue
        [ "$f" = "$bundle_path" ] || rm -f "$f"
      done
      echo "$label: already current"
      ;;
    'fm-sync skipped: '*)
      # Untrusted guest text: keep only a bounded printable subset before it
      # reaches host logs or wake surfaces.
      reason=$(printf '%s' "${out#fm-sync skipped: }" | tr -cd 'a-zA-Z0-9 .,:_/()-' | cut -c1-160)
      echo "$label: skipped: ${reason:-unrecognized guest response}"
      ;;
    *)
      echo "$label: skipped: no verdict from the guest (exec failed or produced no fm-sync line)"
      ;;
  esac
  return 0
}
