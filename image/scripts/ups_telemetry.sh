#!/bin/sh
# =====================================================================
# UPS TELEMETRY & DISCOVERY MODULE (image/scripts/ups_telemetry.sh)
# =====================================================================
# Responsibility:
#   Provide shared POSIX helper functions for UPS discovery, NUT server
#   readiness checks, ups.conf runtime overrides, single-shot upsc
#   snapshot parsing, safe integer conversion (handling decimals),
#   stale voltage detection/refresh on power transitions, and recipient
#   email resolution.
#
# Public API:
#   to_int <value>
#   apply_ups_conf_overrides <conf_file> [charge_low] [runtime_low] [offdelay] [ondelay]
#   detect_ups_name [preferred_name] [ups_conf_path]
#   wait_for_nut_server [preferred_name] [poll_interval]
#   resolve_recipient [explicit_email] [email_file] [msmtp_file]
#   parse_upsc_snapshot <raw_upsc_output>
#   fetch_ups_telemetry [ups_name]
#   is_voltage_stale <raw_status> <voltage>
#   trigger_driver_poll [ups_name] [upsd_users_file]
#   refresh_telemetry_on_transition [ups_name]
# =====================================================================

# ---------------------------------------------------------------------
# to_int: Safely convert a numeric or decimal string (e.g. "70.5")
# into a non-negative integer for POSIX /bin/sh arithmetic.
# Arguments:
#   $1 - Numeric string (default: 0)
# Outputs:
#   Integer string to STDOUT
# ---------------------------------------------------------------------
to_int() {
    _val="${1:-0}"
    _int="${_val%%.*}"
    _int=$(printf "%s" "$_int" | tr -cd '0-9')
    printf "%s" "${_int:-0}"
}

# ---------------------------------------------------------------------
# _upsert_ups_conf_param: Update an existing key=value directive in
# ups.conf or append it if absent.
# Arguments:
#   $1 - Path to ups.conf
#   $2 - Parameter key (e.g. "offdelay")
#   $3 - Regex-escaped key pattern (e.g. "override\.battery\.charge\.low")
#   $4 - Parameter value
# ---------------------------------------------------------------------
_upsert_ups_conf_param() {
    _file="$1"
    _key="$2"
    _key_regex="$3"
    _val="$4"

    [ -n "$_val" ] || return 0

    if grep -qE "^[[:space:]]*${_key_regex}[[:space:]]*=" "$_file"; then
        sed -i "s|^[[:space:]]*${_key_regex}[[:space:]]*=.*|    ${_key} = ${_val}|" "$_file"
    else
        printf "    %s = %s\n" "$_key" "$_val" >> "$_file"
    fi
}

# ---------------------------------------------------------------------
# apply_ups_conf_overrides: Synchronize Low Battery thresholds and
# shutdown delays from environment variables into /etc/nut/ups.conf,
# enabling 'ignorelb' whenever custom LB thresholds are configured.
# Arguments:
#   $1 - Path to ups.conf (default: /etc/nut/ups.conf)
#   $2 - Low battery charge threshold (%)
#   $3 - Low battery runtime threshold (seconds)
#   $4 - UPS outlet power-off delay (seconds)
#   $5 - UPS auto-restart delay (seconds)
# ---------------------------------------------------------------------
apply_ups_conf_overrides() {
    _conf_file="${1:-/etc/nut/ups.conf}"
    _charge_low="${2:-${BATTERY_CHARGE_LOW:-}}"
    _runtime_low="${3:-${BATTERY_RUNTIME_LOW:-}}"
    _offdelay="${4:-${UPS_OFFDELAY:-}}"
    _ondelay="${5:-${UPS_ONDELAY:-}}"

    [ -f "$_conf_file" ] || return 0

    if [ -n "$_charge_low" ] || [ -n "$_runtime_low" ]; then
        if ! grep -qE '^[[:space:]]*ignorelb([[:space:]]|$)' "$_conf_file"; then
            printf "    ignorelb\n" >> "$_conf_file"
        fi
    fi

    _upsert_ups_conf_param "$_conf_file" "override.battery.charge.low" "override\.battery\.charge\.low" "$_charge_low"
    _upsert_ups_conf_param "$_conf_file" "override.battery.runtime.low" "override\.battery\.runtime\.low" "$_runtime_low"
    _upsert_ups_conf_param "$_conf_file" "offdelay" "offdelay" "$_offdelay"
    _upsert_ups_conf_param "$_conf_file" "ondelay" "ondelay" "$_ondelay"
}

# ---------------------------------------------------------------------
# detect_ups_name: Auto-discover the UPS identifier from explicit arg,
# environment variable, live upsc listing, or ups.conf section header.
# Arguments:
#   $1 - Explicit UPS name (optional)
#   $2 - Path to ups.conf (default: /etc/nut/ups.conf)
# Outputs:
#   UPS identifier string to STDOUT (fallback: "ups")
# ---------------------------------------------------------------------
detect_ups_name() {
    _name="${1:-${UPS_NAME:-}}"
    _conf="${2:-/etc/nut/ups.conf}"

    if [ -z "$_name" ]; then
        _name=$(upsc -l localhost 2>/dev/null | head -n1 || true)
    fi
    if [ -z "$_name" ] && [ -f "$_conf" ]; then
        _name=$(sed -n 's/^\[\([^]]*\)\]/\1/p' "$_conf" | head -n1 || true)
    fi
    printf "%s" "${_name:-ups}"
}

# ---------------------------------------------------------------------
# wait_for_nut_server: Block until upsd responds to upsc queries and
# set UPS_NAME to the discovered device identifier.
# Arguments:
#   $1 - Preferred UPS identifier (optional)
#   $2 - Poll interval in seconds (default: 2)
# Side Effects:
#   Sets global UPS_NAME
# ---------------------------------------------------------------------
wait_for_nut_server() {
    _wait_ups="${1:-${UPS_NAME:-}}"
    _wait_interval=$(to_int "${2:-2}")
    _wait_retry=0

    while [ -z "$_wait_ups" ] || ! upsc "${_wait_ups}@localhost" ups.status >/dev/null 2>&1; do
        if [ -z "$_wait_ups" ]; then
            _wait_ups=$(upsc -l localhost 2>/dev/null | head -n1 || true)
        fi
        if [ "$_wait_interval" -gt 0 ]; then
            sleep "$_wait_interval"
        fi
        _wait_retry=$((_wait_retry + 1))
        if [ "$_wait_retry" -ge 30 ] && [ -z "$_wait_ups" ]; then
            _wait_ups=$(detect_ups_name "")
        fi
    done

    UPS_NAME="$_wait_ups"
}

# ---------------------------------------------------------------------
# resolve_recipient: Determine target notification email from explicit
# argument, NOTIFICATION_EMAIL env var, notification_email file, or
# the msmtprc sender address.
# Arguments:
#   $1 - Explicit email address (optional)
#   $2 - Path to notification email file (default: /etc/notification_email)
#   $3 - Path to msmtprc file (default: /etc/msmtprc)
# Outputs:
#   Email address string to STDOUT (empty if unconfigured)
# ---------------------------------------------------------------------
resolve_recipient() {
    _recip="${1:-${NOTIFICATION_EMAIL:-}}"
    _email_file="${2:-/etc/notification_email}"
    _msmtp_file="${3:-/etc/msmtprc}"

    if [ -z "$_recip" ] && [ -f "$_email_file" ]; then
        _recip=$(tr -d ' \r\n' < "$_email_file")
    fi
    if [ -z "$_recip" ] && [ -f "$_msmtp_file" ]; then
        _recip=$(awk '$1=="from"{print $2; exit}' "$_msmtp_file")
    fi
    printf "%s" "$_recip"
}

# ---------------------------------------------------------------------
# parse_upsc_snapshot: Parse raw 'upsc' key: value output into exported
# telemetry variables (both raw strings and safe integer equivalents).
# Arguments:
#   $1 - Multi-line output from 'upsc <ups>@localhost'
# ---------------------------------------------------------------------
parse_upsc_snapshot() {
    _vars="$1"

    RAW_STATUS=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="ups.status"{print $2; exit}')
    CHARGE=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="battery.charge"{print $2; exit}')
    RUNTIME=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="battery.runtime"{print $2; exit}')
    VOLTAGE=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="input.voltage"{print $2; exit}')
    LOAD=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="ups.load"{print $2; exit}')
    REALPOWER=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="ups.realpower" || $1=="output.realpower"{print $2; exit}')
    NOMINAL_REALPOWER=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="ups.realpower.nominal" || $1=="output.realpower.nominal"{print $2; exit}')
    UPS_MFR=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="ups.mfr"{print $2; exit}')
    UPS_MODEL=$(printf "%s\n" "$_vars" | awk -F': ' '$1=="ups.model"{print $2; exit}')

    CHARGE="${CHARGE:-100}"
    RUNTIME="${RUNTIME:-0}"
    VOLTAGE="${VOLTAGE:-0}"
    LOAD="${LOAD:-0}"
    REALPOWER="${REALPOWER:-}"
    NOMINAL_REALPOWER="${NOMINAL_REALPOWER:-${UPS_NOMINAL_WATTS:-}}"

    CHARGE_INT=$(to_int "$CHARGE")
    RUNTIME_INT=$(to_int "$RUNTIME")
    LOAD_INT=$(to_int "$LOAD")
    VOLTAGE_INT=$(to_int "$VOLTAGE")
    RUNTIME_MIN=$((RUNTIME_INT / 60))

    export RAW_STATUS CHARGE CHARGE_INT RUNTIME RUNTIME_INT RUNTIME_MIN \
           VOLTAGE VOLTAGE_INT LOAD LOAD_INT REALPOWER NOMINAL_REALPOWER \
           UPS_MFR UPS_MODEL
}

# ---------------------------------------------------------------------
# fetch_ups_telemetry: Execute a single upsc query and populate the
# telemetry snapshot variables.
# Arguments:
#   $1 - Target UPS identifier (default: $UPS_NAME or "ups")
# ---------------------------------------------------------------------
fetch_ups_telemetry() {
    _target_ups="${1:-${UPS_NAME:-ups}}"
    _raw_vars=$(upsc "${_target_ups}@localhost" 2>/dev/null || true)
    parse_upsc_snapshot "$_raw_vars"
}

# ---------------------------------------------------------------------
# is_voltage_stale: Detect cached/stale input.voltage immediately after
# a power transition (OL -> OB showing >50V, or OB -> OL showing <=0V).
# Arguments:
#   $1 - Raw ups.status string
#   $2 - Current input.voltage reading
# Returns:
#   0 if stale, 1 if fresh/consistent
# ---------------------------------------------------------------------
is_voltage_stale() {
    _status="$1"
    _volt_int=$(to_int "$2")

    case "$_status" in
        *OB*)
            # On battery (blackout): input voltage should have dropped near 0V
            if [ "$_volt_int" -gt 50 ]; then
                return 0
            fi
            ;;
        *OL*)
            # On mains power: input voltage should be positive
            if [ "$_volt_int" -le 0 ]; then
                return 0
            fi
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------
# trigger_driver_poll: Trigger an immediate on-demand HID Full Update
# on usbhid-ups by writing back an existing safe HID attribute's value.
# Arguments:
#   $1 - Target UPS identifier (default: $UPS_NAME or "ups")
#   $2 - Path to upsd.users (default: /etc/nut/upsd.users)
# ---------------------------------------------------------------------
trigger_driver_poll() {
    _target_ups="${1:-${UPS_NAME:-ups}}"
    _users_file="${2:-/etc/nut/upsd.users}"

    [ -f "$_users_file" ] || return 0

    _user=$(sed -n 's/^\[\([^]]*\)\]/\1/p' "$_users_file" | head -n1)
    _pass=$(awk -F'= ' '/^[[:space:]]*password[[:space:]]*=/{print $2; exit}' "$_users_file" | tr -d ' \r\n')
    [ -n "$_user" ] && [ -n "$_pass" ] || return 0

    # Write back the current value of the first supported safe HID variable
    for _var in "ups.delay.start" "input.transfer.low" "input.transfer.high"; do
        _cur_val=$(upsc "${_target_ups}@localhost" "$_var" 2>/dev/null || true)
        if [ -n "$_cur_val" ]; then
            upsrw -s "${_var}=${_cur_val}" -u "$_user" -p "$_pass" "${_target_ups}@localhost" >/dev/null 2>&1 || true
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------------------
# refresh_telemetry_on_transition: Force an on-demand HID driver poll
# and re-read upsc until input.voltage matches the new power state.
# Arguments:
#   $1 - Target UPS identifier (default: $UPS_NAME or "ups")
# ---------------------------------------------------------------------
refresh_telemetry_on_transition() {
    _target_ups="${1:-${UPS_NAME:-ups}}"
    _max_retries="${TRANSITION_RETRY_MAX:-15}"
    _retry_delay="${TRANSITION_RETRY_DELAY:-2}"
    _attempt=0

    if ! is_voltage_stale "$RAW_STATUS" "$VOLTAGE"; then
        return 0
    fi

    trigger_driver_poll "$_target_ups"

    while [ "$_attempt" -lt "$_max_retries" ]; do
        sleep "$_retry_delay"
        fetch_ups_telemetry "$_target_ups"
        if ! is_voltage_stale "$RAW_STATUS" "$VOLTAGE"; then
            return 0
        fi
        _attempt=$((_attempt + 1))
    done
    return 0
}
