#!/usr/bin/env bash
# Confine a test's treehouse worktree pools to that test's own temp directory.
#
# treehouse keeps a repo's worktree pool in {root}/.treehouse/<repo>-<hash>/ and
# leaves that directory behind when the repo itself is deleted. A test that
# points treehouse at a throwaway repo under TMPDIR therefore orphaned one pool
# directory per fixture per run: 92 had accumulated under ~/.treehouse by
# 2026-09-14.
#
# A fixture repo's own treehouse.toml `root` key (absolute path, pool placed at
# {root}/.treehouse) redirects the pool into the test's temp tree, so nothing
# reaches ~/.treehouse in the first place. The sweep below is the backstop for a
# treehouse build that does not honor that key, and is what the EXIT trap calls.
set -u

TREEHOUSE_POOL_HOME_ROOT="${HOME}/.treehouse"
TREEHOUSE_POOL_BASELINE=
TREEHOUSE_POOL_FIXTURES=

# Snapshot ~/.treehouse before any treehouse call. Nothing recorded here can
# ever be swept, so a pool that predates the test is never at risk.
treehouse_pool_baseline() {
  TREEHOUSE_POOL_BASELINE=$(ls -1 "$TREEHOUSE_POOL_HOME_ROOT" 2>/dev/null)
}

treehouse_pool_confine() { # <fixture-repo> <pool-parent>
  local repo=$1 parent=$2
  mkdir -p "$parent" || return 1
  printf 'root = "%s"\n' "$parent" > "$repo/treehouse.toml" || return 1
  TREEHOUSE_POOL_FIXTURES="${TREEHOUSE_POOL_FIXTURES}$(basename "$repo")
"
}

# The hash test rejects a dash, so fixture "scratch-project" never claims
# "scratch-project-1"'s pool.
treehouse_pool_leaked() {
  local entry fixture suffix
  [ -d "$TREEHOUSE_POOL_HOME_ROOT" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "
$TREEHOUSE_POOL_BASELINE
" in
      *"
$entry
"*) continue ;;
    esac
    while IFS= read -r fixture; do
      [ -n "$fixture" ] || continue
      case "$entry" in
        "$fixture"-*) suffix=${entry#"$fixture"-} ;;
        *) continue ;;
      esac
      case "$suffix" in
        ''|*[!0-9a-f]*) continue ;;
      esac
      printf '%s\n' "$TREEHOUSE_POOL_HOME_ROOT/$entry"
      break
    done <<EOF
$TREEHOUSE_POOL_FIXTURES
EOF
  done <<EOF
$(ls -1 "$TREEHOUSE_POOL_HOME_ROOT" 2>/dev/null)
EOF
}

# Remove exactly what treehouse_pool_leaked names. Safe to call unconditionally
# from an EXIT trap, including on failure: it can only name a pool this run
# created for one of its own fixtures.
treehouse_pool_sweep() {
  local pool
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    rm -rf "$pool"
  done <<EOF
$(treehouse_pool_leaked)
EOF
}
