#!/bin/sh
set -u

# =====================================================================
# MESSAGE BUILDER SCRIPT (build_message.sh)
# Responsibilities: Load language dictionaries (.lang), decode NUT status
# codes, assemble localized message text and standardized telemetry block.
# Outputs to STDOUT in standard RFC-822 format:
#   Subject: <subject>
#   <empty line>
#   <body>
# =====================================================================

EVENT_TYPE="${1:-test}"
ALERT_LANG="${ALERT_LANG:-it}"
UPS_NAME="${UPS_NAME:-}"
UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"

# 1. Load language module (.lang) with automatic fallback to English (en)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

if [ -d "/alerts" ]; then
    ALERTS_DIR="/alerts"
elif [ -d "$BASE_DIR/alerts" ]; then
    ALERTS_DIR="$BASE_DIR/alerts"
else
    ALERTS_DIR="./alerts"
fi

LANG_FILE="${ALERTS_DIR}/${ALERT_LANG}.lang"
FALLBACK_FILE="${ALERTS_DIR}/en.lang"

if [ -f "$LANG_FILE" ]; then
    . "$LANG_FILE"
elif [ -f "$FALLBACK_FILE" ]; then
    . "$FALLBACK_FILE"
else
    FIRST_LANG=$(ls "$ALERTS_DIR"/*.lang 2>/dev/null | head -n1 || true)
    if [ -f "$FIRST_LANG" ]; then
        . "$FIRST_LANG"
    else
        echo "❌ ERROR: No .lang translation files found in $ALERTS_DIR" >&2
        exit 1
    fi
fi

# 2. Auto-detect UPS name (if not provided by environment)
if [ -z "$UPS_NAME" ]; then
    UPS_NAME=$(upsc -l localhost 2>/dev/null | head -n1 || true)
fi
if [ -z "$UPS_NAME" ] && [ -f "/etc/nut/ups.conf" ]; then
    UPS_NAME=$(sed -n 's/^\[\([^]]*\)\]/\1/p' /etc/nut/ups.conf | head -n1 || true)
fi
UPS_NAME="${UPS_NAME:-ups}"

# 3. Determine display name (Friendly Name or Hardware Manufacturer & Model)
if [ -n "$UPS_FRIENDLY_NAME" ]; then
    UPS_DISPLAY="$UPS_FRIENDLY_NAME"
else
    UPS_MFR=$(upsc "${UPS_NAME}@localhost" ups.mfr 2>/dev/null || echo "")
    UPS_MODEL=$(upsc "${UPS_NAME}@localhost" ups.model 2>/dev/null || echo "")

    if [ -n "$UPS_MFR" ] && [ -n "$UPS_MODEL" ]; then
        UPS_DISPLAY="$UPS_MFR $UPS_MODEL"
    elif [ -n "$UPS_MODEL" ]; then
        UPS_DISPLAY="$UPS_MODEL"
    else
        UPS_DISPLAY="UPS ($UPS_NAME)"
    fi
fi

# 4. Collect telemetry metrics (if not already supplied by caller environment)
TIMESTAMP="${TIMESTAMP:-$(date '+%d/%m/%Y %H:%M:%S')}"
RAW_STATUS="${RAW_STATUS:-$(upsc "${UPS_NAME}@localhost" ups.status 2>/dev/null || echo "N/D")}"
CHARGE="${CHARGE:-$(upsc "${UPS_NAME}@localhost" battery.charge 2>/dev/null || echo "100")}"
RUNTIME="${RUNTIME:-$(upsc "${UPS_NAME}@localhost" battery.runtime 2>/dev/null || echo "0")}"
RUNTIME_MIN="${RUNTIME_MIN:-$((RUNTIME / 60))}"
VOLTAGE="${VOLTAGE:-$(upsc "${UPS_NAME}@localhost" input.voltage 2>/dev/null || echo "0")}"
LOAD="${LOAD:-$(upsc "${UPS_NAME}@localhost" ups.load 2>/dev/null || echo "0")}"
DURATION_MIN="${DURATION_MIN:-0}"
DURATION_SEC="${DURATION_SEC:-0}"

# 5. Format and translate NUT status flags
format_status() {
    STATUS_STR="$1"
    FORMATTED=""
    for word in $STATUS_STR; do
        case "$word" in
            OL) DESC="${STATUS_OL:-$word}" ;;
            OB) DESC="${STATUS_OB:-$word}" ;;
            CHRG) DESC="${STATUS_CHRG:-$word}" ;;
            DISCHRG) DESC="${STATUS_DISCHRG:-$word}" ;;
            LB) DESC="${STATUS_LB:-$word}" ;;
            FSD) DESC="${STATUS_FSD:-$word}" ;;
            OVER) DESC="${STATUS_OVER:-$word}" ;;
            RB) DESC="${STATUS_RB:-$word}" ;;
            CAL) DESC="${STATUS_CAL:-$word}" ;;
            OFF) DESC="${STATUS_OFF:-$word}" ;;
            *) DESC="$word" ;;
        esac
        if [ -z "$FORMATTED" ]; then
            FORMATTED="$DESC"
        else
            FORMATTED="$FORMATTED + $DESC"
        fi
    done
    echo "${FORMATTED:-$STATUS_STR}"
}

STATUS_DESC=$(format_status "$RAW_STATUS")

# 6. Standardized telemetry details block
build_details() {
    printf "%s\n- %s: %s\n- %s: %s\n- %s: %s%%\n- %s: %s %s (%s %s)\n- %s: %s%%\n- %s: %s V" \
        "$LABEL_DETAILS" \
        "$LABEL_TIMESTAMP" "$TIMESTAMP" \
        "$LABEL_STATUS" "$STATUS_DESC" \
        "$LABEL_BATTERY" "$CHARGE" \
        "$LABEL_RUNTIME" "$RUNTIME_MIN" "$UNIT_MINUTES" "$RUNTIME" "$UNIT_SECONDS" \
        "$LABEL_LOAD" "$LOAD" \
        "$LABEL_VOLTAGE" "$VOLTAGE"
}

# 7. Select subject and body based on event type
case "$EVENT_TYPE" in
    blackout)
        SUBJECT=$(printf "$SUBJECT_BLACKOUT" "$UPS_DISPLAY")
        MSG="$MSG_BLACKOUT"
        ;;
    power_restored)
        SUBJECT=$(printf "$SUBJECT_POWER_RESTORED" "$UPS_DISPLAY")
        DURATION_INFO=$(printf "$LABEL_OUTAGE_DURATION" "$DURATION_MIN" "$DURATION_SEC")
        MSG="${MSG_POWER_RESTORED}
${DURATION_INFO}"
        ;;
    batt_70)
        SUBJECT=$(printf "$SUBJECT_BATT_70" "$UPS_DISPLAY")
        MSG="$MSG_BATT_70"
        ;;
    batt_50)
        SUBJECT=$(printf "$SUBJECT_BATT_50" "$UPS_DISPLAY")
        MSG="$MSG_BATT_50"
        ;;
    batt_35)
        SUBJECT=$(printf "$SUBJECT_BATT_35" "$UPS_DISPLAY")
        MSG="$MSG_BATT_35"
        ;;
    fsd)
        SUBJECT=$(printf "$SUBJECT_FSD" "$UPS_DISPLAY")
        MSG="$MSG_FSD"
        ;;
    overload)
        SUBJECT=$(printf "$SUBJECT_OVERLOAD" "$UPS_DISPLAY")
        MSG="$MSG_OVERLOAD"
        ;;
    overload_cleared)
        SUBJECT=$(printf "$SUBJECT_OVERLOAD_CLEARED" "$UPS_DISPLAY")
        MSG="$MSG_OVERLOAD_CLEARED"
        ;;
    test|*)
        SUBJECT=$(printf "$SUBJECT_TEST" "$UPS_DISPLAY")
        MSG="$MSG_TEST"
        ;;
esac

DETAILS=$(build_details)

# 8. Output to STDOUT for direct piping into send_mail.sh
printf "Subject: %s\n\n%s\n\n%s\n" "$SUBJECT" "$MSG" "$DETAILS"
