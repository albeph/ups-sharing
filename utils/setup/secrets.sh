#!/bin/bash
# =====================================================================
# SECRETS MANAGEMENT MODULE (utils/setup/secrets.sh)
# Securely stores authentication credentials in discrete files under
# configs/secrets/ with strict Linux DAC permissions (root:root 400).
# Never writes passwords into .env files or container environment.
# =====================================================================

save_secrets() {
    echo -e "${BOLD}--- 5. Saving Docker Secrets ---${RESET}"

    # Ensure secrets directory exists with traversal permissions (755)
    mkdir -p "$SECRETS_DIR"
    chmod 755 "$SECRETS_DIR"
    touch "$SECRETS_DIR/.gitkeep" 2>/dev/null || true
    chmod 644 "$SECRETS_DIR/.gitkeep" 2>/dev/null || true

    # Write secrets to disk (Docker Secrets mount them into volatile RAM /run/secrets)
    printf "%s" "$API_PASSWORD" > "$SECRETS_DIR/nut_password.txt"
    printf "%s" "$SMTP_PASSWORD" > "$SECRETS_DIR/smtp_password.txt"

    # Enforce strict file security (read-only for root, completely inaccessible to unprivileged users)
    chown root:root "$SECRETS_DIR/nut_password.txt" "$SECRETS_DIR/smtp_password.txt" 2>/dev/null || true
    chmod 400 "$SECRETS_DIR/nut_password.txt" "$SECRETS_DIR/smtp_password.txt"

    # If run via sudo, ensure caller owns directory and .gitkeep to prevent git permission issues
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER" "$SECRETS_DIR" "$SECRETS_DIR/.gitkeep" 2>/dev/null || true
    fi

    echo -e "  ${GREEN}✔${RESET} Saved ${BOLD}nut_password.txt${RESET} (chmod 400 root:root)"
    echo -e "  ${GREEN}✔${RESET} Saved ${BOLD}smtp_password.txt${RESET} (chmod 400 root:root)"
    echo ""
}
