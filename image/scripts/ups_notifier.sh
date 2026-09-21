#!/bin/sh
set -u

# =====================================================================
# UPS STATUS MONITOR DAEMON (ups_notifier.sh)
# Responsibilities: Communicate with NUT (upsc), maintain state machine,
# detect threshold transitions, and trigger the Unix alert pipeline:
#   build_message.sh <event> | send_mail.sh <recipient>
# =====================================================================

NOTIFICATION_EMAIL="${1:-${NOTIFICATION_EMAIL:-}}"
UPS_NAME="${2:-${UPS_NAME:-}}"
ALERT_LANG="${ALERT_LANG:-en}"
UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# If recipient email is not provided via argument or variable, read from file
if [ -z "$NOTIFICATION_EMAIL" ] && [ -f "/etc/notification_email" ]; then
    NOTIFICATION_EMAIL=$(cat /etc/notification_email | tr -d ' \r\n')
fi

# 1. Wait until NUT server is ready and responding
echo "[NOTIFIER] Waiting for NUT server to become ready..."
RETRY=0
while [ -z "$UPS_NAME" ] || ! upsc "${UPS_NAME}@localhost" ups.status >/dev/null 2>&1; do
    if [ -z "$UPS_NAME" ]; then
        UPS_NAME=$(upsc -l localhost 2>/dev/null | head -n1 || true)
    fi
    sleep 2
    RETRY=$((RETRY + 1))
    if [ "$RETRY" -ge 30 ] && [ -z "$UPS_NAME" ]; then
        UPS_NAME="ups"
    fi
done

echo "[NOTIFIER] NUT server reachable. Monitoring started (UPS: $UPS_NAME, Friendly: ${UPS_FRIENDLY_NAME:-N/A}, Language: $ALERT_LANG)"

PREV_STATUS="OL"
SENT_70=0
SENT_50=0
SENT_35=0
SENT_FSD=0
SENT_OVER=0
BLACKOUT_START=0

# Trigger the modular Unix pipeline: build_message.sh -> send_mail.sh
trigger_event() {
    EVENT_NAME="$1"
    export TIMESTAMP RAW_STATUS CHARGE RUNTIME RUNTIME_MIN VOLTAGE LOAD DURATION_MIN DURATION_SEC UPS_NAME UPS_FRIENDLY_NAME ALERT_LANG
    "$SCRIPT_DIR/build_message.sh" "$EVENT_NAME" | "$SCRIPT_DIR/send_mail.sh" "$NOTIFICATION_EMAIL" || {
        echo "[NOTIFIER] ⚠️ Error executing notification pipeline for event '$EVENT_NAME'" >&2
    }
}

while true; do
    VARS=$(upsc "${UPS_NAME}@localhost" 2>/dev/null || true)
    RAW_STATUS=$(echo "$VARS" | awk -F': ' '$1=="ups.status"{print $2}')

    if [ -n "$RAW_STATUS" ]; then
        CHARGE=$(echo "$VARS" | awk -F': ' '$1=="battery.charge"{print $2}')
        RUNTIME=$(echo "$VARS" | awk -F': ' '$1=="battery.runtime"{print $2}')
        VOLTAGE=$(echo "$VARS" | awk -F': ' '$1=="input.voltage"{print $2}')
        LOAD=$(echo "$VARS" | awk -F': ' '$1=="ups.load"{print $2}')

        CHARGE="${CHARGE:-100}"
        RUNTIME="${RUNTIME:-0}"
        VOLTAGE="${VOLTAGE:-0}"
        LOAD="${LOAD:-0}"

        TIMESTAMP=$(date '+%d/%m/%Y %H:%M:%S')
        RUNTIME_MIN=$((RUNTIME / 60))
        DURATION_MIN=0
        DURATION_SEC=0

        # 1. EVENT: POWER OUTAGE (Blackout - transitioned from mains OL to battery OB)
        case "$RAW_STATUS" in
            *OB*)
                case "$PREV_STATUS" in
                    *OL*)
                        BLACKOUT_START=$(date +%s)
                        SENT_70=0
                        SENT_50=0
                        SENT_35=0
                        SENT_FSD=0
                        trigger_event "blackout"
                        ;;
                esac
                ;;
        esac

        # 2. EVENT: POWER RESTORED (Transitioned back from battery OB to mains OL)
        case "$RAW_STATUS" in
            *OL*)
                case "$PREV_STATUS" in
                    *OB*)
                        BLACKOUT_END=$(date +%s)
                        if [ "$BLACKOUT_START" -gt 0 ]; then
                            DURATION_SEC=$((BLACKOUT_END - BLACKOUT_START))
                        fi
                        DURATION_MIN=$((DURATION_SEC / 60))
                        trigger_event "power_restored"
                        BLACKOUT_START=0
                        SENT_70=0
                        SENT_50=0
                        SENT_35=0
                        SENT_FSD=0
                        ;;
                esac
                ;;
        esac

        # 3. BATTERY LEVEL THRESHOLDS (While discharging on battery OB)
        case "$RAW_STATUS" in
            *OB*)
                if [ "$CHARGE" -le 70 ] && [ "$SENT_70" -eq 0 ]; then
                    SENT_70=1
                    trigger_event "batt_70"
                fi

                if [ "$CHARGE" -le 50 ] && [ "$SENT_50" -eq 0 ]; then
                    SENT_50=1
                    trigger_event "batt_50"
                fi

                if [ "$CHARGE" -le 35 ] && [ "$SENT_35" -eq 0 ]; then
                    SENT_35=1
                    trigger_event "batt_35"
                fi
                ;;
        esac

        # 4. EVENT: FORCED SHUTDOWN COMMAND (FSD / Shutdown)
        case "$RAW_STATUS" in
            *FSD*|*SHUTDOWN*)
                if [ "$SENT_FSD" -eq 0 ]; then
                    SENT_FSD=1
                    trigger_event "fsd"
                fi
                ;;
        esac

        # 5. EVENT: OVERLOAD
        LOAD_INT="${LOAD%%.*}"
        if case "$RAW_STATUS" in *OVER*) true;; *) false;; esac || [ "${LOAD_INT:-0}" -ge 100 ]; then
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

        PREV_STATUS="$RAW_STATUS"
    fi

    sleep 3
done
