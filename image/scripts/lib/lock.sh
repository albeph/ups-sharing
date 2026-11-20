#!/bin/sh
# =====================================================================
# POSIX ATOMIC DIRECTORY LOCK LIBRARY (image/scripts/lib/lock.sh)
# =====================================================================
# Responsibility:
#   Provide a lightweight, cross-process mutual exclusion primitive
#   compatible with Alpine Linux POSIX /bin/sh (ash), including
#   automatic recovery from stale locks left behind by terminated PIDs.
#
# Public API:
#   lock_acquire <lock_dir> [timeout_sec]
#   lock_release <lock_dir>
# =====================================================================

# ---------------------------------------------------------------------
# lock_acquire: Acquire an atomic directory lock with stale-PID cleanup.
# Arguments:
#   $1 - Path to the lock directory
#   $2 - Maximum wait time in seconds before forcing takeover (default: 30)
# Returns:
#   0 on success, 1 on failure
# ---------------------------------------------------------------------
lock_acquire() {
    _lock_dir="$1"
    _lock_timeout="${2:-30}"
    _lock_waited=0

    # Ensure parent directory exists before attempting atomic mkdir
    _lock_parent=$(dirname "$_lock_dir")
    mkdir -p "$_lock_parent" 2>/dev/null || true

    while ! mkdir "$_lock_dir" 2>/dev/null; do
        if [ -f "$_lock_dir/pid" ]; then
            _lock_holder_pid=$(cat "$_lock_dir/pid" 2>/dev/null || true)
            if [ -n "$_lock_holder_pid" ] && ! kill -0 "$_lock_holder_pid" 2>/dev/null; then
                # Lock holder process is no longer alive; reclaim stale lock
                rm -rf "$_lock_dir" 2>/dev/null || true
                continue
            fi
        fi

        if [ "$_lock_waited" -ge "$_lock_timeout" ]; then
            # Timeout reached: force-reclaim lock to prevent permanent deadlock
            rm -rf "$_lock_dir" 2>/dev/null || true
            mkdir "$_lock_dir" 2>/dev/null || return 1
            break
        fi

        sleep 1
        _lock_waited=$((_lock_waited + 1))
    done

    printf "%s\n" "$$" > "$_lock_dir/pid" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------
# lock_release: Release a previously acquired directory lock.
# Arguments:
#   $1 - Path to the lock directory
# Returns:
#   0 always
# ---------------------------------------------------------------------
lock_release() {
    _lock_dir="$1"
    [ -n "$_lock_dir" ] || return 0
    rm -rf "$_lock_dir" 2>/dev/null || true
    return 0
}
