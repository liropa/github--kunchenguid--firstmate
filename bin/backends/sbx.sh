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

# In-guest tmux session name. One secondmate per sandbox, so a fixed session
# name with the task's fm-<id> window is unambiguous within each VM.
FM_SBX_GUEST_SESSION=${FM_SBX_GUEST_SESSION:-fm}

fm_backend_sbx_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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
fm_backend_sbx_launch_template() {  # <harness>
  # shellcheck disable=SC2016  # single quotes deliberate: $(cat ...) expands in the guest pane
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)  printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__ __BEAT__\"]" "$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

# fm_backend_sbx_resume_template: the relaunch command resurrection uses after
# an auto-stop killed the agent. Session-resume mode, not a fresh brief: the
# agent's conversation state survives on the VM disk. claude's Stop hook
# survives in the clone's .claude/settings.local.json, so resume needs no
# re-wiring; codex's notify= must be re-supplied on the resume command.
fm_backend_sbx_resume_template() {  # <harness> <turnend> <beat>
  local harness=$1 turnend=$2 beat=$3
  case "$harness" in
    claude) printf '%s' 'claude --continue --dangerously-skip-permissions' ;;
    codex)  printf 'codex resume --last --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch %s %s\"]"' "$turnend" "$beat" ;;
    *) return 1 ;;
  esac
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
  local target=$1 name id meta harness home turnend beat resume
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
  return 0
}

fm_backend_sbx_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2 name
  fm_backend_sbx_ensure_stack "$target" || return 1
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" "$key"
}

fm_backend_sbx_send_text_line() {  # <target> <text>
  local target=$1 text=$2 name
  fm_backend_sbx_ensure_stack "$target" || return 1
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" "$text" Enter
}

fm_backend_sbx_send_literal() {  # <target> <text>
  local target=$1 text=$2 name
  fm_backend_sbx_ensure_stack "$target" || return 1
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" -l "$text"
}

# fm_backend_sbx_send_text_submit: type once, submit, echo a verdict. v1 does
# not read the guest composer back (that would spend a capture exec per
# verification round), so like zellij's adapter it reports `unknown` and the
# caller's conservative fallback policy owns the rest. Retries/enter-sleep/
# settle are accepted for dispatcher-signature parity.
fm_backend_sbx_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 settle=${5:-1} name
  fm_backend_sbx_ensure_stack "$target" || { printf 'send-failed'; return 1; }
  name=$(fm_backend_sbx_name_of_target "$target")
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" -l "$text" \
    || { printf 'send-failed'; return 1; }
  sbx exec "$name" -- tmux send-keys -t "$(fm_backend_sbx_guest_tmux_target "$name")" Enter \
    || { printf 'send-failed'; return 1; }
  sleep "$settle"
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
