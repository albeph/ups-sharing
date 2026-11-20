#!/bin/sh
set -u

# =====================================================================
# UPS STATUS MONITOR DAEMON (image/scripts/ups_notifier.sh)
# =====================================================================
# Responsibility:
#   Poll live UPS telemetry from NUT (upsc), execute the event state
#   machine (blackout, power restoration, battery thresholds, Forced
#   Shutdown, electrical overload), refresh stale input.voltage readings
#   on power flips, coordinate with fsd_recovery.sh to avoid duplicates,
#   and dispatch alerts through the modular Unix pipeline:
#     build_message.sh <event> | send_mail.sh <recipient>
#
# Sourcing mode (for unit testing):
#   Set UPS_NOTIFIER_LIB_ONLY=1 before sourcing to load the state
#   machine methods without entering the polling loop.
# =====================================================================

SCRIPT_DIR="${UPS_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
. "$SCRIPT_DIR/ups_telemetry.sh"

NOTIFICATION_EMAIL=$(resolve_recipient "${1:-${NOTIFICATION_EMAIL:-}}")
UPS_NAME="${2:-${UPS_NAME:-}}"
ALERT_LANG="${ALERT_LANG:-en}"
UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"
UPS_NOMINAL_WATTS="${UPS_NOMINAL_WATTS:-}"
FSD_RECOVERY_BIN="${FSD_RECOVERY_BIN:-$SCRIPT_DIR/fsd_recovery.sh}"
NOTIFIER_POLL_INTERVAL="${NOTIFIER_POLL_INTERVAL:-3}"

# State machine fields
PREV_STATUS="OL"
SENT_70=0
SENT_50=0
SENT_35=0
SENT_FSD=0
SENT_OVER=0
BLACKOUT_START=0

# ---------------------------------------------------------------------
# trigger_event: Export snapshot context and execute the notification
# pipeline (build_message.sh -> send_mail.sh).
# Arguments:
#   $1 - Event identifier (e.g. "blackout", "power_restored", "fsd")
# ---------------------------------------------------------------------
trigger_event() {
    EVENT_NAME="$1"
    export TIMESTAMP RAW_STATUS CHARGE RUNTIME RUNTIME_MIN VOLTAGE LOAD \
           REALPOWER NOMINAL_REALPOWER DURATION_MIN DURATION_SEC \
           UPS_NAME UPS_FRIENDLY_NAME ALERT_LANG UPS_NOMINAL_WATTS

    "$SCRIPT_DIR/build_message.sh" "$EVENT_NAME" | "$SCRIPT_DIR/send_mail.sh" "$NOTIFICATION_EMAIL" || {
        echo "[NOTIFIER] ⚠️ Error executing notification pipeline for event '${EVENT_NAME}'" >&2
    }
}

# ---------------------------------------------------------------------
# notifier_reset_outage_flags: Clear per-outage alert tracking flags.
# ---------------------------------------------------------------------
notifier_reset_outage_flags() {
    SENT_70=0
    SENT_50=0
    SENT_35=0
    SENT_FSD=0
}

# ---------------------------------------------------------------------
# notifier_handle_blackout: Process OL -> OB transition (power outage).
# Refreshes potentially stale input.voltage and applies charging-deficit
# protection so already-crossed thresholds do not cause alert storms.
# ---------------------------------------------------------------------
notifier_handle_blackout() {
    case "$RAW_STATUS" in
        *OB*)
            case "$PREV_STATUS" in
                *OL*)
                    BLACKOUT_START=$(date +%s)
                    notifier_reset_outage_flags
                    # Force on-demand HID refresh for accurate input.voltage
                    refresh_telemetry_on_transition "$UPS_NAME"
                    # Charging-deficit protection: suppress thresholds already crossed at blackout start
                    if [ "$CHARGE_INT" -le 70 ]; then SENT_70=1; fi
                    if [ "$CHARGE_INT" -le 50 ]; then SENT_50=1; fi
                    if [ "$CHARGE_INT" -le 35 ]; then SENT_35=1; fi
                    trigger_event "blackout"
                    ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------
# notifier_handle_power_restored: Process OB -> OL transition (mains
# returned). Delegates to fsd_recovery.sh if a post-FSD reboot recovery
# notification is currently active to guarantee zero duplicate emails.
# ---------------------------------------------------------------------
notifier_handle_power_restored() {
    case "$RAW_STATUS" in
        *OL*)
            case "$PREV_STATUS" in
                *OB*)
                    if [ -x "$FSD_RECOVERY_BIN" ] && "$FSD_RECOVERY_BIN" is-recovery-active; then
                        echo "[NOTIFIER] Post-FSD recovery manager is active; delegating power_restored notification to avoid duplicates."
                    else
                        _blackout_end=$(date +%s)
                        if [ "$BLACKOUT_START" -gt 0 ] && [ "$_blackout_end" -gt "$BLACKOUT_START" ]; then
                            DURATION_SEC=$((_blackout_end - BLACKOUT_START))
                        fi
                        DURATION_MIN=$((DURATION_SEC / 60))
                        refresh_telemetry_on_transition "$UPS_NAME"
                        trigger_event "power_restored"

                        # Clear any FSD marker recorded during this runtime if mains returned before halt
                        if [ -x "$FSD_RECOVERY_BIN" ]; then
                            case "$RAW_STATUS" in
                                *FSD*|*SHUTDOWN*) ;;
                                *) "$FSD_RECOVERY_BIN" clear >/dev/null 2>&1 || true ;;
                            esac
                        fi
                    fi

                    BLACKOUT_START=0
                    notifier_reset_outage_flags
                    ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------
# notifier_handle_battery_thresholds: Evaluate battery charge thresholds
# (35% -> 50% -> 70%) while running on battery, using cascade marking
# from most critical upward to prevent multi-email bursts.
# ---------------------------------------------------------------------
notifier_handle_battery_thresholds() {
    case "$RAW_STATUS" in
        *OB*)
            if [ "$CHARGE_INT" -le 35 ] && [ "$SENT_35" -eq 0 ]; then
                SENT_70=1
                SENT_50=1
                SENT_35=1
                trigger_event "batt_35"
            elif [ "$CHARGE_INT" -le 50 ] && [ "$SENT_50" -eq 0 ]; then
                SENT_70=1
                SENT_50=1
                trigger_event "batt_50"
            elif [ "$CHARGE_INT" -le 70 ] && [ "$SENT_70" -eq 0 ]; then
                SENT_70=1
                trigger_event "batt_70"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------
# notifier_handle_fsd: Persist post-FSD recovery marker on disk before
# dispatching the Forced Shutdown notification email.
# ---------------------------------------------------------------------
notifier_handle_fsd() {
    case "$RAW_STATUS" in
        *FSD*|*SHUTDOWN*)
            if [ "$SENT_FSD" -eq 0 ]; then
                SENT_FSD=1
                # Persist FSD marker BEFORE SMTP so it survives immediate power-off
                if [ -x "$FSD_RECOVERY_BIN" ]; then
                    "$FSD_RECOVERY_BIN" mark-fsd "$CHARGE" "$BLACKOUT_START" || true
                fi
                trigger_event "fsd"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------
# notifier_handle_overload: Track electrical overload entry and recovery.
# ---------------------------------------------------------------------
notifier_handle_overload() {
    if case "$RAW_STATUS" in *OVER*) true;; *) false;; esac || [ "$LOAD_INT" -ge 100 ]; then
        if [ "$SENT_OVER" -eq 0 ]; then
            SENT_OVER=1
            trigger_event "overload"
        fi
    else
        if [ "$SENT_OVER" -eq 1 ]; then
            SENT_OVER=0
            trigger_event "overload_cleared"
        fi
    fi
}

# ---------------------------------------------------------------------
# process_ups_snapshot: Advance the UPS event state machine by one
# telemetry snapshot.
# ---------------------------------------------------------------------
process_ups_snapshot() {
    [ -n "${RAW_STATUS:-}" ] || return 0

    TIMESTAMP=$(date '+%d/%m/%Y %H:%M:%S')
    DURATION_MIN=0
    DURATION_SEC=0

    notifier_handle_blackout
    notifier_handle_power_restored
    notifier_handle_battery_thresholds
    notifier_handle_fsd
    notifier_handle_overload

    PREV_STATUS="$RAW_STATUS"
}

# ---------------------------------------------------------------------
# notifier_main: Wait for NUT server readiness and run polling loop.
# ---------------------------------------------------------------------
notifier_main() {
    echo "[NOTIFIER] Waiting for NUT server to become ready..."
    wait_for_nut_server "$UPS_NAME" 2
    echo "[NOTIFIER] NUT server reachable. Monitoring started (UPS: ${UPS_NAME}, Friendly: ${UPS_FRIENDLY_NAME:-N/A}, Language: ${ALERT_LANG})"

    while true; do
        fetch_ups_telemetry "$UPS_NAME"
        process_ups_snapshot
        sleep "$NOTIFIER_POLL_INTERVAL"
    done
}

# Allow sourcing this file as a library for deterministic unit testing
if [ "${UPS_NOTIFIER_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

notifier_main
