#!/bin/bash
# =====================================================================
# LOCALIZATION & LABELS MODULE (utils/setup/localization.sh)
# =====================================================================
# Responsibility:
#   Discover available alert localization dictionaries (*.lang), allow
#   interactive arrow-key language selection, detect/prompt the host
#   IANA timezone, and prompt for a friendly UPS display label.
#
# Public API:
#   localization_discover_languages
#   localization_detect_host_timezone [timezone_file] [localtime_link]
#   configure_localization
# =====================================================================

# ---------------------------------------------------------------------
# localization_discover_languages: Populate LANG_CODES and LANG_LABELS
# arrays from available *.lang dictionaries in ALERTS_DIR.
# ---------------------------------------------------------------------
localization_discover_languages() {
    LANG_CODES=()
    LANG_LABELS=()

    # Place built-in languages first for convenience if present
    if [ -f "$ALERTS_DIR/en.lang" ]; then
        LANG_CODES+=("en")
        LANG_LABELS+=("English (en)")
    fi
    if [ -f "$ALERTS_DIR/it.lang" ]; then
        LANG_CODES+=("it")
        LANG_LABELS+=("Italiano (it)")
    fi

    # Append any additional custom .lang dictionaries
    local lang_file code
    for lang_file in "$ALERTS_DIR"/*.lang; do
        if [ -f "$lang_file" ]; then
            code=$(basename "$lang_file" .lang)
            if [ "$code" != "en" ] && [ "$code" != "it" ]; then
                LANG_CODES+=("$code")
                LANG_LABELS+=("${code} (${code})")
            fi
        fi
    done

    # Fallback to English if no dictionary files were discovered
    if [ ${#LANG_CODES[@]} -eq 0 ]; then
        LANG_CODES=("en")
        LANG_LABELS=("English (en)")
    fi
}

# ---------------------------------------------------------------------
# localization_detect_host_timezone: Detect the host's configured IANA
# timezone (e.g. "UTC", "Europe/London", "America/New_York") using
# /etc/timezone, /etc/localtime symlink, or timedatectl, falling back
# to UTC when unavailable.
# Arguments:
#   $1 - Optional override path for /etc/timezone (for unit testing)
#   $2 - Optional override path for /etc/localtime (for unit testing)
# Outputs:
#   IANA timezone string to STDOUT
# ---------------------------------------------------------------------
localization_detect_host_timezone() {
    local tz_file="${1:-/etc/timezone}"
    local localtime_path="${2:-/etc/localtime}"
    local detected=""

    # 1. Read Debian/Ubuntu /etc/timezone if present
    if [ -f "$tz_file" ]; then
        detected=$(tr -d ' \r\n' < "$tz_file" 2>/dev/null || true)
    fi

    # 2. Resolve /etc/localtime symlink pointing into .../zoneinfo/<Region/City>
    if [ -z "$detected" ] && [ -L "$localtime_path" ]; then
        local target
        target=$(readlink -f "$localtime_path" 2>/dev/null || readlink "$localtime_path" 2>/dev/null || true)
        case "$target" in
            */zoneinfo/*)
                detected="${target#*/zoneinfo/}"
                ;;
        esac
    fi

    # 3. Query systemd timedatectl when running on a standard host
    if [ -z "$detected" ] && [ "$tz_file" = "/etc/timezone" ] && command -v timedatectl >/dev/null 2>&1; then
        detected=$(timedatectl show -p Timezone --value 2>/dev/null | tr -d ' \r\n' || true)
    fi

    printf "%s" "${detected:-${TZ:-UTC}}"
}

# ---------------------------------------------------------------------
# configure_localization: Interactive wizard step for alert language,
# container timezone, and friendly UPS display name.
# Populates: ALERT_LANG, CONTAINER_TZ, UPS_FRIENDLY_NAME
# ---------------------------------------------------------------------
configure_localization() {
    print_step "2/7" "Localization & Display Labels" "Alert language, timezone, and friendly naming"

    localization_discover_languages

    local selected_lang_idx=0
    menu_select "Select email notifications language (use ↑/↓ and Enter):" selected_lang_idx "${LANG_LABELS[@]}"
    ALERT_LANG="${LANG_CODES[selected_lang_idx]}"

    local detected_tz
    detected_tz=$(localization_detect_host_timezone)
    print_info "Timezone controls timestamps displayed in container logs and email alerts."
    prompt_text "Container timezone (IANA, e.g. UTC, Europe/London, America/New_York)" CONTAINER_TZ "$detected_tz"

    prompt_text "Friendly name for email notifications (e.g. Home UPS)" UPS_FRIENDLY_NAME "Home UPS"
}
