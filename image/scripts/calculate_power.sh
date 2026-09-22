#!/bin/sh
set -u

# =====================================================================
# POWER CALCULATION SCRIPT (calculate_power.sh)
# Responsibilities: Compute real-time active power draw in Watts (W)
# using either direct hardware telemetry (ups.realpower) or dynamic
# calculation from current load percentage and rated nominal capacity.
#
# Arguments / Environment:
#   $1 or RAW_STATUS:          UPS status (e.g. OL, OB, N/D)
#   $2 or LOAD:                Load percentage (e.g. 20, 33.3)
#   $3 or REALPOWER:           Direct hardware power reading in Watts (optional)
#   $4 or NOMINAL_REALPOWER:   Rated nominal power in Watts (optional)
#   $5 or UNIT_WATTS:          Unit label (default: W)
#   $6 or LABEL_POWER_NOMINAL: Format string for nominal power display
#
# Outputs to STDOUT:
#   Formatted power string (e.g. "~104 W (su 520 W nominali)", "140 W", "N/D")
# =====================================================================

STATUS="${1:-${RAW_STATUS:-N/D}}"
LOAD="${2:-${LOAD:-0}}"
REALPOWER="${3:-${REALPOWER:-}}"
NOMINAL="${4:-${NOMINAL_REALPOWER:-${UPS_NOMINAL_WATTS:-}}}"
UNIT="${5:-${UNIT_WATTS:-W}}"
LABEL_NOMINAL="${6:-${LABEL_POWER_NOMINAL:-}}"

CLEAN_REALPOWER=$(echo "$REALPOWER" | tr -cd '0-9.')
CLEAN_NOMINAL=$(echo "$NOMINAL" | tr -cd '0-9.')
CLEAN_LOAD=$(echo "$LOAD" | tr -cd '0-9.')

# If UPS status is unavailable (N/D) and no direct reading exists
if [ "$STATUS" = "N/D" ] && [ -z "$CLEAN_REALPOWER" ]; then
    echo "N/D"
    exit 0
fi

# 1. Direct hardware real power measurement (ups.realpower / output.realpower)
if [ -n "$CLEAN_REALPOWER" ]; then
    WATTS=$(awk -v p="$CLEAN_REALPOWER" 'BEGIN { printf "%.0f", p }' 2>/dev/null || echo "$CLEAN_REALPOWER")
    if [ -n "$CLEAN_NOMINAL" ] && [ "$CLEAN_NOMINAL" -gt 0 ] 2>/dev/null && [ -n "$LABEL_NOMINAL" ]; then
        NOMINAL_INFO=$(printf "$LABEL_NOMINAL" "$CLEAN_NOMINAL" "$UNIT")
        echo "${WATTS} ${UNIT} ${NOMINAL_INFO}"
    else
        echo "${WATTS} ${UNIT}"
    fi
    exit 0
fi

# 2. Dynamic calculation from UPS load percentage and nominal power reported by UPS
if [ -n "$CLEAN_NOMINAL" ] && [ "$CLEAN_NOMINAL" -gt 0 ] 2>/dev/null && [ -n "$CLEAN_LOAD" ]; then
    WATTS=$(awk -v l="$CLEAN_LOAD" -v n="$CLEAN_NOMINAL" 'BEGIN { printf "%.0f", (l * n) / 100 }' 2>/dev/null || echo "")
    if [ -n "$WATTS" ]; then
        if [ -n "$LABEL_NOMINAL" ]; then
            NOMINAL_INFO=$(printf "$LABEL_NOMINAL" "$CLEAN_NOMINAL" "$UNIT")
            echo "~${WATTS} ${UNIT} ${NOMINAL_INFO}"
        else
            echo "~${WATTS} ${UNIT}"
        fi
        exit 0
    fi
fi

# 3. Fallback when power cannot be determined
echo "N/D"
