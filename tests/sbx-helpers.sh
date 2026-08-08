#!/usr/bin/env bash
# tests/sbx-helpers.sh - shared fake `sbx` CLI for the sbx-backend suites
# (fm-backend-sbx and fm-spawn-sbx). The fake encodes sandbox-lifecycle
# behavior (a state inventory file behind `ls --json`, exec routing for the
# in-guest tmux calls, guest-write capture), so it lives here rather than in
# the generic tests/lib.sh - the same split secondmate-helpers.sh uses.
# Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# make_fake_sbx <dir>: install a fake `sbx` into <dir>/fakebin (echoed), plus a
# symlink to the REAL jq (the adapter's state probe parses `ls --json` with jq;
# callers should skip their suite when jq is absent, mirroring the herdr
# suites). Behavior is driven by env at call time:
#   FM_FAKE_SBX_LS_FILE      file whose contents `sbx ls --json` prints
#   FM_FAKE_SBX_LS_RC        non-zero makes `sbx ls` fail (CLI-error case)
#   FM_FAKE_SBX_LOG          every invocation appended as one "$*" line
#   FM_FAKE_SBX_TMUX_HAS_RC  exit code for `exec ... tmux has-session` (default 0)
#   FM_FAKE_SBX_CREATE_JSON  when set, `sbx create` overwrites LS_FILE with it
#                            (simulates the new sandbox appearing as running)
#   FM_FAKE_SBX_WRITE_DIR    when set, `exec -i ... sh -c 'mkdir ... cat > ...'`
#                            captures stdin to <dir>/<guest-path with / -> _>
#   FM_FAKE_SBX_CAPTURE      file `exec ... tmux capture-pane` prints
#   FM_FAKE_SBX_CAPTURE_FAIL_ONCE
#                            makes the first capture-pane return non-zero
#   FM_FAKE_SBX_TYPE_ECHO    when set (with FM_FAKE_SBX_CAPTURE), a literal
#                            `tmux send-keys ... -l <text>` appends <text> to
#                            the capture file - models a terminal that renders
#                            what was typed; unset = the type is eaten (the
#                            resume-time swallow)
#   FM_FAKE_SBX_TYPE_FAIL_ON  literal send ordinal that returns non-zero
#   FM_FAKE_SBX_ENTER_BUSY   appends the default busy footer on Enter
#   FM_FAKE_SBX_ENTER_BUSY_AFTER
#                            first Enter number that appends the busy footer
#   FM_FAKE_SBX_SEND_RC      non-zero makes tmux send-keys fail
#   FM_FAKE_SBX_ENTER_RC     non-zero makes only Enter send-keys fail
#   FM_FAKE_SBX_ACK_ON_ENTER file touched after a successful Enter send
#   FM_FAKE_SBX_ACK_ON_ENTER_ONCE
#                            touches the acknowledgement on the first Enter only
#   FM_FAKE_SBX_EXPECT_PENDING_DIR
#                            requires a pending delivery candidate on Enter
#   FM_FAKE_SBX_REQUIRE_FRESH_PENDING
#                            requires a different candidate for every Enter
#   FM_FAKE_SBX_FG           what `exec ... tmux display-message` prints as the
#                            pane's foreground process (default codex; set to
#                            bash to simulate a resume that died back to the
#                            guest shell)
#   FM_FAKE_SBX_GIT_STATUS   what `exec ... git -C <home> status --porcelain`
#                            prints (the teardown landed-work probe; empty =
#                            clean guest)
#   FM_FAKE_SBX_GIT_LOG      what `exec ... git -C <home> log ...` prints
#                            (empty = every commit already on a remote)
#   FM_FAKE_SBX_GIT_RC       non-zero makes the guest `git` calls fail (the
#                            unverifiable-guest case)
#   FM_FAKE_SBX_SOURCE_RC    exit code for the spawn-time source-mount probe
#                            (`exec ... test -r <mount>/AGENTS.md`; default 0 =
#                            the clone-mode RO mount is where sbx puts it)
#   FM_FAKE_SBX_PROVISION_RC non-zero fails the guest-home provisioning exec
#                            (the `sh -c` pass carrying `ln -sfn`) instead of
#                            executing it
#   FM_FAKE_SBX_GUEST_USER_HOME
#                            the guest USER's own $HOME (where the shell
#                            profiles live) for the provisioning exec, which is
#                            a different directory from the home clone. The
#                            fake ALWAYS overrides $HOME for that exec -
#                            defaulting to a scratch dir beside the log - so a
#                            suite can never write the real developer's shell
#                            profiles.
#   FM_FAKE_SBX_GUEST_ENV_TOKEN
#                            value the provisioning exec's guest env carries as
#                            CLAUDE_CODE_OAUTH_TOKEN (sbx plants the non-secret
#                            placeholder at sandbox creation). Unset = the guest
#                            sees the variable UNSET; the host's own credential
#                            env is never forwarded into a fixture.
#   FM_FAKE_SBX_GUEST_HOME   when set, in-guest home paths are REMAPPED to this
#                            directory before real execution: clone mode places
#                            the guest clone at the SAME absolute path as the
#                            host home but on the VM's own disk, and the remap
#                            models exactly that "same path, different disk"
#                            split (the tracked-sync and provisioning `sh -c`
#                            passes remap their home argument; `git -C <home>`
#                            runs real git against the remapped dir instead of
#                            the env-driven canned output)
#   FM_FAKE_SBX_SYNC_RC      non-zero fails the tracked-file sync exec (the
#                            `sh -c` pass carrying `merge --ff-only`) instead
#                            of executing it
#   FM_FAKE_SBX_KEEPALIVE_OUT
#                            what the keep-alive exec (the `sh -c` pass
#                            carrying `fm-keepalive`) prints as the guest
#                            loop's verdict; unset = no output (the exec-died
#                            case the wrapper must classify)
#   FM_FAKE_SBX_KEEPALIVE_RC exit code for the keep-alive exec (default 0)
#   FM_FAKE_SBX_TRUST_SEED_RC
#                            non-zero fails the claude workspace-trust reconcile
#                            exec (the `sh -c` pass naming
#                            .no-mistakes/worktrees) instead of executing it.
#                            That exec writes the guest USER's ~/.claude.json,
#                            so it uses FM_FAKE_SBX_GUEST_USER_HOME and the same
#                            always-override $HOME rule.
#   FM_FAKE_SBX_NM_BIN       directory prepended to PATH for the no-mistakes
#                            daemon-restore exec (the `sh -c` pass naming
#                            `no-mistakes daemon status`). Put a fake
#                            `no-mistakes` there to pose a running / down /
#                            stale-socket / unrecognized guest; unset = the
#                            guest has no gate binary at all. That exec reads
#                            $HOME/.no-mistakes, so it uses
#                            FM_FAKE_SBX_GUEST_USER_HOME and the same
#                            always-override $HOME rule - a suite must never
#                            probe the developer's real daemon root.
#   FM_FAKE_SBX_NM_RC        non-zero fails that exec outright (the transport
#                            failure case) instead of executing it
#   FM_FAKE_SBX_DOCTOR_RC    non-zero fails the gate-vendor probe exec (the
#                            `sh -c` pass naming `no-mistakes doctor`) outright.
#                            That exec reuses FM_FAKE_SBX_NM_BIN and the same
#                            hermetic-PATH rule - a suite must never run the
#                            developer's real `no-mistakes doctor`.
make_fake_sbx() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$fakebin/jq"
  fi
  cat > "$fakebin/sbx" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_SBX_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_SBX_LOG"
# Retry ordinals still need per-fake persistence when a caller does not log.
fake_state=${FM_FAKE_SBX_LOG:-$0.state}
cmd=${1:-}
shift || true
case "$cmd" in
  ls)
    [ "${FM_FAKE_SBX_LS_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_LS_RC}"
    cat "${FM_FAKE_SBX_LS_FILE:?FM_FAKE_SBX_LS_FILE unset}"
    exit 0
    ;;
  create)
    if [ -n "${FM_FAKE_SBX_CREATE_JSON:-}" ]; then
      printf '%s\n' "$FM_FAKE_SBX_CREATE_JSON" > "${FM_FAKE_SBX_LS_FILE:?}"
    fi
    exit 0
    ;;
  rm|stop)
    exit 0
    ;;
  exec)
    interactive=0
    # Consume exec flags and the sandbox name; everything after -- is the
    # guest command line.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -i) interactive=1; shift ;;
        --) shift; break ;;
        *) shift ;;
      esac
    done
    # No element of a guest command may be empty. This is firstmate's own
    # invariant on every vector it builds, and it is enforced HERE - once, for
    # every suite - because `$*` joins the arguments and so cannot show an
    # empty one: a suite asserting the joined string passes whether or not the
    # vector is well formed, which is exactly how an empty element shipped.
    # It is also what the real API does: an empty element was reported live on
    # 2026-08-08 as `400 Bad Request: cmd element 10 is empty`, stopping every
    # resurrection of a secondmate with no data/captain-shared.md. That report
    # is host evidence relayed to this repo, not a run observed here, so the
    # wording below is deliberately the invariant, not a claimed API quote.
    empty_element=0
    for arg in "$@"; do
      [ -n "$arg" ] || empty_element=1
    done
    if [ "$empty_element" = 1 ]; then
      printf 'fake sbx: refusing exec: a guest command element is empty\n' >&2
      exit 1
    fi
    guest="$*"
    case "$guest" in
      "tmux has-session"*)
        exit "${FM_FAKE_SBX_TMUX_HAS_RC:-0}"
        ;;
      "tmux capture-pane"*)
        if [ -n "${FM_FAKE_SBX_CAPTURE_FAIL_ONCE:-}" ]; then
          marker="${FM_FAKE_SBX_CAPTURE:-$FM_FAKE_SBX_LOG}.capture-failed"
          if [ ! -e "$marker" ]; then
            : > "$marker"
            exit 1
          fi
        fi
        if [ -n "${FM_FAKE_SBX_CAPTURE:-}" ]; then
          start=
          prev=
          for arg in "$@"; do
            if [ "$prev" = -S ]; then
              start=$arg
              break
            fi
            prev=$arg
          done
          case "$start" in
            -[0-9]*) tail -n "${start#-}" "$FM_FAKE_SBX_CAPTURE" ;;
            *) cat "$FM_FAKE_SBX_CAPTURE" ;;
          esac
        fi
        exit 0
        ;;
      "tmux display-message"*)
        printf '%s\n' "${FM_FAKE_SBX_FG:-codex}"
        exit 0
        ;;
      "tmux send-keys"*)
        [ "${FM_FAKE_SBX_SEND_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_SEND_RC}"
        enter_count=0
        case "$guest" in
          *" -l "*)
            type_count_file="$fake_state.type-count"
            type_count=$(cat "$type_count_file" 2>/dev/null || echo 0)
            type_count=$((type_count + 1))
            printf '%s\n' "$type_count" > "$type_count_file"
            [ "$type_count" != "${FM_FAKE_SBX_TYPE_FAIL_ON:-0}" ] || exit 1
            ;;
          *" Enter")
            enter_count_file="$fake_state.enter-count"
            enter_count=$(cat "$enter_count_file" 2>/dev/null || echo 0)
            enter_count=$((enter_count + 1))
            printf '%s\n' "$enter_count" > "$enter_count_file"
            [ "${FM_FAKE_SBX_ENTER_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_ENTER_RC}"
            ;;
        esac
        if [ -n "${FM_FAKE_SBX_CAPTURE:-}" ]; then
          case "$guest" in
            *" -l "*)
              if [ -n "${FM_FAKE_SBX_TYPE_ECHO:-}" ]; then
                for last in "$@"; do :; done
                printf '%s\n' "$last" >> "$FM_FAKE_SBX_CAPTURE"
              fi
              ;;
            *" Enter")
              if [ -n "${FM_FAKE_SBX_ENTER_BUSY:-}" ] \
                && [ "$enter_count" -ge "${FM_FAKE_SBX_ENTER_BUSY_AFTER:-1}" ]; then
                printf 'esc to interrupt\n' >> "$FM_FAKE_SBX_CAPTURE"
              fi
              ;;
          esac
        fi
        case "$guest" in
          *" Enter")
            if [ -n "${FM_FAKE_SBX_EXPECT_PENDING_DIR:-}" ]; then
              pending=
              last_pending=$(cat "$fake_state.pending-last" 2>/dev/null || true)
              for candidate in "$FM_FAKE_SBX_EXPECT_PENDING_DIR"/.sbx-delivery-pending-*; do
                if [ -e "$candidate" ] \
                  && { [ -z "${FM_FAKE_SBX_REQUIRE_FRESH_PENDING:-}" ] \
                    || [ "$candidate" != "$last_pending" ]; }; then
                  pending=$candidate
                  break
                fi
              done
              [ -n "$pending" ] || exit 1
              printf '%s\n' "$pending" > "$fake_state.pending-last"
            fi
            if [ -n "${FM_FAKE_SBX_ACK_ON_ENTER:-}" ] \
              && { [ -z "${FM_FAKE_SBX_ACK_ON_ENTER_ONCE:-}" ] \
                || [ "$enter_count" -eq 1 ]; }; then
              touch "$FM_FAKE_SBX_ACK_ON_ENTER"
            fi
            ;;
        esac
        exit 0
        ;;
      "test -r "*)
        # fm_backend_sbx_create_task's source-mount probe.
        exit "${FM_FAKE_SBX_SOURCE_RC:-0}"
        ;;
      "sh -c "*"fm-keepalive"*)
        # The keep-alive's guest activity loop (fm_backend_sbx_keepalive):
        # canned output drives the host-side wrapper's verdict handling; the
        # loop logic itself is unit-tested by running
        # fm_backend_sbx_keepalive_script directly (tests/fm-backend-sbx.test.sh).
        if [ -n "${FM_FAKE_SBX_KEEPALIVE_OUT+x}" ]; then
          printf '%s\n' "$FM_FAKE_SBX_KEEPALIVE_OUT"
        fi
        exit "${FM_FAKE_SBX_KEEPALIVE_RC:-0}"
        ;;
      "sh -c "*"ln -sfn "*)
        # The guest-home provisioning pass (fm_backend_sbx_provision_guest_home).
        # Clone mode places the guest home at the SAME absolute path as the
        # host home, so executing the script for real against the world's home
        # dir models the guest write exactly - suites assert the resulting
        # symlink/marker shapes instead of grepping script text. When
        # FM_FAKE_SBX_GUEST_HOME is set, the home argument is remapped so the
        # write lands on the guest-clone fixture, not the host clone.
        [ "${FM_FAKE_SBX_PROVISION_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_PROVISION_RC}"
        script=$3
        shift 3
        if [ -n "${FM_FAKE_SBX_GUEST_HOME:-}" ]; then
          set -- "$1" "$FM_FAKE_SBX_GUEST_HOME" "${@:3}"
        fi
        # The pass also writes the guest USER's shell profiles, which live in
        # $HOME, not in the home clone. Force $HOME onto a fixture and scrub
        # the host's own CLAUDE_CODE_OAUTH_TOKEN: a suite must never write the
        # developer's real profiles, nor persist a real credential anywhere.
        guest_user_home=${FM_FAKE_SBX_GUEST_USER_HOME:-${FM_FAKE_SBX_LOG:-/dev/null}.guest-user-home}
        mkdir -p "$guest_user_home" 2>/dev/null || true
        if [ -n "${FM_FAKE_SBX_GUEST_ENV_TOKEN:-}" ]; then
          env HOME="$guest_user_home" \
            CLAUDE_CODE_OAUTH_TOKEN="$FM_FAKE_SBX_GUEST_ENV_TOKEN" sh -c "$script" "$@"
        else
          env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$guest_user_home" sh -c "$script" "$@"
        fi
        exit $?
        ;;
      "sh -c "*"merge --ff-only"*)
        # The guest tracked-file sync (fm_backend_sbx_tracked_sync): execute
        # the guarded in-guest fast-forward for real, remapping the home
        # argument onto the guest-clone fixture. The bundle argument stays
        # unmapped - the signal-bridge mount IS the same directory on both
        # sides.
        [ "${FM_FAKE_SBX_SYNC_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_SYNC_RC}"
        script=$3
        shift 3
        if [ -n "${FM_FAKE_SBX_GUEST_HOME:-}" ]; then
          set -- "$1" "$FM_FAKE_SBX_GUEST_HOME" "${@:3}"
        fi
        sh -c "$script" "$@"
        exit $?
        ;;
      "sh -c "*"no-mistakes doctor"*)
        # The guest gate-vendor probe (fm_backend_sbx_gate_vendor_check).
        # Executed for real against a hermetic PATH, so suites assert what the
        # probe PARSED out of a byte-accurate doctor report rather than
        # grepping script text - the parse is the behaviour under test. The
        # PATH is a replacement, not a prepend, for the same reason as the
        # daemon route below: the guest script must never be one inherited
        # entry away from the developer's real `no-mistakes`.
        [ "${FM_FAKE_SBX_DOCTOR_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_DOCTOR_RC}"
        script=$3
        shift 3
        guest_user_home=${FM_FAKE_SBX_GUEST_USER_HOME:-${FM_FAKE_SBX_LOG:-/dev/null}.guest-user-home}
        mkdir -p "$guest_user_home" 2>/dev/null || true
        env HOME="$guest_user_home" \
          PATH="${FM_FAKE_SBX_NM_BIN:-/nonexistent}:/usr/bin:/bin" sh -c "$script" "$@"
        exit $?
        ;;
      "sh -c "*"no-mistakes daemon status"*)
        # The guest no-mistakes daemon restore
        # (fm_backend_sbx_restore_nomistakes_daemon), driven by resurrection.
        # Executed for real against a fixture $HOME and a fixture PATH, so
        # suites assert what the probe DECIDED (was `daemon start` invoked, or
        # was a live daemon left alone) rather than grepping script text.
        [ "${FM_FAKE_SBX_NM_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_NM_RC}"
        script=$3
        shift 3
        guest_user_home=${FM_FAKE_SBX_GUEST_USER_HOME:-${FM_FAKE_SBX_LOG:-/dev/null}.guest-user-home}
        mkdir -p "$guest_user_home" 2>/dev/null || true
        # HERMETIC PATH, not a prepend: the guest script would otherwise be one
        # inherited PATH entry away from invoking the developer's REAL
        # `no-mistakes daemon start` against their own daemon. The script needs
        # only shell builtins plus `command -v`, so the system dirs suffice.
        env HOME="$guest_user_home" \
          PATH="${FM_FAKE_SBX_NM_BIN:-/nonexistent}:/usr/bin:/bin" sh -c "$script" "$@"
        exit $?
        ;;
      "sh -c "*".no-mistakes/worktrees"*)
        # The claude workspace-trust reconcile (fork issues #17, #40), driven by
        # both fm-spawn and resurrection. Executed for real against a fixture
        # $HOME, like the guest-home provisioning pass above, so suites assert
        # the resulting ~/.claude.json rather than grepping script text - the
        # revoke-plus-grant merge is the behaviour under test.
        [ "${FM_FAKE_SBX_TRUST_SEED_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_TRUST_SEED_RC}"
        script=$3
        shift 3
        guest_user_home=${FM_FAKE_SBX_GUEST_USER_HOME:-${FM_FAKE_SBX_LOG:-/dev/null}.guest-user-home}
        mkdir -p "$guest_user_home" 2>/dev/null || true
        env HOME="$guest_user_home" sh -c "$script" "$@"
        exit $?
        ;;
      "sh -c mkdir -p"*"cat >> "*)
        # fm-spawn's codex project-trust seed appends to the guest's
        # ~/.codex/config.toml; capture it under a fixed key so tests can
        # assert the seeded content.
        if [ "$interactive" = 1 ] && [ -n "${FM_FAKE_SBX_WRITE_DIR:-}" ]; then
          cat >> "$FM_FAKE_SBX_WRITE_DIR/codex-config.toml"
        else
          cat > /dev/null 2>/dev/null || true
        fi
        exit 0
        ;;
      "sh -c mkdir -p"*"cat > "*)
        # fm_backend_sbx_guest_write: last argv word is the guest path.
        if [ "$interactive" = 1 ] && [ -n "${FM_FAKE_SBX_WRITE_DIR:-}" ]; then
          for last in "$@"; do :; done
          cat > "$FM_FAKE_SBX_WRITE_DIR/$(printf '%s' "$last" | tr '/' '_')"
        else
          cat > /dev/null 2>/dev/null || true
        fi
        exit 0
        ;;
      "git -C "*)
        if [ -n "${FM_FAKE_SBX_GUEST_HOME:-}" ]; then
          # Tracked-sync suites: run REAL git against the guest-clone fixture
          # (fm-spawn's post-create HEAD read and any direct in-guest git).
          shift
          args=()
          prev=
          for a in "$@"; do
            if [ "$prev" = "-C" ]; then args+=("$FM_FAKE_SBX_GUEST_HOME"); else args+=("$a"); fi
            prev=$a
          done
          git "${args[@]}"
          exit $?
        fi
        # fm_backend_sbx_unlanded_work's in-guest landed-work probe. Output is
        # env-driven so a suite can pose a clean / dirty / unpushed / git-error
        # guest; FM_FAKE_SBX_GIT_RC fails BOTH git calls (unverifiable guest).
        [ "${FM_FAKE_SBX_GIT_RC:-0}" = 0 ] || exit "${FM_FAKE_SBX_GIT_RC}"
        case "$guest" in
          *"status --porcelain"*)
            [ -n "${FM_FAKE_SBX_GIT_STATUS:-}" ] && printf '%s\n' "$FM_FAKE_SBX_GIT_STATUS"
            ;;
          *" log "*)
            [ -n "${FM_FAKE_SBX_GIT_LOG:-}" ] && printf '%s\n' "$FM_FAKE_SBX_GIT_LOG"
            ;;
        esac
        exit 0
        ;;
      *)
        [ "$interactive" = 1 ] && { cat > /dev/null 2>/dev/null || true; }
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/sbx"
  printf '%s\n' "$fakebin"
}

# The non-secret placeholder shape sbx plants (`sk-ant-oat01-{rand}`): the real
# token is swapped in host-side at the proxy and never enters a VM, so no real
# credential is ever involved here. Consumed by the sourcing suites, not by
# this library, exactly like SBX_LS_EMPTY below.
# shellcheck disable=SC2034
SBX_FAKE_PLACEHOLDER=sk-ant-oat01-fixtureplaceholder

# make_fake_no_mistakes <dir>: install a fake `no-mistakes` into <dir>/nmbin
# (echoed) for the guest daemon-restore exec. Its `daemon status` output is
# byte-accurate to the real CLI measured 2026-07-31 (v1.40.2) - including that
# status EXITS 0 whether the daemon is up or DOWN, so a fake that leaned on the
# exit code would let a broken classifier pass. Behavior is driven by env at
# call time:
#   FM_FAKE_NM_STATE_FILE   file holding one of running|down|stale-socket|
#                           garbage; the fake reads it fresh per call, so a
#                           successful `daemon start` can flip it to running
#   FM_FAKE_NM_LOG          every invocation appended as one "$*" line
#   FM_FAKE_NM_RUN_FILE     an in-flight pipeline run. ANY daemon lifecycle
#                           command other than `status` deletes it, modelling
#                           the real consequence of restarting a daemon that
#                           serves live lanes. A suite asserts the file, not
#                           just the log, so a regression fails on the damage
#                           rather than on a string.
#   FM_FAKE_NM_START_FAILS  non-empty makes `daemon start` fail
#   FM_FAKE_NM_START_INERT  non-empty leaves the state unchanged after a
#                           successful-looking start (a start that did not
#                           produce a serving daemon)
#   FM_FAKE_NM_GATE         what `doctor` reports on its `gate validation`
#                           line: a vendor name (default codex) renders
#                           "<name> is runnable"; `unrunnable` renders the real
#                           no-runnable-agent wording; `none` omits the line
#                           entirely. `doctor` ALWAYS EXITS 0, byte-accurate to
#                           v1.40.2 - including when gate validation fails -
#                           so a check that trusted the exit status would pass
#                           against a guest whose gate cannot validate at all.
make_fake_no_mistakes() {  # <dir>
  local nmbin="$1/nmbin"
  mkdir -p "$nmbin"
  cat > "$nmbin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_NM_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_NM_LOG"
case "${1:-} ${2:-}" in
  "doctor"*)
    # Report shape verified against the real CLI 2026-08-02 (v1.40.2): a
    # System block, an Agents block, then the gate-validation verdict last.
    printf '  System\n'
    printf '  \342\234\223 git             git version 2.55.0\n'
    printf '  \342\234\223 data directory  %s/.no-mistakes\n' "$HOME"
    printf '\n  Agents\n'
    printf '  \342\234\223 claude          /usr/local/bin/claude\n'
    printf '  \342\200\223 cursor          not found (cursor-agent, acpx)\n'
    case "${FM_FAKE_NM_GATE:-codex}" in
      none) ;;
      unrunnable)
        printf '  \342\234\227 gate validation  no runnable agent found for configured agent auto (looked for: claude, codex)\n'
        ;;
      *)
        printf '  \342\234\223 gate validation  %s is runnable\n' "$FM_FAKE_NM_GATE"
        ;;
    esac
    exit 0
    ;;
esac
state=$(cat "${FM_FAKE_NM_STATE_FILE:?FM_FAKE_NM_STATE_FILE unset}" 2>/dev/null || echo down)
case "${1:-} ${2:-}" in
  "daemon status")
    case "$state" in
      running)      printf '  \342\227\217 daemon running (pid 4242)\n'; exit 0 ;;
      down)         printf '  \342\227\213 daemon not running\n'; exit 0 ;;
      stale-socket) printf 'connect to daemon socket: dial ipc: dial unix %s/.no-mistakes/socket: connect: connection refused\n' "$HOME"; exit 1 ;;
      *)            printf 'some future status wording nobody has seen\n'; exit 0 ;;
    esac
    ;;
  "daemon start"|"daemon stop"|"daemon restart")
    # The damage a wrongly-issued lifecycle command does, made observable.
    [ -n "${FM_FAKE_NM_RUN_FILE:-}" ] && rm -f "$FM_FAKE_NM_RUN_FILE"
    [ -z "${FM_FAKE_NM_START_FAILS:-}" ] || { printf 'daemon start failed\n' >&2; exit 1; }
    [ -n "${FM_FAKE_NM_START_INERT:-}" ] || printf 'running\n' > "$FM_FAKE_NM_STATE_FILE"
    printf 'daemon process started\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$nmbin/no-mistakes"
  printf '%s\n' "$nmbin"
}

fm_sbx_guest_env_source_line() {
  printf '%s\n' "if [ -r \"\$HOME/.fm-sbx-env.sh\" ]; then . \"\$HOME/.fm-sbx-env.sh\"; fi  # firstmate sbx guest env"
}

fm_file_mode() {  # <path>
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# seed_debian_guest_user_home <dir>: a guest user $HOME shaped like the stock
# Debian image the sbx templates build on. ~/.bashrc's FIRST statement is the
# non-interactive early return - that guard is the filter carrying the defect,
# because anything appended below it never runs for the agent-spawned children
# this fix exists for. A fixture without it would pass either way.
seed_debian_guest_user_home() {  # <dir>
  local h=$1
  mkdir -p "$h"
  cat > "$h/.bashrc" <<'RC'
# ~/.bashrc: executed by bash(1) for non-login shells.
case $- in
    *i*) ;;
      *) return;;
esac
export FM_TEST_OPERATOR_RC_MARKER=interactive-only
RC
  cat > "$h/.profile" <<'PR'
# ~/.profile: executed by the command interpreter for login shells.
export FM_TEST_OPERATOR_PROFILE_MARKER=login
PR
}

# agent_child_var <guest-user-home> <bashrc|login|posix> [var]: what <var>
# (default CLAUDE_CODE_OAUTH_TOKEN) a process the AGENT spawned would see -
# `UNSET` when it has no value. Every mode starts from `env -u`, because the
# observed defect is precisely that the agent hands its children an env with
# the placeholder missing.
#   bashrc - a NON-INTERACTIVE bash initializing from ~/.bashrc: the exact
#            failing shape (an agent Bash-tool child, and the shell an in-guest
#            daemon gets restarted from).
#   login  - a login shell reading ~/.profile: the shape the manual per-VM
#            mitigation proved on the live guest.
#   posix  - POSIX sh sourcing ~/.profile: proves the written snippet parses
#            outside bash.
agent_child_var() {  # <guest-user-home> <mode> [var]
  local h=$1 mode=$2 var=${3:-CLAUDE_CODE_OAUTH_TOKEN} prog
  # shellcheck disable=SC2016  # deliberate: the probe must expand in the CHILD shell, after its profile ran
  prog='printf "%s" "${'$var'-UNSET}"'
  case "$mode" in
    bashrc) env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$h" bash -c ". \"\$HOME/.bashrc\"; $prog" ;;
    login)  env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$h" bash -lc "$prog" ;;
    posix)  env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$h" sh -c ". \"\$HOME/.profile\"; $prog" ;;
    *) fail "agent_child_var: unknown mode '$mode'" ;;
  esac
}

# sbx_ls_json <name> <status>: one-sandbox inventory JSON in the REAL
# `sbx ls --json` shape (verified 2026-07-19; docs/sbx-backend.md).
sbx_ls_json() {  # <name> <status>
  printf '{"sandboxes":[{"name":"%s","id":"fake-id","agent":"shell","status":"%s","workspaces":["/w"]}]}\n' "$1" "$2"
}

# Consumed by the sourcing suites, not by this library, so it reads as
# "unused" here - the same pattern as lib.sh's ROOT.
# shellcheck disable=SC2034
SBX_LS_EMPTY='{"sandboxes":[]}'
