#!/bin/bash
# =====================================================================
# SMTP PROVIDER CONFIGURATION MODULE (utils/setup/smtp.sh)
# =====================================================================
# Responsibility:
#   Discover available SMTP provider templates in image/smtp_configs/,
#   present an interactive selection menu (template, custom, or off),
#   and collect outgoing mail authentication credentials.
#
# Public API:
#   smtp_read_template_key <template_file> <key> [default_val]
#   smtp_discover_templates
#   configure_smtp_provider
# =====================================================================

# ---------------------------------------------------------------------
# smtp_read_template_key: Safely extract a quoted key=value entry from
# an SMTP provider template without sourcing untrusted shell code.
# Arguments:
#   $1 - Template file path
#   $2 - Key name (e.g. "SMTP_HOST")
#   $3 - Default value if key is absent (optional)
# Outputs:
#   Extracted value to STDOUT
# ---------------------------------------------------------------------
smtp_read_template_key() {
    local conf_file="$1"
    local key="$2"
    local default_val="${3:-}"
    local value=""

    if [ -f "$conf_file" ]; then
        value=$(grep -E "^${key}=" "$conf_file" | head -n1 | cut -d'=' -f2- | tr -d '"\r\n' || true)
    fi
    printf "%s" "${value:-$default_val}"
}

# ---------------------------------------------------------------------
# smtp_discover_templates: Scan image/smtp_configs/*.conf and populate
# SMTP_CONF_FILES, SMTP_CONF_IDS, and SMTP_CONF_LABELS arrays.
# ---------------------------------------------------------------------
smtp_discover_templates() {
    SMTP_CONF_FILES=()
    SMTP_CONF_IDS=()
    SMTP_CONF_LABELS=()

    local conf id name
    for conf in "$IMAGE_DIR"/smtp_configs/*.conf; do
        if [ -f "$conf" ]; then
            id=$(basename "$conf" .conf)
            name=$(smtp_read_template_key "$conf" "PROVIDER_NAME" "$id")
            SMTP_CONF_FILES+=("$conf")
            SMTP_CONF_IDS+=("$id")
            SMTP_CONF_LABELS+=("$name")
        fi
    done

    # Append interactive options for custom server or disabled alerts
    SMTP_CONF_IDS+=("custom")
    SMTP_CONF_LABELS+=("Custom SMTP Provider (manual parameters)")

    SMTP_CONF_IDS+=("none")
    SMTP_CONF_LABELS+=("Disable email alerts (no SMTP)")
}

# ---------------------------------------------------------------------
# _smtp_configure_disabled: Clear all SMTP settings when alerts are off.
# ---------------------------------------------------------------------
_smtp_configure_disabled() {
    echo -e "  ${YELLOW}ℹ️  Email alerts will be disabled.${RESET}\n"
    SMTP_PROVIDER="none"
    SMTP_HOST=""
    SMTP_PORT=""
    SMTP_TLS="off"
    SMTP_STARTTLS="off"
    SMTP_AUTH="off"
    SMTP_USER=""
    SMTP_PASSWORD=""
    NOTIFICATION_EMAIL=""
}

# ---------------------------------------------------------------------
# _smtp_configure_custom: Prompt user for manual SMTP server parameters.
# ---------------------------------------------------------------------
_smtp_configure_custom() {
    SMTP_PROVIDER="custom"
    prompt_text "SMTP Host (e.g. mail.example.com)" SMTP_HOST "mail.example.com"
    prompt_text "SMTP Port" SMTP_PORT "587"
    prompt_text "TLS (on/off)" SMTP_TLS "on"
    prompt_text "STARTTLS (on/off)" SMTP_STARTTLS "on"
    prompt_text "Authentication (on/off)" SMTP_AUTH "on"

    prompt_text "Sender email address (from)" SMTP_USER ""
    if [ "$SMTP_AUTH" = "on" ]; then
        prompt_secret "SMTP Password" SMTP_PASSWORD ""
        SMTP_PASSWORD="$(printf "%s" "$SMTP_PASSWORD" | tr -d ' ')"
    else
        SMTP_PASSWORD=""
    fi
    prompt_text "Recipient email for notifications" NOTIFICATION_EMAIL "$SMTP_USER"
}

# ---------------------------------------------------------------------
# _smtp_configure_from_template: Load provider defaults from a template
# file and collect sender/recipient credentials.
# Arguments:
#   $1 - Provider ID
#   $2 - Path to template file
# ---------------------------------------------------------------------
_smtp_configure_from_template() {
    local provider_id="$1"
    local template_file="$2"

    SMTP_PROVIDER="$provider_id"
    SMTP_HOST=$(smtp_read_template_key "$template_file" "SMTP_HOST" "")
    SMTP_PORT=$(smtp_read_template_key "$template_file" "SMTP_PORT" "587")
    SMTP_TLS=$(smtp_read_template_key "$template_file" "SMTP_TLS" "on")
    SMTP_STARTTLS=$(smtp_read_template_key "$template_file" "SMTP_STARTTLS" "on")
    SMTP_AUTH=$(smtp_read_template_key "$template_file" "SMTP_AUTH" "on")

    local req_pw pw_help
    req_pw=$(smtp_read_template_key "$template_file" "REQUIRES_PASSWORD" "yes")
    pw_help=$(smtp_read_template_key "$template_file" "PASSWORD_HELP" "Enter password: ")

    prompt_text "Sender email address / username" SMTP_USER ""

    if [ "$req_pw" = "yes" ]; then
        [ -n "$pw_help" ] && print_info "$pw_help"
        prompt_secret "Password / App Password for ${SMTP_USER}" SMTP_PASSWORD ""
        SMTP_PASSWORD="$(printf "%s" "$SMTP_PASSWORD" | tr -d ' ')"
    else
        SMTP_PASSWORD=""
    fi

    prompt_text "Recipient email for notifications" NOTIFICATION_EMAIL "$SMTP_USER"
}

# ---------------------------------------------------------------------
# configure_smtp_provider: Interactive wizard step for outgoing SMTP
# alert configuration.
# ---------------------------------------------------------------------
configure_smtp_provider() {
    print_step "4/7" "Email Alerts & SMTP Provider" "Outgoing mail service for blackout and status notifications"

    smtp_discover_templates

    local selected_smtp_idx=0
    menu_select "Select SMTP provider (use ↑/↓ and Enter):" selected_smtp_idx "${SMTP_CONF_LABELS[@]}"

    local chosen_id="${SMTP_CONF_IDS[selected_smtp_idx]}"
    case "$chosen_id" in
        none)   _smtp_configure_disabled ;;
        custom) _smtp_configure_custom ;;
        *)      _smtp_configure_from_template "$chosen_id" "${SMTP_CONF_FILES[selected_smtp_idx]}" ;;
    esac
}
