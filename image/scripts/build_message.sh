#!/bin/sh
set -u

# =====================================================================
# MESSAGE BUILDER MODULE (image/scripts/build_message.sh)
# =====================================================================
# Responsibility:
#   Load localized notification dictionaries (.lang) with automatic
#   English fallback, decode NUT status flags, assemble event-specific
#   message bodies and standardized telemetry detail blocks, and emit
#   RFC-822 formatted messages to STDOUT for piping into send_mail.sh:
#     Subject: <subject>
#     <empty line>
#     <body>
#
# Usage:
#   build_message.sh <event_type>
#   Events: blackout | power_restored | batt_70 | batt_50 | batt_35 |
#           fsd | fsd_power_restored | overload | overload_cleared | test
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/ups_telemetry.sh"

# ---------------------------------------------------------------------
# msg_resolve_alerts_dir: Locate the directory containing .lang files.
# Outputs:
#   Directory path to STDOUT
# ---------------------------------------------------------------------
msg_resolve_alerts_dir() {
    if [ -d "/alerts" ]; then
        printf "/alerts"
    elif [ -d "$BASE_DIR/alerts" ]; then
        printf "%s/alerts" "$BASE_DIR"
    else
        printf "./alerts"
    fi
}

# ---------------------------------------------------------------------
# msg_load_dictionary: Source English baseline dictionary first, then
# overlay the requested ALERT_LANG dictionary if available.
# Arguments:
#   $1 - Alerts directory path
#   $2 - Language code (e.g. "en", "it")
# ---------------------------------------------------------------------
msg_load_dictionary() {
    _alerts_dir="$1"
    _lang_code="$2"
    _lang_file="${_alerts_dir}/${_lang_code}.lang"
    _fallback_file="${_alerts_dir}/en.lang"

    if [ -f "$_fallback_file" ]; then
        . "$_fallback_file"
    fi

    if [ -f "$_lang_file" ]; then
        if [ "$_lang_file" != "$_fallback_file" ]; then
            . "$_lang_file"
        fi
    elif [ ! -f "$_fallback_file" ]; then
        _first_lang=$(ls "${_alerts_dir}"/*.lang 2>/dev/null | head -n1 || true)
        if [ -f "$_first_lang" ]; then
            . "$_first_lang"
        else
            echo "❌ ERROR: No .lang translation files found in ${_alerts_dir}" >&2
            return 1
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------
# msg_ensure_telemetry: Fetch a single-shot upsc snapshot if telemetry
# was not pre-populated by the caller, and normalize derived fields.
# ---------------------------------------------------------------------
msg_ensure_telemetry() {
    if [ -z "${RAW_STATUS:-}" ]; then
        fetch_ups_telemetry "$UPS_NAME"
    fi

    TIMESTAMP="${TIMESTAMP:-$(date '+%d/%m/%Y %H:%M:%S')}"
    RAW_STATUS="${RAW_STATUS:-N/D}"
    CHARGE="${CHARGE:-100}"
    CHARGE_INT=$(to_int "$CHARGE")
    RUNTIME="${RUNTIME:-0}"
    RUNTIME_INT=$(to_int "$RUNTIME")
    RUNTIME_MIN="${RUNTIME_MIN:-$((RUNTIME_INT / 60))}"
    VOLTAGE="${VOLTAGE:-0}"
    LOAD="${LOAD:-0}"
    DURATION_MIN="${DURATION_MIN:-0}"
    DURATION_SEC="${DURATION_SEC:-0}"
    DURATION_SEC_INT=$(to_int "$DURATION_SEC")
    FSD_TIMESTAMP="${FSD_TIMESTAMP:-}"
    FSD_COUNT_INT=$(to_int "${FSD_COUNT:-1}")
    REALPOWER="${REALPOWER:-}"
    NOMINAL_REALPOWER="${NOMINAL_REALPOWER:-${UPS_NOMINAL_WATTS:-}}"
}

# ---------------------------------------------------------------------
# msg_resolve_display_name: Select human-readable UPS display label
# from UPS_FRIENDLY_NAME, hardware descriptors, or UPS_NAME fallback.
# Outputs:
#   Display name string to STDOUT
# ---------------------------------------------------------------------
msg_resolve_display_name() {
    if [ -n "${UPS_FRIENDLY_NAME:-}" ]; then
        printf "%s" "$UPS_FRIENDLY_NAME"
        return 0
    fi

    _mfr="${UPS_MFR:-}"
    _model="${UPS_MODEL:-}"
    if [ -n "$_mfr" ] && [ -n "$_model" ]; then
        printf "%s %s" "$_mfr" "$_model"
    elif [ -n "$_model" ]; then
        printf "%s" "$_model"
    else
        printf "UPS (%s)" "$UPS_NAME"
    fi
}

# ---------------------------------------------------------------------
# msg_format_status: Translate space-separated NUT status codes into
# localized, human-readable descriptions joined by " + ".
# Arguments:
#   $1 - Raw NUT ups.status string (e.g. "OB DISCHRG LB")
# Outputs:
#   Formatted status string to STDOUT
# ---------------------------------------------------------------------
msg_format_status() {
    _status_str="$1"
    _formatted=""

    for _word in $_status_str; do
        case "$_word" in
            OL)      _desc="${STATUS_OL:-$_word}" ;;
            OB)      _desc="${STATUS_OB:-$_word}" ;;
            CHRG)    _desc="${STATUS_CHRG:-$_word}" ;;
            DISCHRG) _desc="${STATUS_DISCHRG:-$_word}" ;;
            LB)      _desc="${STATUS_LB:-$_word}" ;;
            FSD)     _desc="${STATUS_FSD:-$_word}" ;;
            OVER)    _desc="${STATUS_OVER:-$_word}" ;;
            RB)      _desc="${STATUS_RB:-$_word}" ;;
            CAL)     _desc="${STATUS_CAL:-$_word}" ;;
            OFF)     _desc="${STATUS_OFF:-$_word}" ;;
            *)       _desc="$_word" ;;
        esac

        if [ -z "$_formatted" ]; then
            _formatted="$_desc"
        else
            _formatted="${_formatted} + ${_desc}"
        fi
    done

    printf "%s\n" "${_formatted:-$_status_str}"
}

# ---------------------------------------------------------------------
# msg_build_details_block: Format the standardized telemetry summary
# appended to every notification email.
# ---------------------------------------------------------------------
msg_build_details_block() {
    printf "%s\n- %s: %s\n- %s: %s\n- %s: %s%%\n- %s: %s %s (%s %s)\n- %s: %s%%\n- %s: %s\n- %s: %s V" \
        "$LABEL_DETAILS" \
        "$LABEL_TIMESTAMP" "$TIMESTAMP" \
        "$LABEL_STATUS" "$STATUS_DESC" \
        "$LABEL_BATTERY" "$CHARGE" \
        "$LABEL_RUNTIME" "$RUNTIME_MIN" "$UNIT_MINUTES" "$RUNTIME" "$UNIT_SECONDS" \
        "$LABEL_LOAD" "$LOAD" \
        "$LABEL_POWER" "$POWER_DISPLAY" \
        "$LABEL_VOLTAGE" "$VOLTAGE"
}

# ---------------------------------------------------------------------
# msg_compose_fsd_recovery_body: Assemble the post-FSD power recovery
# body, appending optional FSD timestamp, outage duration, consecutive
# shutdown cycle count, and low-charge deficit warning.
# ---------------------------------------------------------------------
msg_compose_fsd_recovery_body() {
    MSG="$MSG_FSD_POWER_RESTORED"

    if [ -n "$FSD_TIMESTAMP" ]; then
        _fsd_time_info=$(printf "$LABEL_FSD_TIME" "$FSD_TIMESTAMP")
        MSG="${MSG}
${_fsd_time_info}"
    fi

    if [ "$DURATION_SEC_INT" -gt 0 ]; then
        _duration_info=$(printf "$LABEL_OUTAGE_DURATION" "$DURATION_MIN" "$DURATION_SEC")
        MSG="${MSG}
${_duration_info}"
    else
        MSG="${MSG}
${LABEL_OUTAGE_DURATION_UNKNOWN}"
    fi

    if [ "$FSD_COUNT_INT" -gt 1 ]; then
        _cycles_info=$(printf "$LABEL_FSD_CYCLES" "$FSD_COUNT_INT")
        MSG="${MSG}
${_cycles_info}"
    fi

    if [ "$CHARGE_INT" -lt 50 ]; then
        _deficit_warn=$(printf "$MSG_RECHARGE_DEFICIT_WARN" "$CHARGE")
        MSG="${MSG}
${_deficit_warn}"
    fi
}

# ---------------------------------------------------------------------
# msg_compose_event: Populate SUBJECT and MSG for a given event type.
# Arguments:
#   $1 - Event identifier
# ---------------------------------------------------------------------
msg_compose_event() {
    _event="$1"

    case "$_event" in
        blackout)
            SUBJECT=$(printf "$SUBJECT_BLACKOUT" "$UPS_DISPLAY")
            MSG="$MSG_BLACKOUT"
            ;;
        power_restored)
            SUBJECT=$(printf "$SUBJECT_POWER_RESTORED" "$UPS_DISPLAY")
            _duration_info=$(printf "$LABEL_OUTAGE_DURATION" "$DURATION_MIN" "$DURATION_SEC")
            MSG="${MSG_POWER_RESTORED}
${_duration_info}"
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
        fsd_power_restored)
            SUBJECT=$(printf "$SUBJECT_FSD_POWER_RESTORED" "$UPS_DISPLAY")
            msg_compose_fsd_recovery_body
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
}

# ---------------------------------------------------------------------
# main: Load dictionary, hydrate telemetry, and emit RFC-822 message.
# ---------------------------------------------------------------------
main() {
    _event_type="${1:-test}"
    ALERT_LANG="${ALERT_LANG:-en}"
    UPS_NAME=$(detect_ups_name "${UPS_NAME:-}")
    UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"

    _alerts_dir=$(msg_resolve_alerts_dir)
    msg_load_dictionary "$_alerts_dir" "$ALERT_LANG" || exit 1
    msg_ensure_telemetry

    UPS_DISPLAY=$(msg_resolve_display_name)
    POWER_DISPLAY=$("$SCRIPT_DIR/calculate_power.sh" \
        "$RAW_STATUS" "$LOAD" "$REALPOWER" "$NOMINAL_REALPOWER" \
        "${UNIT_WATTS:-W}" "${LABEL_POWER_NOMINAL:-}")
    STATUS_DESC=$(msg_format_status "$RAW_STATUS")

    msg_compose_event "$_event_type"
    DETAILS=$(msg_build_details_block)

    printf "Subject: %s\n\n%s\n\n%s\n" "$SUBJECT" "$MSG" "$DETAILS"
}

main "$@"
