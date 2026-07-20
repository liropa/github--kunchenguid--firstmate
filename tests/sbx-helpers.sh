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
#   FM_FAKE_SBX_TYPE_ECHO    when set (with FM_FAKE_SBX_CAPTURE), a literal
#                            `tmux send-keys ... -l <text>` appends <text> to
#                            the capture file - models a terminal that renders
#                            what was typed; unset = the type is eaten (the
#                            resume-time swallow)
#   FM_FAKE_SBX_ENTER_BUSY   appends the default busy footer on Enter
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
    guest="$*"
    case "$guest" in
      "tmux has-session"*)
        exit "${FM_FAKE_SBX_TMUX_HAS_RC:-0}"
        ;;
      "tmux capture-pane"*)
        [ -n "${FM_FAKE_SBX_CAPTURE:-}" ] && cat "$FM_FAKE_SBX_CAPTURE"
        exit 0
        ;;
      "tmux display-message"*)
        printf '%s\n' "${FM_FAKE_SBX_FG:-codex}"
        exit 0
        ;;
      "tmux send-keys"*)
        if [ -n "${FM_FAKE_SBX_TYPE_ECHO:-}" ] && [ -n "${FM_FAKE_SBX_CAPTURE:-}" ]; then
          case "$guest" in
            *" -l "*)
              for last in "$@"; do :; done
              printf '%s\n' "$last" >> "$FM_FAKE_SBX_CAPTURE"
              ;;
            *" Enter")
              [ -n "${FM_FAKE_SBX_ENTER_BUSY:-}" ] && printf 'esc to interrupt\n' >> "$FM_FAKE_SBX_CAPTURE"
              ;;
          esac
        fi
        exit 0
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

# sbx_ls_json <name> <status>: one-sandbox inventory JSON in the REAL
# `sbx ls --json` shape (verified 2026-07-19; docs/sbx-backend.md).
sbx_ls_json() {  # <name> <status>
  printf '{"sandboxes":[{"name":"%s","id":"fake-id","agent":"shell","status":"%s","workspaces":["/w"]}]}\n' "$1" "$2"
}

# Consumed by the sourcing suites, not by this library, so it reads as
# "unused" here - the same pattern as lib.sh's ROOT.
# shellcheck disable=SC2034
SBX_LS_EMPTY='{"sandboxes":[]}'
