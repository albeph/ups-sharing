#!/bin/bash
# =====================================================================
# UNIT TESTS: POSIX Atomic Directory Lock (tests/test_lock.sh)
# =====================================================================

. "$PROJECT_ROOT/image/scripts/lib/lock.sh"

LOCK_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$LOCK_TMP_DIR"' EXIT

# 1. Acquire and release a fresh lock cleanly
LOCK_1="$LOCK_TMP_DIR/basic.lock"
lock_acquire "$LOCK_1" 5
assert_eq "0" "$?" "lock_acquire succeeds on available lock directory"
assert_file_exists "$LOCK_1/pid" "lock_acquire writes holder PID file"
assert_eq "$$" "$(cat "$LOCK_1/pid")" "lock_acquire records current process PID"

lock_release "$LOCK_1"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ ! -d "$LOCK_1" ]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} lock_release removes lock directory"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} lock_release failed to remove lock directory"
fi

# 2. Automatic reclamation of stale lock from a dead PID
LOCK_2="$LOCK_TMP_DIR/stale.lock"
mkdir -p "$LOCK_2"
printf "999999\n" > "$LOCK_2/pid"

lock_acquire "$LOCK_2" 5
assert_eq "0" "$?" "lock_acquire reclaims stale lock held by non-existent PID"
assert_eq "$$" "$(cat "$LOCK_2/pid")" "lock_acquire updates PID file after reclaiming stale lock"
lock_release "$LOCK_2"
