#!/bin/bash
# =====================================================================
# SECRETS MANAGEMENT MODULE (utils/setup/secrets.sh)
# =====================================================================
# Responsibility:
#   Persist sensitive credentials into discrete files under
#   configs/secrets/ with strict Linux DAC permissions (root:root 400).
#   Passwords are never written into .env or container environment vars.
#
# Public API:
#   secrets_write_file <filename> <secret_value>
#   save_secrets
# =====================================================================

# ---------------------------------------------------------------------
# secrets_write_file: Write a single secret file without trailing
# newline and enforce strict root:root 400 permissions.
# Arguments:
#   $1 - File basename inside SECRETS_DIR
#   $2 - Secret string value
# ---------------------------------------------------------------------
secrets_write_file() {
    local filename="$1"
    local secret_val="$2"
    local target_path="${SECRETS_DIR}/${filename}"

    printf "%s" "$secret_val" > "$target_path"
    chown root:root "$target_path" 2>/dev/null || true
    chmod 400 "$target_path"
    printf "  %b✔%b Saved %b%-26s%b (chmod 400 root:root)\n" "$GREEN" "$RESET" "$BOLD" "$filename" "$RESET"
}

# ---------------------------------------------------------------------
# save_secrets: Initialize configs/secrets/ and write all three Docker
# Secret files (Primary NUT, Secondary NUT, and SMTP passwords).
# ---------------------------------------------------------------------
save_secrets() {
    print_step "5/7" "Saving Docker Secrets" "Writing credentials with Linux DAC permissions (root:root 400)"

    # Ensure secrets directory exists with traversal permissions (755)
    mkdir -p "$SECRETS_DIR"
    chmod 755 "$SECRETS_DIR"
    touch "$SECRETS_DIR/.gitkeep" 2>/dev/null || true
    chmod 644 "$SECRETS_DIR/.gitkeep" 2>/dev/null || true

    # Write secrets to disk (Docker mounts them into volatile RAM at /run/secrets)
    secrets_write_file "nut_password.txt" "${API_PASSWORD:-}"
    secrets_write_file "nut_secondary_password.txt" "${SECONDARY_PASSWORD:-}"
    secrets_write_file "smtp_password.txt" "${SMTP_PASSWORD:-}"

    # Preserve caller ownership on directory & .gitkeep when invoked via sudo
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER" "$SECRETS_DIR" "$SECRETS_DIR/.gitkeep" 2>/dev/null || true
    fi
}
