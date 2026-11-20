#!/bin/sh
set -u

# =====================================================================
# POWER CALCULATION MODULE (image/scripts/calculate_power.sh)
# =====================================================================
# Responsibility:
#   Compute real-time active output power draw in Watts (W) using either
#   direct hardware telemetry (ups.realpower / output.realpower) or a
#   dynamic estimate from load percentage and nominal rated capacity.
#
# Arguments / Environment:
#   $1 or RAW_STATUS:          UPS status (e.g. "OL", "OB", "N/D")
#   $2 or LOAD:                Load percentage (e.g. "20", "33.3")
#   $3 or REALPOWER:           Direct hardware power reading in Watts
#   $4 or NOMINAL_REALPOWER:   Rated nominal power in Watts
#   $5 or UNIT_WATTS:          Unit label (default: "W")
#   $6 or LABEL_POWER_NOMINAL: printf template for nominal power display
#
# Output (STDOUT):
#   Formatted power string (e.g. "~120 W (out of 600 W nominal)", "140 W", "N/D")
# =====================================================================

# ---------------------------------------------------------------------
# power_format_output: Format wattage with optional prefix and nominal
# capacity suffix.
# Arguments:
#   $1 - Prefix ("" for direct reading, "~" for estimated reading)
#   $2 - Rounded power value in Watts
#   $3 - Unit label (e.g. "W")
#   $4 - Clean nominal power value (optional)
#   $5 - printf format template for nominal display (optional)
# ---------------------------------------------------------------------
power_format_output() {
    _prefix="$1"
    _watts="$2"
    _unit="$3"
    _nominal="$4"
    _label_template="$5"

    if [ -n "$_nominal" ] && [ "$_nominal" -gt 0 ] 2>/dev/null && [ -n "$_label_template" ]; then
        _nominal_info=$(printf "$_label_template" "$_nominal" "$_unit")
        printf "%s%s %s %s\n" "$_prefix" "$_watts" "$_unit" "$_nominal_info"
    else
        printf "%s%s %s\n" "$_prefix" "$_watts" "$_unit"
    fi
}

# ---------------------------------------------------------------------
# power_calculate: Determine formatted active output power string.
# ---------------------------------------------------------------------
power_calculate() {
    _status="$1"
    _clean_load=$(printf "%s" "$2" | tr -cd '0-9.')
    _clean_realpower=$(printf "%s" "$3" | tr -cd '0-9.')
    _clean_nominal=$(printf "%s" "$4" | tr -cd '0-9.')
    _unit="$5"
    _label_nominal="$6"

    # Unavailable status with no direct hardware power reading
    if [ "$_status" = "N/D" ] && [ -z "$_clean_realpower" ]; then
        echo "N/D"
        return 0
    fi

    # 1. Direct hardware real-power reading (ups.realpower / output.realpower)
    if [ -n "$_clean_realpower" ]; then
        _watts=$(awk -v p="$_clean_realpower" 'BEGIN { printf "%.0f", p }' 2>/dev/null || echo "$_clean_realpower")
        power_format_output "" "$_watts" "$_unit" "$_clean_nominal" "$_label_nominal"
        return 0
    fi

    # 2. Dynamic estimate: (load% * nominal_watts) / 100
    if [ -n "$_clean_nominal" ] && [ "$_clean_nominal" -gt 0 ] 2>/dev/null && [ -n "$_clean_load" ]; then
        _watts=$(awk -v l="$_clean_load" -v n="$_clean_nominal" 'BEGIN { printf "%.0f", (l * n) / 100 }' 2>/dev/null || echo "")
        if [ -n "$_watts" ]; then
            power_format_output "~" "$_watts" "$_unit" "$_clean_nominal" "$_label_nominal"
            return 0
        fi
    fi

    # 3. Fallback when power cannot be determined
    echo "N/D"
}

# ---------------------------------------------------------------------
# main: Parse arguments/environment and print formatted power string.
# ---------------------------------------------------------------------
main() {
    power_calculate \
        "${1:-${RAW_STATUS:-N/D}}" \
        "${2:-${LOAD:-0}}" \
        "${3:-${REALPOWER:-}}" \
        "${4:-${NOMINAL_REALPOWER:-${UPS_NOMINAL_WATTS:-}}}" \
        "${5:-${UNIT_WATTS:-W}}" \
        "${6:-${LABEL_POWER_NOMINAL:-}}"
}

main "$@"
