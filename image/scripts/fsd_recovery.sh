#!/bin/sh
set -u

# =====================================================================
# POST-FSD POWER RECOVERY MANAGER (image/scripts/fsd_recovery.sh)
# =====================================================================
# Responsibility:
#   Independent, self-contained stateful module that persists Forced
#   Shutdown (FSD) markers across host/UPS power-offs and coordinates
#   delayed post-boot "Power Restored after FSD" email delivery.
#
# Key Guarantees:
#   - Survives host shutdown, UPS outlet power-off, and repeated reboots
#     via atomic state persistence in NUT_STATE_DIR (/var/lib/nut-state).
#   - Never blocks ups_notifier.sh while routers, DNS, or SMTP are still
#     initializing after a cold boot (independent worker with stepped
#     exponential backoff).
#   - Verifies continuous OL stability (FSD_RECOVERY_STABLE_SEC) before
#     every send attempt so a follow-up blackout in charging deficit
#     suspends delivery instead of emitting a false recovery email.
#   - Tracks consecutive FSD cycles (FSD_COUNT) and exposes
#     'is-recovery-active' so ups_notifier.sh suppresses duplicates.
#
# Public Interface (Subcommands):
#   fsd_recovery.sh mark-fsd [charge] [blackout_start_epoch]
#   fsd_recovery.sh activate
#   fsd_recovery.sh is-recovery-active
#   fsd_recovery.sh clear
#   fsd_recovery.sh status
#   fsd_recovery.sh daemon [recipient] [ups_name]
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lock.sh"
. "$SCRIPT_DIR/ups_telemetry.sh"

NUT_STATE_DIR="${NUT_STATE_DIR:-/var/lib/nut-state}"
STATE_FILE="${NUT_STATE_DIR}/fsd_recovery.state"
LOCK_DIR="${NUT_STATE_DIR}/.fsd_recovery.lock"

FSD_RECOVERY_STABLE_SEC="${FSD_RECOVERY_STABLE_SEC:-15}"
FSD_RECOVERY_POLL_INTERVAL="${FSD_RECOVERY_POLL_INTERVAL:-3}"
FSD_RECOVERY_RETRY_INITIAL="${FSD_RECOVERY_RETRY_INITIAL:-15}"
FSD_RECOVERY_RETRY_MAX="${FSD_RECOVERY_RETRY_MAX:-60}"
FSD_RECOVERY_MAX_ATTEMPTS="${FSD_RECOVERY_MAX_ATTEMPTS:-1440}"

BUILD_MESSAGE_BIN="${BUILD_MESSAGE_BIN:-$SCRIPT_DIR/build_message.sh}"
SEND_MAIL_BIN="${SEND_MAIL_BIN:-$SCRIPT_DIR/send_mail.sh}"

# Encapsulated state fields (read/written exclusively through state helpers)
RECOVERY_STATE=""
FSD_COUNT="0"
FIRST_FSD_EPOCH="0"
LAST_FSD_EPOCH="0"
FSD_TIMESTAMP=""
BLACKOUT_START="0"
FSD_CHARGE=""

# ---------------------------------------------------------------------
# _state_reset: Reset in-memory recovery state variables to defaults.
# ---------------------------------------------------------------------
_state_reset() {
    RECOVERY_STATE=""
    FSD_COUNT="0"
    FIRST_FSD_EPOCH="0"
    LAST_FSD_EPOCH="0"
    FSD_TIMESTAMP=""
    BLACKOUT_START="0"
    FSD_CHARGE=""
}

# ---------------------------------------------------------------------
# _state_load_unlocked: Safely parse key=value state file without eval.
# Returns:
#   0 if valid state loaded, 1 if absent or invalid
# ---------------------------------------------------------------------
_state_load_unlocked() {
    _state_reset
    [ -f "$STATE_FILE" ] || return 1

    while IFS='=' read -r _k _v || [ -n "$_k" ]; do
        case "$_k" in
            RECOVERY_STATE)  RECOVERY_STATE="$_v" ;;
            FSD_COUNT)       FSD_COUNT="$_v" ;;
            FIRST_FSD_EPOCH) FIRST_FSD_EPOCH="$_v" ;;
            LAST_FSD_EPOCH)  LAST_FSD_EPOCH="$_v" ;;
            FSD_TIMESTAMP)   FSD_TIMESTAMP="$_v" ;;
            BLACKOUT_START)  BLACKOUT_START="$_v" ;;
            FSD_CHARGE)      FSD_CHARGE="$_v" ;;
        esac
    done < "$STATE_FILE"

    FSD_COUNT=$(to_int "${FSD_COUNT:-0}")
    FIRST_FSD_EPOCH=$(to_int "${FIRST_FSD_EPOCH:-0}")
    LAST_FSD_EPOCH=$(to_int "${LAST_FSD_EPOCH:-0}")
    BLACKOUT_START=$(to_int "${BLACKOUT_START:-0}")
    [ -n "$RECOVERY_STATE" ] || return 1
    return 0
}

# ---------------------------------------------------------------------
# _state_save_unlocked: Atomically persist state fields via temp + mv.
# ---------------------------------------------------------------------
_state_save_unlocked() {
    mkdir -p "$NUT_STATE_DIR" 2>/dev/null || true
    _tmp_file="${STATE_FILE}.tmp.$$"
    cat <<EOF > "$_tmp_file"
RECOVERY_STATE=${RECOVERY_STATE}
FSD_COUNT=${FSD_COUNT}
FIRST_FSD_EPOCH=${FIRST_FSD_EPOCH}
LAST_FSD_EPOCH=${LAST_FSD_EPOCH}
FSD_TIMESTAMP=${FSD_TIMESTAMP}
BLACKOUT_START=${BLACKOUT_START}
FSD_CHARGE=${FSD_CHARGE}
EOF
    mv -f "$_tmp_file" "$STATE_FILE"
}

# ---------------------------------------------------------------------
# _is_status_mains_online: Check whether ups.status indicates stable
# mains power (contains OL and excludes OB, FSD, SHUTDOWN, and OFF).
# Arguments:
#   $1 - Raw ups.status string
# Returns:
#   0 if stably online, 1 otherwise
# ---------------------------------------------------------------------
_is_status_mains_online() {
    _st="${1:-}"
    case "$_st" in
        *OL*)
            case "$_st" in
                *OB*|*FSD*|*SHUTDOWN*|*OFF*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------
# _sleep_sec: Sleep wrapper honoring 0-second delays in automated tests.
# Arguments:
#   $1 - Duration in seconds
# ---------------------------------------------------------------------
_sleep_sec() {
    _sec=$(to_int "${1:-0}")
    if [ "$_sec" -gt 0 ]; then
        sleep "$_sec"
    fi
}

# ---------------------------------------------------------------------
# _compute_recovery_duration: Calculate elapsed outage duration safely,
# guarding against unsynced host clocks (e.g. RTC-less devices at boot).
# Populates: TIMESTAMP, DURATION_SEC, DURATION_MIN
# ---------------------------------------------------------------------
_compute_recovery_duration() {
    _now_epoch=$(date +%s)
    TIMESTAMP=$(date '+%d/%m/%Y %H:%M:%S')

    _outage_ref="$BLACKOUT_START"
    if [ "$_outage_ref" -le 0 ]; then
        _outage_ref="$FIRST_FSD_EPOCH"
    fi

    DURATION_SEC=0
    DURATION_MIN=0
    if [ "$_outage_ref" -gt 0 ] && [ "$_now_epoch" -gt "$_outage_ref" ]; then
        DURATION_SEC=$((_now_epoch - _outage_ref))
        DURATION_MIN=$((DURATION_SEC / 60))
    fi
}

# ---------------------------------------------------------------------
# _compute_next_retry_delay: Compute stepped exponential backoff capped
# at FSD_RECOVERY_RETRY_MAX.
# Arguments:
#   $1 - Current retry delay in seconds
#   $2 - Maximum retry delay in seconds
# Outputs:
#   Next retry delay to STDOUT
# ---------------------------------------------------------------------
_compute_next_retry_delay() {
    _cur="$1"
    _max="$2"
    if [ "$_cur" -lt "$_max" ]; then
        _next=$((_cur * 2))
        if [ "$_next" -gt "$_max" ]; then
            _next="$_max"
        fi
        printf "%s" "$_next"
    else
        printf "%s" "$_cur"
    fi
}

# ---------------------------------------------------------------------
# _send_recovery_notification: Export recovery telemetry context and
# pipe fsd_power_restored message through build_message -> send_mail.
# Arguments:
#   $1 - Target recipient email address
# Returns:
#   0 on successful delivery, non-zero on failure
# ---------------------------------------------------------------------
_send_recovery_notification() {
    _target_recipient="$1"
    _compute_recovery_duration

    export TIMESTAMP RAW_STATUS CHARGE CHARGE_INT RUNTIME RUNTIME_MIN VOLTAGE LOAD \
           REALPOWER NOMINAL_REALPOWER DURATION_MIN DURATION_SEC UPS_NAME \
           UPS_FRIENDLY_NAME ALERT_LANG UPS_NOMINAL_WATTS \
           FSD_TIMESTAMP FSD_COUNT FSD_CHARGE

    "$BUILD_MESSAGE_BIN" "fsd_power_restored" | "$SEND_MAIL_BIN" "$_target_recipient"
}

# ---------------------------------------------------------------------
# cmd_mark_fsd: Persist an FSD shutdown marker.
# Idempotent within the same shutdown sequence (FSD_RECORDED -> FSD_RECORDED);
# increments FSD_COUNT when a new FSD occurs before recovery completed
# (RECOVERY_PENDING -> FSD_RECORDED).
# Arguments:
#   $1 - Battery charge percentage at FSD (optional)
#   $2 - Original blackout start Unix epoch (optional)
# ---------------------------------------------------------------------
cmd_mark_fsd() {
    _in_charge="${1:-}"
    _in_bstart=$(to_int "${2:-0}")
    _now=$(date +%s)
    _ts=$(date '+%d/%m/%Y %H:%M:%S')

    lock_acquire "$LOCK_DIR" 30 || {
        echo "[FSD-RECOVERY] ⚠️ Failed to acquire state lock during mark-fsd." >&2
        return 1
    }

    if _state_load_unlocked; then
        if [ "$RECOVERY_STATE" = "FSD_RECORDED" ]; then
            # Idempotent update within the same shutdown sequence
            if [ -z "$FSD_CHARGE" ] && [ -n "$_in_charge" ]; then
                FSD_CHARGE="$_in_charge"
            fi
            if [ "$BLACKOUT_START" -eq 0 ] && [ "$_in_bstart" -gt 0 ]; then
                BLACKOUT_START="$_in_bstart"
            fi
            _state_save_unlocked
            lock_release "$LOCK_DIR"
            echo "[FSD-RECOVERY] FSD marker already recorded for current shutdown (cycles: ${FSD_COUNT})."
            return 0
        else
            # Previous post-FSD recovery was still pending when a consecutive FSD occurred
            RECOVERY_STATE="FSD_RECORDED"
            FSD_COUNT=$((FSD_COUNT + 1))
            LAST_FSD_EPOCH="$_now"
            FSD_TIMESTAMP="$_ts"
            [ -n "$_in_charge" ] && FSD_CHARGE="$_in_charge"
            if [ "$BLACKOUT_START" -eq 0 ] && [ "$_in_bstart" -gt 0 ]; then
                BLACKOUT_START="$_in_bstart"
            fi
            _state_save_unlocked
            lock_release "$LOCK_DIR"
            echo "[FSD-RECOVERY] Recorded consecutive FSD shutdown (cycle #${FSD_COUNT}, charge: ${FSD_CHARGE:-N/A}%)."
            return 0
        fi
    else
        RECOVERY_STATE="FSD_RECORDED"
        FSD_COUNT="1"
        FIRST_FSD_EPOCH="$_now"
        LAST_FSD_EPOCH="$_now"
        FSD_TIMESTAMP="$_ts"
        if [ "$_in_bstart" -gt 0 ]; then
            BLACKOUT_START="$_in_bstart"
        else
            BLACKOUT_START="$_now"
        fi
        FSD_CHARGE="$_in_charge"
        _state_save_unlocked
        lock_release "$LOCK_DIR"
        echo "[FSD-RECOVERY] Persisted FSD shutdown marker (timestamp: ${FSD_TIMESTAMP}, charge: ${FSD_CHARGE:-N/A}%)."
        return 0
    fi
}

# ---------------------------------------------------------------------
# cmd_activate: Transition FSD_RECORDED -> RECOVERY_PENDING on container
# startup (or resume an existing RECOVERY_PENDING state).
# Returns:
#   0 if recovery is active, 1 if idle
# ---------------------------------------------------------------------
cmd_activate() {
    lock_acquire "$LOCK_DIR" 30 || return 1
    if ! _state_load_unlocked; then
        lock_release "$LOCK_DIR"
        return 1
    fi

    RECOVERY_STATE="RECOVERY_PENDING"
    _state_save_unlocked
    lock_release "$LOCK_DIR"
    return 0
}

# ---------------------------------------------------------------------
# cmd_is_recovery_active: Return 0 iff post-FSD recovery is pending.
# ---------------------------------------------------------------------
cmd_is_recovery_active() {
    if _state_load_unlocked && [ "$RECOVERY_STATE" = "RECOVERY_PENDING" ]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# cmd_clear: Atomically remove the persisted FSD recovery marker.
# ---------------------------------------------------------------------
cmd_clear() {
    lock_acquire "$LOCK_DIR" 30 || return 1
    rm -f "$STATE_FILE" "${STATE_FILE}.tmp."* 2>/dev/null || true
    lock_release "$LOCK_DIR"
    return 0
}

# ---------------------------------------------------------------------
# cmd_status: Print current persisted recovery state for diagnostics.
# ---------------------------------------------------------------------
cmd_status() {
    if _state_load_unlocked; then
        printf "RECOVERY_STATE=%s\nFSD_COUNT=%s\nFIRST_FSD_EPOCH=%s\nLAST_FSD_EPOCH=%s\nFSD_TIMESTAMP=%s\nBLACKOUT_START=%s\nFSD_CHARGE=%s\n" \
            "$RECOVERY_STATE" "$FSD_COUNT" "$FIRST_FSD_EPOCH" "$LAST_FSD_EPOCH" \
            "$FSD_TIMESTAMP" "$BLACKOUT_START" "$FSD_CHARGE"
        return 0
    else
        printf "RECOVERY_STATE=IDLE\n"
        return 1
    fi
}

# ---------------------------------------------------------------------
# cmd_daemon: Background recovery worker invoked at container startup.
# Exits immediately with zero overhead when no FSD marker is present.
# Arguments:
#   $1 - Recipient email address (optional)
#   $2 - UPS identifier (optional)
# ---------------------------------------------------------------------
cmd_daemon() {
    _recipient=$(resolve_recipient "${1:-${NOTIFICATION_EMAIL:-}}")
    UPS_NAME="${2:-${UPS_NAME:-}}"
    ALERT_LANG="${ALERT_LANG:-en}"
    UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"
    UPS_NOMINAL_WATTS="${UPS_NOMINAL_WATTS:-}"

    # Fast path: normal boot with no pending FSD marker
    [ -f "$STATE_FILE" ] || return 0
    cmd_activate || return 0

    trap 'echo "[FSD-RECOVERY] Received termination signal; preserving pending recovery state."; exit 0' TERM INT

    echo "[FSD-RECOVERY] Detected pending post-FSD recovery state. Waiting for NUT server..."
    wait_for_nut_server "$UPS_NAME" "${FSD_RECOVERY_POLL_INTERVAL:-3}"
    echo "[FSD-RECOVERY] NUT server reachable (UPS: ${UPS_NAME}). Monitoring mains stability & SMTP readiness..."

    _stable_sec=$(to_int "$FSD_RECOVERY_STABLE_SEC")
    _poll_int=$(to_int "$FSD_RECOVERY_POLL_INTERVAL")
    _retry_delay=$(to_int "$FSD_RECOVERY_RETRY_INITIAL")
    _retry_max=$(to_int "$FSD_RECOVERY_RETRY_MAX")
    _max_attempts=$(to_int "$FSD_RECOVERY_MAX_ATTEMPTS")

    _stable_elapsed=0
    _attempts=0
    _suspended_logged=0

    while true; do
        # Exit cleanly if recovery state was cleared or superseded by a new FSD
        if ! _state_load_unlocked || [ "$RECOVERY_STATE" != "RECOVERY_PENDING" ]; then
            echo "[FSD-RECOVERY] Recovery state changed (${RECOVERY_STATE:-CLEARED}); stopping recovery worker."
            return 0
        fi

        fetch_ups_telemetry "$UPS_NAME"

        # Suspend delivery whenever UPS is not on stable mains power
        if ! _is_status_mains_online "${RAW_STATUS:-}"; then
            _stable_elapsed=0
            if [ "$_suspended_logged" -eq 0 ]; then
                echo "[FSD-RECOVERY] UPS is not on stable mains (status: '${RAW_STATUS:-N/A}', battery: ${CHARGE:-N/A}%). Suspending recovery email until power stabilizes."
                _suspended_logged=1
            fi
            _sleep_sec "$_poll_int"
            continue
        fi

        if [ "$_suspended_logged" -eq 1 ]; then
            echo "[FSD-RECOVERY] Mains power (OL) returned. Verifying stability (${_stable_sec}s) before notifying..."
            _suspended_logged=0
        fi

        # Require continuous OL stability to prevent alerts during flickering power
        if [ "$_stable_elapsed" -lt "$_stable_sec" ]; then
            _sleep_sec "$_poll_int"
            if [ "$_poll_int" -gt 0 ]; then
                _stable_elapsed=$((_stable_elapsed + _poll_int))
            else
                _stable_elapsed="$_stable_sec"
            fi
            continue
        fi

        # Refresh potentially stale input.voltage and re-verify online status
        refresh_telemetry_on_transition "$UPS_NAME"
        if ! _is_status_mains_online "${RAW_STATUS:-}"; then
            _stable_elapsed=0
            _suspended_logged=1
            echo "[FSD-RECOVERY] Mains lost during telemetry refresh (status: '${RAW_STATUS:-N/A}'). Suspending recovery email."
            _sleep_sec "$_poll_int"
            continue
        fi

        # Re-verify persistent state immediately before transmitting
        if ! _state_load_unlocked || [ "$RECOVERY_STATE" != "RECOVERY_PENDING" ]; then
            echo "[FSD-RECOVERY] Recovery state changed before send (${RECOVERY_STATE:-CLEARED}); aborting."
            return 0
        fi

        if _send_recovery_notification "$_recipient"; then
            cmd_clear
            echo "[FSD-RECOVERY] ✅ Post-FSD power restored email delivered; recovery state cleared."
            return 0
        fi

        _attempts=$((_attempts + 1))
        if [ "$_max_attempts" -gt 0 ] && [ "$_attempts" -ge "$_max_attempts" ]; then
            echo "[FSD-RECOVERY] ❌ Max delivery attempts (${_max_attempts}) exhausted; clearing pending state." >&2
            cmd_clear
            return 1
        fi

        echo "[FSD-RECOVERY] ⚠️ Delivery failed (attempt #${_attempts}, network/SMTP may not be ready yet). Retrying in ${_retry_delay}s..." >&2
        _sleep_sec "$_retry_delay"
        _retry_delay=$(_compute_next_retry_delay "$_retry_delay" "$_retry_max")
    done
}

# ---------------------------------------------------------------------
# main: Dispatch CLI subcommand to the corresponding recovery method.
# ---------------------------------------------------------------------
main() {
    _action="${1:-}"
    [ $# -gt 0 ] && shift

    case "$_action" in
        mark-fsd)           cmd_mark_fsd "$@" ;;
        activate)           cmd_activate ;;
        is-recovery-active) cmd_is_recovery_active ;;
        clear)              cmd_clear ;;
        status)             cmd_status ;;
        daemon)             cmd_daemon "$@" ;;
        *)
            echo "Usage: $0 {mark-fsd [charge] [blackout_start]|activate|is-recovery-active|clear|status|daemon [recipient] [ups_name]}" >&2
            exit 1
            ;;
    esac
}

main "$@"
