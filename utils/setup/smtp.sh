#!/bin/bash
# =====================================================================
# SMTP PROVIDER CONFIGURATION MODULE (utils/setup/smtp.sh)
# Discovers available SMTP templates in image/smtp_configs/, provides
# interactive provider selection (Gmail, Outlook, Local, Custom), and
# collects authentication credentials.
# =====================================================================

configure_smtp_provider() {
    echo -e "${BOLD}--- 4. Email Alerts & SMTP Provider ---${RESET}"
    echo "Configure an outgoing SMTP service to receive blackout and alert emails."

    local -a conf_files=()
    local -a conf_ids=()
    local -a conf_labels=()

    # Discover *.conf files in image/smtp_configs/ (excluding .example)
    for conf in "$IMAGE_DIR"/smtp_configs/*.conf; do
        if [ -f "$conf" ]; then
            local id
            id=$(basename "$conf" .conf)
            local name=""
            name=$(grep -E '^PROVIDER_NAME=' "$conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || true)
            [ -z "$name" ] && name="$id"
            conf_files+=("$conf")
            conf_ids+=("$id")
            conf_labels+=("$name")
        fi
    done

    # Add interactive options for custom configuration and disabling alerts
    local custom_idx=${#conf_labels[@]}
    conf_ids+=("custom")
    conf_labels+=("Custom SMTP Provider (manual parameters)")

    local disable_idx=${#conf_labels[@]}
    conf_ids+=("none")
    conf_labels+=("Disable email alerts (no SMTP)")

    local selected_smtp_idx=0
    menu_select "Select SMTP provider (use ↑/↓ and Enter):" selected_smtp_idx "${conf_labels[@]}"

    local chosen_id="${conf_ids[selected_smtp_idx]}"

    if [ "$chosen_id" = "none" ]; then
        echo -e "  ${YELLOW}ℹ️  Email alerts will be disabled.${RESET}"
        SMTP_PROVIDER="none"
        SMTP_HOST=""
        SMTP_PORT=""
        SMTP_TLS="off"
        SMTP_STARTTLS="off"
        SMTP_AUTH="off"
        SMTP_USER=""
        SMTP_PASSWORD=""
        NOTIFICATION_EMAIL=""
        echo ""
        return 0
    fi

    if [ "$chosen_id" = "custom" ]; then
        SMTP_PROVIDER="custom"
        prompt_text "SMTP Host (e.g. mail.domain.com)" SMTP_HOST "mail.domain.com"
        prompt_text "SMTP Port [587]" SMTP_PORT "587"
        prompt_text "TLS (on/off) [on]" SMTP_TLS "on"
        prompt_text "STARTTLS (on/off) [on]" SMTP_STARTTLS "on"
        prompt_text "Authentication (on/off) [on]" SMTP_AUTH "on"

        prompt_text "Sender email address (from)" SMTP_USER ""
        if [ "$SMTP_AUTH" = "on" ]; then
            prompt_secret "SMTP Password" SMTP_PASSWORD ""
            SMTP_PASSWORD="$(echo "$SMTP_PASSWORD" | tr -d ' ')"
        else
            SMTP_PASSWORD=""
        fi
        prompt_text "Recipient email for notifications" NOTIFICATION_EMAIL "$SMTP_USER"
        echo ""
        return 0
    fi

    # Read selected template
    local chosen_conf="${conf_files[selected_smtp_idx]}"
    SMTP_PROVIDER="$chosen_id"

    # Source parameters safely
    SMTP_HOST=$(grep -E '^SMTP_HOST=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "")
    SMTP_PORT=$(grep -E '^SMTP_PORT=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "587")
    SMTP_TLS=$(grep -E '^SMTP_TLS=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "on")
    SMTP_STARTTLS=$(grep -E '^SMTP_STARTTLS=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "on")
    SMTP_AUTH=$(grep -E '^SMTP_AUTH=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "on")
    local req_pw
    req_pw=$(grep -E '^REQUIRES_PASSWORD=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "yes")
    local pw_help
    pw_help=$(grep -E '^PASSWORD_HELP=' "$chosen_conf" | head -n1 | cut -d'=' -f2- | tr -d '"' || echo "Enter password: ")

    prompt_text "Sender email address / username" SMTP_USER ""

    if [ "$req_pw" = "yes" ]; then
        if [ -n "$pw_help" ]; then
            echo -e "  ${DIM}ℹ️  $pw_help${RESET}"
        fi
        prompt_secret "Password / App Password for $SMTP_USER" SMTP_PASSWORD ""
        SMTP_PASSWORD="$(echo "$SMTP_PASSWORD" | tr -d ' ')"
    else
        SMTP_PASSWORD=""
    fi

    prompt_text "Recipient email for notifications" NOTIFICATION_EMAIL "$SMTP_USER"
    echo ""
}
