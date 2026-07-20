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
# guest agent's current turn to end (fm_backend_sbx_keepalive). 0 disables
# keep-alives entirely (unit tests do).
FM_SBX_KEEPALIVE_MAX=${FM_SBX_KEEPALIVE_MAX:-7200}

# In-guest tmux session name. One secondmate per sandbox, so a fixed session
# name with the task's fm-<id> window is unambiguous within each VM.
FM_SBX_GUEST_SESSION=${FM_SBX_GUEST_SESSION:-fm}

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

fm_backend_sbx_agent_for_harness() {  # <harness>
  case "$1" in
    claude) printf 'claude' ;;
    codex)  printf 'codex' ;;
    *)
      echo "error: harness '$1' is not verified on the sbx backend (supported: claude codex)" >&2
      return 1
      ;;
  esac
}

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

# --- keep-alive: pin the VM through a guest turn -----------------------------

# fm_backend_sbx_keepalive: hold ONE background `sbx exec` open until <id>'s
# turn-ended mount file advances past its current mtime (the guest agent
# finished the turn) or FM_SBX_KEEPALIVE_MAX elapses. Why this exists:
# Docker Sandboxes' auto-stop is HOST-CONNECTION-based, not guest-workload-
# based - a VM with no live exec/attach stops within roughly a minute even
# with a CPU-busy guest process (verified live; a detached in-guest tmux
# agent gets no protection at all, unlike agent-as-exec rigs where the run
# IS the connection). Without a keeper, any launch or steered turn that
# outlasts the post-disconnect grace is killed mid-work: the turn never
# ends, no signal lands, and the secondmate silently freezes until the next
# steer resurrects it into the same trap. The keeper is the narrow fix: one
# connection, held exactly for the expected-work window, self-terminating on
# the guest side (it reads the same mount file at the same path), so an
# idle VM still auto-stops - design §8's stopped-is-healthy premise stays.
# Fire-and-forget: callers never wait on it, and a keeper left waiting by a
# turn that never comes is bounded by the cap. Multiple keepers (one per
# steer) are harmless - all exit on the same next turn-end.
fm_backend_sbx_keepalive() {  # <name> <id>
  local name=$1 id=$2 turnend
  [ "$FM_SBX_KEEPALIVE_MAX" -gt 0 ] 2>/dev/null || return 0
  turnend="$FM_SBX_SIGNALS_ROOT/$id/$id.turn-ended"
  # shellcheck disable=SC2016  # single quotes deliberate: $1/$2 expand in the guest sh loop, not here
  nohup sbx exec "$name" -- sh -c '
    t=$1 max=$2
    start=$(date +%s)
    base=$(stat -c %Y "$t" 2>/dev/null || echo 0)
    while :; do
      now=$(date +%s)
      [ $((now - start)) -ge "$max" ] && exit 0
      cur=$(stat -c %Y "$t" 2>/dev/null || echo 0)
      [ "$cur" -gt "$base" ] && exit 0
      sleep 5
    done' _ "$turnend" "$FM_SBX_KEEPALIVE_MAX" >/dev/null 2>&1 &
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
  local target=$1 name id meta harness home turnend beat resume fg
  local ready_prev ready_now ready_i
  name=$(fm_backend_sbx_name_of_target "$target")
  case "$(fm_backend_sbx_state "$name")" in
    running|stopped) ;;
    *) echo "error: sandbox $name is not steerable (absent or unreadable)" >&2; return 1 ;;
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
  turnend="$FM_SBX_SIGNALS_ROOT/$id/$id.turn-ended"
  beat="$FM_SBX_SIGNALS_ROOT/$id/$id.beat"
  resume=$(fm_backend_sbx_resume_template "$harness" "$turnend" "$beat") || {
    echo "error: cannot resurrect $name: no resume template for harness '$harness'" >&2
    return 1
  }
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
# fm_backend_sbx_keepalive). A non-fm-* name has no derivable id/signal
# path, so no keeper - nothing host-side would ever see its turn end anyway.
fm_backend_sbx_send_keepalive() {  # <target>
  local target=$1 id
  id=$(fm_backend_sbx_task_of_target "$target") || return 0
  fm_backend_sbx_keepalive "$(fm_backend_sbx_name_of_target "$target")" "$id"
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
# Enter only, never retype (fm-send's no-double-text rule). A pane that
# shows the busy signature or no longer shows the text after Enter counts
# as submitted.
# Presence means NEWLY appeared, not merely visible: steers routinely share
# the needle prefix (the from-firstmate marker plus a repeated verb), and a
# prior steer's rendered line stays inside the 30-line capture window.
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
  base_pane=$(sbx exec "$name" -- tmux capture-pane -p -t "$pane_t" -S -30 2>/dev/null) || base_pane=
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
    pane=$(sbx exec "$name" -- tmux capture-pane -p -t "$pane_t" -S -30 2>/dev/null) || pane=
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
# lack tmux, which is refused loudly here).
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
