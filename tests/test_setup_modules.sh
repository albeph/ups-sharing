#!/bin/bash
# =====================================================================
# UNIT & INTEGRATION TESTS: Setup Modules & Config Generation
# (tests/test_setup_modules.sh)
# =====================================================================

TMP_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

# Load UI, Hardware, Localization, SMTP, Secrets, and Generator modules in isolated sandbox
source "$PROJECT_ROOT/utils/setup/ui.sh" >/dev/null 2>&1
source "$PROJECT_ROOT/utils/setup/hardware.sh"
source "$PROJECT_ROOT/utils/setup/localization.sh"
source "$PROJECT_ROOT/utils/setup/smtp.sh"
source "$PROJECT_ROOT/utils/setup/secrets.sh"
source "$PROJECT_ROOT/utils/setup/env_generator.sh"

SECRETS_DIR="$TMP_TEST_DIR/secrets"
ENV_FILE="$TMP_TEST_DIR/.env"
UPS_CONF_FILE="$TMP_TEST_DIR/ups.conf"

# Configure mock variables representing wizard selections
UPS_NAME="ups"
VENDOR_ID="0001"
ALERT_LANG="it"
CONTAINER_TZ="Europe/London"
UPS_FRIENDLY_NAME="Server Room UPS"
UPS_NOMINAL_WATTS="600"
BATTERY_CHARGE_LOW="30"
BATTERY_RUNTIME_LOW="300"
UPS_OFFDELAY="60"
UPS_ONDELAY="70"
API_USER="upsmon_primary"
API_PASSWORD="primary_secret_pw"
SECONDARY_USER="upsmon_client"
SECONDARY_PASSWORD="secondary_secret_pw"
SMTP_PROVIDER="gmail"
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_TLS="on"
SMTP_STARTTLS="on"
SMTP_AUTH="on"
SMTP_USER="alerts@gmail.com"
SMTP_PASSWORD="smtp_secret_pw"
NOTIFICATION_EMAIL="admin@domain.com"

# 1. Test secrets generation and permissions
save_secrets >/dev/null
assert_file_exists "$SECRETS_DIR/nut_password.txt" "Primary NUT password secret file created"
assert_file_exists "$SECRETS_DIR/nut_secondary_password.txt" "Secondary NUT password secret file created"
assert_file_exists "$SECRETS_DIR/smtp_password.txt" "SMTP password secret file created"
assert_file_mode "$SECRETS_DIR/nut_password.txt" "400" "Primary secret has chmod 400"
assert_file_mode "$SECRETS_DIR/nut_secondary_password.txt" "400" "Secondary secret has chmod 400"
assert_eq "primary_secret_pw" "$(cat "$SECRETS_DIR/nut_password.txt")" "Primary password content matches"
assert_eq "secondary_secret_pw" "$(cat "$SECRETS_DIR/nut_secondary_password.txt")" "Secondary password content matches"

# 2. Test .env generation (no passwords leaked, role users & thresholds present)
generate_env_file >/dev/null
assert_file_exists "$ENV_FILE" ".env file generated"
assert_file_mode "$ENV_FILE" "600" ".env file has chmod 600"
env_content=$(cat "$ENV_FILE")
assert_contains "$env_content" "TZ=Europe/London" ".env contains configured container timezone"
assert_contains "$env_content" "UPS_NOMINAL_WATTS=600" ".env contains optional UPS_NOMINAL_WATTS fallback when set"
assert_contains "$env_content" "API_USER=upsmon_primary" ".env contains Primary user"
assert_contains "$env_content" "SECONDARY_USER=upsmon_client" ".env contains Secondary user"
assert_contains "$env_content" "BATTERY_CHARGE_LOW=30" ".env contains low battery charge threshold"
assert_contains "$env_content" "BATTERY_RUNTIME_LOW=300" ".env contains low battery runtime threshold"

# Verify zero password leakage in .env
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [[ "$env_content" != *"primary_secret_pw"* ]] && [[ "$env_content" != *"secondary_secret_pw"* ]] && [[ "$env_content" != *"smtp_secret_pw"* ]]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} Zero plaintext passwords leaked into .env"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Plaintext password leaked into .env!"
fi

# 3. Test ups.conf generation with Low Battery safety overrides
generate_ups_conf >/dev/null
assert_file_exists "$UPS_CONF_FILE" "ups.conf file generated"
ups_conf_content=$(cat "$UPS_CONF_FILE")
assert_contains "$ups_conf_content" "[ups]" "ups.conf contains UPS section header"
assert_contains "$ups_conf_content" "vendorid = \"0001\"" "ups.conf contains vendorid"
assert_contains "$ups_conf_content" "ignorelb" "ups.conf enables ignorelb so custom LB thresholds are enforced"
assert_contains "$ups_conf_content" "override.battery.charge.low = 30" "ups.conf contains low charge override"
assert_contains "$ups_conf_content" "override.battery.runtime.low = 300" "ups.conf contains low runtime override"
assert_contains "$ups_conf_content" "offdelay = 60" "ups.conf contains offdelay for delayed UPS power-off"
assert_contains "$ups_conf_content" "ondelay = 70" "ups.conf contains ondelay > offdelay for auto-restart"

# 4. Test UI prompt_text / prompt_secret against shell injection (no eval expansion)
SPECIAL_INPUT='my$pass`id`"quote'
prompt_text "Test label" SAFE_OUT "" <<< "$SPECIAL_INPUT" >/dev/null
assert_eq "$SPECIAL_INPUT" "$SAFE_OUT" "prompt_text preserves special shell chars without eval expansion"

# 5. Test ensure_base_nut_configs restores missing nut.conf and upsd.conf without overwriting custom ones
CONFIGS_DIR="$TMP_TEST_DIR"
ensure_base_nut_configs >/dev/null
assert_file_exists "$TMP_TEST_DIR/nut.conf" "ensure_base_nut_configs restores missing nut.conf"
assert_file_exists "$TMP_TEST_DIR/upsd.conf" "ensure_base_nut_configs restores missing upsd.conf"
assert_contains "$(cat "$TMP_TEST_DIR/nut.conf")" "MODE=netserver" "Restored nut.conf contains MODE=netserver"
assert_contains "$(cat "$TMP_TEST_DIR/upsd.conf")" "LISTEN 0.0.0.0 3493" "Restored upsd.conf contains LISTEN directive"

# Verify custom upsd.conf is preserved
printf "LISTEN 127.0.0.1 3493\n" > "$TMP_TEST_DIR/upsd.conf"
ensure_base_nut_configs >/dev/null
assert_contains "$(cat "$TMP_TEST_DIR/upsd.conf")" "LISTEN 127.0.0.1 3493" "ensure_base_nut_configs preserves existing custom upsd.conf"

# 6. Test utils/host_shutdown.sh in --dry-run mode with sandboxed configs
DRY_BASE="$TMP_TEST_DIR/host_shutdown_test"
mkdir -p "$DRY_BASE/configs/secrets"
cp "$ENV_FILE" "$DRY_BASE/configs/.env"
cp "$SECRETS_DIR/nut_password.txt" "$DRY_BASE/configs/secrets/nut_password.txt"
dry_out=$(UPS_SHARING_BASE_DIR="$DRY_BASE" "$PROJECT_ROOT/utils/host_shutdown.sh" --dry-run)
assert_contains "$dry_out" "[DRY-RUN] Would persist post-FSD recovery marker via container 'nut-server'" "host_shutdown.sh persists post-FSD recovery marker before shutdown"
assert_contains "$dry_out" "[DRY-RUN] Would send UPS command: 'shutdown.return' to 'ups' (user: upsmon_primary, offdelay: 60s)" "host_shutdown.sh schedules UPS delayed power-off using .env & Docker Secret"
assert_contains "$dry_out" "[DRY-RUN] Would execute: /sbin/shutdown -h +0" "host_shutdown.sh proceeds to host OS halt"

# 7. Test hardware.sh pure parsing helpers
mock_usb_line="Bus 001 Device 004: ID 0001:0002 Generic Uninterruptible Power Supply"
assert_eq "0001" "$(hardware_extract_vendor_id "$mock_usb_line")" "hardware_extract_vendor_id extracts 4-digit hex vendor ID"
assert_eq "Generic Uninterruptible Power Supply" "$(hardware_extract_label "$mock_usb_line")" "hardware_extract_label extracts clean device label"

# 8. Test smtp.sh safe template key reader
mock_smtp_conf="$TMP_TEST_DIR/mock_smtp.conf"
cat <<'EOF' > "$mock_smtp_conf"
PROVIDER_NAME="Example Mail"
SMTP_HOST="smtp.example.org"
SMTP_PORT="587"
EOF
assert_eq "smtp.example.org" "$(smtp_read_template_key "$mock_smtp_conf" "SMTP_HOST" "")" "smtp_read_template_key extracts SMTP_HOST"
assert_eq "587" "$(smtp_read_template_key "$mock_smtp_conf" "SMTP_PORT" "25")" "smtp_read_template_key extracts SMTP_PORT"
assert_eq "on" "$(smtp_read_template_key "$mock_smtp_conf" "SMTP_TLS" "on")" "smtp_read_template_key returns default when key is absent"

# 9. Test localization.sh host timezone detection helper
mock_tz_file="$TMP_TEST_DIR/timezone"
printf "America/New_York\n" > "$mock_tz_file"
assert_eq "America/New_York" "$(localization_detect_host_timezone "$mock_tz_file" "/nonexistent")" "localization_detect_host_timezone reads /etc/timezone"
assert_eq "UTC" "$(TZ="" localization_detect_host_timezone "/nonexistent" "/nonexistent")" "localization_detect_host_timezone falls back to UTC when undetected"
