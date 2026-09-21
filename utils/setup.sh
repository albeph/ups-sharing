#!/bin/bash
set -e

# =====================================================================
# NUT SERVER SETUP WIZARD (utils/setup.sh)
# =====================================================================
# Purpose:
#   Modular interactive CLI wizard to configure the entire NUT Docker
#   environment with Docker Secrets, hardware auto-discovery, universal
#   SMTP provider selection, and driver synchronization.
#
# Modules (utils/setup/):
#   - ui.sh: ANSI terminal controls & arrow-key interactive menus
#   - hardware.sh: USB UPS hardware detection and identifier mapping
#   - localization.sh: Alert language selection & friendly labels
#   - nut_client.sh: Client credentials for external integrations
#   - smtp.sh: Multi-provider SMTP configuration & credentials
#   - secrets.sh: Secure credential storage with root:root 400
#   - env_generator.sh: Generation of configs/.env and configs/ups.conf
#
# Usage:
#   sudo ./utils/setup.sh
# =====================================================================

# 1. Enforce root privileges for Docker Secrets file DAC permissions
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Error: This script must be run with root privileges."
    echo "   Please run: sudo $0"
    exit 1
fi

# 2. Resolve absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$BASE_DIR/image"
CONFIGS_DIR="$BASE_DIR/configs"
ENV_FILE="$CONFIGS_DIR/.env"
SECRETS_DIR="$CONFIGS_DIR/secrets"
ALERTS_DIR="$IMAGE_DIR/alerts"
UPS_CONF_FILE="$CONFIGS_DIR/ups.conf"
MODULES_DIR="$SCRIPT_DIR/setup"

# 3. Source modular components
source "$MODULES_DIR/ui.sh"
source "$MODULES_DIR/hardware.sh"
source "$MODULES_DIR/localization.sh"
source "$MODULES_DIR/nut_client.sh"
source "$MODULES_DIR/smtp.sh"
source "$MODULES_DIR/secrets.sh"
source "$MODULES_DIR/env_generator.sh"

# 4. Display Welcome Header
echo -e "${CYAN}${BOLD}=====================================================================${RESET}"
echo -e "${CYAN}${BOLD}     ⚡ NUT SERVER CONFIGURATION WIZARD (Network UPS Tools) ⚡     ${RESET}"
echo -e "${CYAN}${BOLD}=====================================================================${RESET}"
echo "This wizard will configure your UPS hardware, client credentials,"
echo "and email notifications with secure Docker Secrets."
echo ""

# 5. Run modular configuration steps
detect_ups_hardware
configure_localization
configure_nut_client
configure_smtp_provider
save_secrets
generate_env_file
generate_ups_conf

# 6. Display Setup Summary & Next Steps
echo -e "${GREEN}${BOLD}=====================================================================${RESET}"
echo -e "${GREEN}${BOLD}🎉 Setup complete! Configuration successfully synchronized:${RESET}"
echo -e "   - Passwords (Docker Secrets): ${BOLD}$SECRETS_DIR/${RESET}"
echo -e "     * nut_password.txt   (root:root 400)"
echo -e "     * smtp_password.txt  (root:root 400)"
echo -e "   - Non-sensitive variables:    ${BOLD}$ENV_FILE${RESET}"
echo -e "   - Driver configuration:       ${BOLD}$UPS_CONF_FILE${RESET} ([$UPS_NAME])"
echo -e "${GREEN}${BOLD}=====================================================================${RESET}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Start or restart the NUT server:"
echo -e "     ${CYAN}docker compose up -d --build${RESET}"
echo ""
echo "  2. Test email alert notifications:"
echo -e "     ${CYAN}./utils/test_email.sh${RESET}"
echo ""
echo "  3. Query live UPS metrics:"
echo -e "     ${CYAN}docker compose exec nut-server upsc $UPS_NAME@localhost${RESET}"
echo -e "${GREEN}${BOLD}=====================================================================${RESET}"
