#!/bin/bash
# =====================================================================
# UNIT TESTS: Container Bootstrap Library (tests/test_bootstrap.sh)
# =====================================================================

BOOT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$BOOT_TMP_DIR"' EXIT

# Run each bootstrap test in a subshell to isolate environment overrides
(
    export NUT_RUN_DIR="$BOOT_TMP_DIR/run"
    export NUT_STATE_DIR="$BOOT_TMP_DIR/state"
    export NUT_CONFIG_MOUNT_DIR="$BOOT_TMP_DIR/config-mount"
    export NUT_ETC_DIR="$BOOT_TMP_DIR/etc-nut"
    export NUT_CERTS_DIR="$BOOT_TMP_DIR/etc-nut/certs"
    export NUT_SECRETS_DIR="$BOOT_TMP_DIR/secrets"
    export NUT_USB_BUS_DIR="$BOOT_TMP_DIR/usb"
    export MSMTP_CONF_FILE="$BOOT_TMP_DIR/msmtprc"
    export NOTIFICATION_EMAIL_FILE="$BOOT_TMP_DIR/notification_email"
    export ALERTS_DIR="$PROJECT_ROOT/image/alerts"
    export SCRIPTS_DIR="$PROJECT_ROOT/image/scripts"

    mkdir -p "$NUT_CONFIG_MOUNT_DIR" "$NUT_SECRETS_DIR" "$NUT_USB_BUS_DIR"
    cat <<'EOF' > "$NUT_CONFIG_MOUNT_DIR/ups.conf"
[ups]
    driver = usbhid-ups
    port = auto
EOF
    printf "primary_pass_123\n" > "$NUT_SECRETS_DIR/nut_password"
    printf "secondary_pass_456\n" > "$NUT_SECRETS_DIR/nut_secondary_password"
    printf "smtp_secret_789\n" > "$NUT_SECRETS_DIR/smtp_password"

    export API_USER="upsmon_admin"
    export SECONDARY_USER="upsmon_ro"
    export NOTIFICATION_EMAIL="ops@example.com"
    export ALERT_LANG="unknown_lang"
    export SMTP_PROVIDER="custom"
    export SMTP_HOST="smtp.example.com"
    export SMTP_PORT="587"
    export SMTP_TLS="on"
    export SMTP_STARTTLS="on"
    export SMTP_AUTH="on"
    export SMTP_USER="alerts@example.com"

    . "$PROJECT_ROOT/image/scripts/lib/bootstrap.sh"

    bootstrap_init_runtime_dirs >/dev/null
    bootstrap_load_nut_configs >/dev/null
    bootstrap_load_secrets >/dev/null
    bootstrap_validate_assets >/dev/null
    bootstrap_configure_smtp >/dev/null
    bootstrap_generate_upsd_users >/dev/null

    printf "%s\n" "$ALERT_LANG" > "$BOOT_TMP_DIR/resolved_lang.txt"
)

# 1. Config loading & automatic default generation
assert_file_exists "$BOOT_TMP_DIR/etc-nut/ups.conf" "bootstrap_load_nut_configs copies ups.conf"
assert_file_exists "$BOOT_TMP_DIR/etc-nut/nut.conf" "bootstrap_load_nut_configs creates default nut.conf when missing"
assert_file_exists "$BOOT_TMP_DIR/etc-nut/upsd.conf" "bootstrap_load_nut_configs creates default upsd.conf when missing"
assert_contains "$(cat "$BOOT_TMP_DIR/etc-nut/nut.conf")" "MODE=netserver" "Default nut.conf sets MODE=netserver"
assert_contains "$(cat "$BOOT_TMP_DIR/etc-nut/upsd.conf")" "LISTEN 0.0.0.0 3493" "Default upsd.conf listens on port 3493"

# 2. Language validation fallback
assert_eq "en" "$(cat "$BOOT_TMP_DIR/resolved_lang.txt")" "bootstrap_validate_assets falls back to English for unknown ALERT_LANG"

# 3. SMTP msmtprc generation & permissions
assert_file_exists "$BOOT_TMP_DIR/msmtprc" "bootstrap_configure_smtp generates msmtprc"
assert_file_mode "$BOOT_TMP_DIR/msmtprc" "600" "Generated msmtprc has chmod 600"
msmtp_content=$(cat "$BOOT_TMP_DIR/msmtprc")
assert_contains "$msmtp_content" "host smtp.example.com" "msmtprc contains configured SMTP host"
assert_contains "$msmtp_content" "tls_starttls on" "msmtprc enables STARTTLS when configured"
assert_contains "$msmtp_content" "password smtp_secret_789" "msmtprc injects trimmed SMTP password from Docker Secret"
assert_eq "ops@example.com" "$(cat "$BOOT_TMP_DIR/notification_email")" "bootstrap_configure_smtp writes notification_email file"

# 4. Role-separated upsd.users generation
assert_file_exists "$BOOT_TMP_DIR/etc-nut/upsd.users" "bootstrap_generate_upsd_users generates upsd.users"
users_content=$(cat "$BOOT_TMP_DIR/etc-nut/upsd.users")
assert_contains "$users_content" "[upsmon_admin]" "upsd.users contains Primary user section"
assert_contains "$users_content" "upsmon primary" "Primary user assigned upsmon primary role"
assert_contains "$users_content" "[upsmon_ro]" "upsd.users contains Secondary user section"
assert_contains "$users_content" "upsmon secondary" "Secondary user assigned upsmon secondary role"
