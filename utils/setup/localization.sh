#!/bin/bash
# =====================================================================
# LOCALIZATION & LABELS MODULE (utils/setup/localization.sh)
# Configures email alert language using interactive arrow-key selection,
# and sets the friendly display name for notifications.
# =====================================================================

configure_localization() {
    echo -e "${BOLD}--- 2. Localization & Display Settings ---${RESET}"

    # Scan image/alerts/ to discover available language files (*.lang)
    local lang_files=("$ALERTS_DIR"/*.lang)
    local -a lang_codes=()
    local -a lang_labels=()

    # Prefer English and Italian first if present
    if [ -f "$ALERTS_DIR/en.lang" ]; then
        lang_codes+=("en")
        lang_labels+=("English (en)")
    fi
    if [ -f "$ALERTS_DIR/it.lang" ]; then
        lang_codes+=("it")
        lang_labels+=("Italiano (it)")
    fi

    # Add any other discovered language files
    for f in "${lang_files[@]}"; do
        if [ -f "$f" ]; then
            local code
            code=$(basename "$f" .lang)
            if [ "$code" != "en" ] && [ "$code" != "it" ]; then
                lang_codes+=("$code")
                lang_labels+=("$code ($code)")
            fi
        fi
    done

    # Fallback to English if none found
    if [ ${#lang_codes[@]} -eq 0 ]; then
        lang_codes=("en")
        lang_labels+=("English (en)")
    fi

    local selected_lang_idx=0
    menu_select "Select email notifications language (use ↑/↓ and Enter):" selected_lang_idx "${lang_labels[@]}"
    ALERT_LANG="${lang_codes[selected_lang_idx]}"

    # Friendly name for email notifications
    prompt_text "Friendly name for email notifications (e.g. Home UPS)" UPS_FRIENDLY_NAME "Home UPS"
    echo ""
}
