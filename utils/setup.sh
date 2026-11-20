#!/bin/bash
set -e

# =====================================================================
# NUT SERVER SETUP WIZARD ORCHESTRATOR (utils/setup.sh)
# =====================================================================
# Responsibility:
#   Orchestrate the interactive CLI setup wizard across single-responsibility
#   modules in utils/setup/ to generate configs/.env, configs/ups.conf,
#   and Linux DAC-protected Docker Secrets under configs/secrets/.
#
# Modules (utils/setup/):
#   - ui.sh:           ANSI terminal controls & interactive arrow-key menus
#   - hardware.sh:     USB HID UPS detection & Low Battery safety thresholds
#   - localization.sh: Alert language selection & friendly display name
#   - nut_client.sh:   Primary & Secondary role-based NUT credentials
#   - smtp.sh:         Multi-provider SMTP template & credential setup
#   - secrets.sh:      Secure credential writer (root:root 400)
#   - env_generator.sh: Generation of configs/.env and configs/ups.conf
#
# Usage:
#   sudo ./utils/setup.sh
# =====================================================================

# ---------------------------------------------------------------------
# setup_require_root: Enforce root execution so Docker Secrets receive
# strict root:root 400 DAC permissions.
# ---------------------------------------------------------------------
setup_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo ""
        echo "❌ Error: This script must be run with root privileges."
        echo "   Please run: sudo $0"
        echo ""
        exit 1
    fi
}

# ---------------------------------------------------------------------
# setup_init_paths: Resolve repository paths used by all wizard modules.
# ---------------------------------------------------------------------
setup_init_paths() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(dirname "$SCRIPT_DIR")"
    IMAGE_DIR="${BASE_DIR}/image"
    CONFIGS_DIR="${BASE_DIR}/configs"
    ENV_FILE="${CONFIGS_DIR}/.env"
    SECRETS_DIR="${CONFIGS_DIR}/secrets"
    ALERTS_DIR="${IMAGE_DIR}/alerts"
    UPS_CONF_FILE="${CONFIGS_DIR}/ups.conf"
    MODULES_DIR="${SCRIPT_DIR}/setup"
}

# ---------------------------------------------------------------------
# setup_load_modules: Source all modular wizard components.
# ---------------------------------------------------------------------
setup_load_modules() {
    local module
    for module in ui.sh hardware.sh localization.sh nut_client.sh smtp.sh secrets.sh env_generator.sh; do
        # shellcheck disable=SC1090
        source "${MODULES_DIR}/${module}"
    done
}

# ---------------------------------------------------------------------
# setup_print_banner: Render the initial wizard welcome header.
# ---------------------------------------------------------------------
setup_print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RESET}"
    echo -e "${CYAN}${BOLD}┃       NUT SERVER CONFIGURATION WIZARD (Network UPS Tools)   ┃${RESET}"
    echo -e "${CYAN}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RESET}"
    echo -e "  This wizard will configure your UPS hardware, client credentials,"
    echo -e "  and email notifications with secure Docker Secrets."
}

# ---------------------------------------------------------------------
# setup_print_summary: Display generated artifacts and next steps.
# ---------------------------------------------------------------------
setup_print_summary() {
    echo -e "${GREEN}${BOLD}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RESET}"
    echo -e "${GREEN}${BOLD}┃       🎉 Setup Complete! Configuration Synchronized        ┃${RESET}"
    echo -e "${GREEN}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RESET}"
    echo -e "  • Docker Secrets:      ${BOLD}${SECRETS_DIR}/${RESET} (root:root 400)"
    echo -e "  • Environment File:    ${BOLD}${ENV_FILE}${RESET} (chmod 600)"
    echo -e "  • Driver Config:       ${BOLD}${UPS_CONF_FILE}${RESET} ([${UPS_NAME}])"
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo ""
    echo -e "  1. Start or restart the NUT server:"
    echo -e "     ${CYAN}docker compose up -d --build${RESET}"
    echo ""
    echo -e "  2. Test email alert notifications:"
    echo -e "     ${CYAN}./utils/test_email.sh${RESET}"
    echo ""
    echo -e "  3. Query live UPS metrics:"
    echo -e "     ${CYAN}docker compose exec nut-server upsc ${UPS_NAME}@localhost${RESET}"
    echo ""
}

# ---------------------------------------------------------------------
# main: Execute the interactive setup wizard end to end.
# ---------------------------------------------------------------------
main() {
    setup_require_root
    setup_init_paths
    setup_load_modules
    setup_print_banner

    detect_ups_hardware
    configure_localization
    configure_nut_client
    configure_smtp_provider
    save_secrets
    generate_env_file
    generate_ups_conf
    ensure_base_nut_configs

    setup_print_summary
}

main "$@"
