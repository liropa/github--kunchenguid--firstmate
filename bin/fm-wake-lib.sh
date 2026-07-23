#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.
#
# Watcher identity contract (single owner of the format and its verification):
# a watcher lock's pid-identity file carries one of three formats.
#   linux-starttime=... cmdline-hex=...   /proc-derived; verified by recomputing.
#   flock-identity pid=... nonce=...      self-declared at publication when
#                                         process inspection was unavailable;
#                                         verified by probing the publisher's
#                                         still-held identity flock, never by ps.
#   <ps lstart + command text>            portable ps fallback; verified by
#                                         recomputing when ps runs, else by the
#                                         identity flock when one was published.
# Publication also holds an flock (LOCK_EX) on <lockdir>/identity-flock for the
# watcher's whole life. The kernel releases that lock when the holder's last
# inherited descriptor closes, so a recycled pid can never re-hold it: the probe
# stays pid-reuse-safe in environments where ps cannot run at all (a sandboxed
# session cannot exec setuid /bin/ps on macOS). A lock that predates the flock
# file and cannot be inspected is reported as unverifiable (rc 2), a distinct
# honest outcome that callers must treat as unknown, never as stale or absent.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1 err
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" -gt 0 ] || return 1
  err=$(kill -0 "$pid" 2>&1) && return 0
  # EPERM still proves existence: a sandboxed session cannot signal processes
  # outside its sandbox, so only ESRCH may be read as death. Anything else must
  # stay "alive" or a sandboxed caller would treat a live holder as stealable.
  case "$err" in
    *[Nn]o\ such\ process*) return 1 ;;
  esac
  return 0
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer /proc on Linux: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  if [ "$(uname)" = Linux ] && [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    printf 'linux-starttime=%s cmdline-hex=%s\n' "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

# True when this environment can compute fm_pid_identity at all, probed against
# the caller's own live pid. False means inspection tooling is unavailable here
# (no readable /proc and ps cannot exec), NOT that any particular pid is dead.
fm_pid_identity_available() {
  fm_pid_identity "${BASHPID:-$$}" >/dev/null 2>&1
}

# Hold the watcher-identity flock for the caller's remaining lifetime. The lock
# rides the open file description behind fd 217, deliberately outside the 0-9
# range reused by other firstmate helpers (fm-check-lib.sh trust reads, Herdr
# event wait), so the kernel releases it when the holder's last inherited
# descriptor closes; a recycled pid never inherits it. The flock file is created
# only when the lock is genuinely held, so its presence is a promise that a
# probe finding it unlocked has found a dead publisher, not a degraded one.
fm_watcher_identity_flock_hold() {  # <lockdir>
  local lockdir=$1
  exec 217>>"$lockdir/identity-flock" 2>/dev/null || return 1
  if ! perl -e '
    use Fcntl qw(:flock);
    open(my $fh, ">>&=", 217) or exit 1;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
  ' 2>/dev/null; then
    exec 217>&- 2>/dev/null
    rm -f "$lockdir/identity-flock" 2>/dev/null || true
    return 1
  fi
  return 0
}

# True when some live process still holds the published identity flock. The
# probe takes LOCK_SH so concurrent probes never report each other as the
# holder; only the publisher's LOCK_EX blocks it.
fm_watcher_identity_flock_held() {  # <lockdir>
  local lockdir=$1
  [ -f "$lockdir/identity-flock" ] || return 1
  perl -e '
    use Fcntl qw(:flock);
    open(my $fh, "<", $ARGV[0]) or exit 1;
    exit(flock($fh, LOCK_SH | LOCK_NB) ? 1 : 0);
  ' "$lockdir/identity-flock" 2>/dev/null
}

# Publish the watcher's identity into its held lockdir: hold the identity flock
# for life, then record the inspectable identity string when one is computable,
# or a self-declared flock-identity marker when it is not. Returns non-zero only
# when neither a computable identity nor a held flock could be published, which
# leaves the lock unverifiable for arm confirmation.
fm_watcher_identity_publish() {  # <lockdir> <pid>
  local lockdir=$1 pid=$2 identity nonce flock_held=0
  fm_watcher_identity_flock_hold "$lockdir" && flock_held=1
  if identity=$(fm_pid_identity "$pid" 2>/dev/null); then
    printf '%s\n' "$identity" > "$lockdir/pid-identity"
    return 0
  fi
  [ "$flock_held" -eq 1 ] || return 1
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')
  [ -n "$nonce" ] || nonce="$pid.$(date +%s)"
  printf 'flock-identity pid=%s nonce=%s\n' "$pid" "$nonce" > "$lockdir/pid-identity"
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Verify that the recorded watcher lock provably names the live process <pid>.
# Returns 0 on a proven match, 1 on a definitive mismatch (wrong home or path,
# empty identity, a dead holder, or a recycled pid), and 2 when identity truly
# cannot be established either way: process inspection is unavailable AND the
# lock predates the identity flock. Callers that act destructively on
# "mismatch" must treat 2 as unknown, never as stale, absent, or contended.
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity declared_pid
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  case "$lock_identity" in
    flock-identity\ pid=*)
      # Self-declared identity: the string is a marker, the held flock is the
      # proof. The declared pid must still be the pid under test.
      declared_pid=${lock_identity#flock-identity pid=}
      declared_pid=${declared_pid%% *}
      [ "$declared_pid" = "$pid" ] || return 1
      fm_watcher_identity_flock_held "$lockdir"
      return
      ;;
  esac
  if current_identity=$(fm_pid_identity "$pid"); then
    [ "$current_identity" = "$lock_identity" ]
    return
  fi
  if fm_pid_identity_available; then
    # Inspection works here, so the failure is about <pid> itself: it is gone.
    return 1
  fi
  # An inspectable-format identity, but this session cannot inspect processes
  # (a sandboxed session cannot exec setuid ps). Fall back to the identity
  # flock when the publisher held one; otherwise the identity is unknowable.
  if [ -f "$lockdir/identity-flock" ]; then
    fm_watcher_identity_flock_held "$lockdir"
    return
  fi
  return 2
}

FM_WATCHER_HEALTHY_PID=
FM_WATCHER_HEALTH_UNVERIFIED=0
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age rc
  FM_WATCHER_HEALTHY_PID=
  FM_WATCHER_HEALTH_UNVERIFIED=0
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
    [ "$rc" -eq 2 ] && FM_WATCHER_HEALTH_UNVERIFIED=1
    return 1
  fi
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/identity-flock" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

# Returns 0 acquired, 1 lost to a real contender (the lock exists or appeared
# mid-create), 2 lock artifacts cannot be created at all (missing or unwritable
# parent directory). 2 means there is no holder to wait for or steal: retrying
# or stealing would fail identically, so callers must fail cleanly instead.
fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    return 1
  fi
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 2
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 2
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale age
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      case "$mid_acquire_stale" in
        ''|*[!0-9]*) mid_acquire_stale=2 ;;
      esac
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      # A non-numeric age means the probed path vanished or cannot be
      # inspected; treat it as not-fresh instead of feeding [ garbage.
      age=$(fm_path_age "$lockdir" 2>/dev/null || true)
      case "${age#-}" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ "$age" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

# fm_lock_try_acquire <lockdir> [<steal_depth>]
# Returns 0 acquired, 1 held by a contender (FM_LOCK_HELD_PID set when
# readable), 2 lock artifacts cannot be created at all (missing or unwritable
# parent) - a clean "locking unavailable here" failure, never a hang or steal.
# steal_depth is internal recursion bookkeeping; callers omit it. A steal of
# <lockdir> serializes through the <lockdir>.steal companion, and a stale
# companion (its holder died mid-steal) may itself be stolen through
# <lockdir>.steal.steal - one companion level, same serialization as the
# primary. Depth 2 never steals, so the suffix is structurally bounded at
# .steal.steal no matter why any acquisition fails.
fm_lock_try_acquire() {
  local lockdir=$1 steal_depth=${2:-0} pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  fm_lock_try_create "$lockdir"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    # No lock artifacts can exist here, so there is no holder to report or
    # steal; a steal attempt would fail the same way one suffix deeper,
    # forever (the 2026-07-22 .steal.steal... runaway). Fail cleanly.
    return 2
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  if [ "$steal_depth" -ge 2 ]; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal" $((steal_depth + 1)); then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

# Waits out real contention only. Returns 0 once acquired, or 2 immediately
# when lock artifacts cannot be created at all (fm_lock_try_acquire rc 2):
# waiting cannot help when there is no holder to outlast, and looping there
# is how the unwritable-parent runaway kept respawning. Callers must handle
# the failure and skip the guarded work.
fm_lock_acquire_wait() {
  local lockdir=$1 rc
  while :; do
    fm_lock_try_acquire "$lockdir"
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
FM_WAKE_STATUS_KEY=
FM_WAKE_STATUS_HISTORICAL=false
fm_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  FM_WAKE_STATUS_KEY=
  FM_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      FM_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  FM_WAKE_STATUS_KEY="$id.status"
}

fm_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$FM_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$FM_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

FM_WAKE_EVENT_LINE=
FM_WAKE_EVENT_TRUNCATED=false
fm_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  local path=$1 tail_bytes=$2 result size chunk record line_number
  FM_WAKE_EVENT_LINE=
  FM_WAKE_EVENT_TRUNCATED=false
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $limit) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/;
    my $start = $size > $limit ? $size - $limit : 0;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $size or exit 1;
    my $remaining = $size - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$tail_bytes" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  record=$(printf '%s' "$chunk" | LC_ALL=C awk '
    /[^[:space:]]/ { line = $0; line_number = NR }
    END { if (line_number) printf "%d\t%s", line_number, line }
  ') || return 1
  [ -n "$record" ] || return 1
  line_number=${record%%	*}
  FM_WAKE_EVENT_LINE=${record#*	}
  FM_WAKE_EVENT_LINE=$(printf '%s' "$FM_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
  if [ "$size" -gt "$tail_bytes" ] && [ "$line_number" -eq 1 ]; then
    FM_WAKE_EVENT_TRUNCATED=true
  fi
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock. The limits are constants,
# so status-file volume cannot turn a drain into an unbounded context read.
fm_wake_print_annotations() {  # <deduped-raw-rows>
  local rows=$1 manifest status_key mode path prefix line suffix keep bytes
  local output='' used=0 omitted=0 read_omitted=0 annotation_marker marker_reserve=192
  local tail_bytes=8192 item_bytes=2048 global_bytes=8192 read_cap=8 reads=0
  local LC_ALL=C

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    if [ "$reads" -ge "$read_cap" ]; then
      read_omitted=$((read_omitted + 1))
      continue
    fi
    reads=$((reads + 1))
    path="$STATE/$status_key"
    fm_wake_latest_event "$path" "$tail_bytes" || continue
    prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
    if [ "$mode" = historical ]; then
      prefix="$prefix; historical / not necessarily the triggering event"
    fi
    line="$prefix: $status_key: $FM_WAKE_EVENT_LINE"
    suffix=''
    [ "$FM_WAKE_EVENT_TRUNCATED" = false ] || suffix=' [truncated]'
    line="$line$suffix"
    if [ $(( ${#line} + 1 )) -gt "$item_bytes" ]; then
      suffix=' [truncated]'
      keep=$((item_bytes - ${#suffix} - 1))
      line="${line:0:$keep}$suffix"
    fi
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes + marker_reserve)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
  done <<EOF
$manifest
EOF

  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $omitted annotations omitted (global enrichment byte cap)"
    printf '%s\n' "$annotation_marker"
  fi
  if [ "$read_omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $read_omitted annotations omitted (enrichment read cap)"
    printf '%s\n' "$annotation_marker"
  fi
  return 0
}
