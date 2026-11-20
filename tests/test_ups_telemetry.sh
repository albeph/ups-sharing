#!/bin/bash
# =====================================================================
# UNIT TESTS: ups_telemetry.sh (tests/test_ups_telemetry.sh)
# =====================================================================

. "$PROJECT_ROOT/image/scripts/ups_telemetry.sh"

# 1. Test to_int conversion with decimals and edge cases
assert_eq "70" "$(to_int "70.0")" "to_int strips .0 decimal"
assert_eq "69" "$(to_int "69.5")" "to_int strips .5 decimal"
assert_eq "1200" "$(to_int "1200.85")" "to_int strips multi-digit decimal"
assert_eq "0" "$(to_int "")" "to_int returns 0 on empty input"

# 2. Test parse_upsc_snapshot with decimal values from UPS
MOCK_UPSC="battery.charge: 68.5
battery.runtime: 1800.5
input.voltage: 230.4
ups.load: 12.5
ups.mfr: Generic Manufacturer
ups.model: Generic USB UPS 1000
ups.realpower.nominal: 600
ups.status: OB DISCHRG"

parse_upsc_snapshot "$MOCK_UPSC"
assert_eq "OB DISCHRG" "$RAW_STATUS" "Snapshot parses ups.status"
assert_eq "68.5" "$CHARGE" "Snapshot preserves raw CHARGE string"
assert_eq "68" "$CHARGE_INT" "Snapshot computes integer CHARGE_INT safely"
assert_eq "1800" "$RUNTIME_INT" "Snapshot computes integer RUNTIME_INT safely"
assert_eq "30" "$RUNTIME_MIN" "Snapshot computes RUNTIME_MIN without decimal crash"
assert_eq "12" "$LOAD_INT" "Snapshot computes integer LOAD_INT safely"
assert_eq "230.4" "$VOLTAGE" "Snapshot parses input.voltage"
assert_eq "600" "$NOMINAL_REALPOWER" "Snapshot parses ups.realpower.nominal"
assert_eq "Generic Manufacturer" "$UPS_MFR" "Snapshot parses ups.mfr"
assert_eq "Generic USB UPS 1000" "$UPS_MODEL" "Snapshot parses ups.model"

# 3. Test is_voltage_stale (Regression test for inverted voltage on OB/OL transitions)
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if is_voltage_stale "OB DISCHRG" "230.0"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} Detects 230.0 V during OB (blackout) as stale cached reading"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Failed to detect 230.0 V during OB as stale"
fi

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if ! is_voltage_stale "OB DISCHRG" "0.0"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} Accepts 0.0 V during OB (blackout) as valid fresh reading"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Incorrectly marked 0.0 V during OB as stale"
fi

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if is_voltage_stale "OL CHRG" "0.0"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} Detects 0.0 V during OL (mains restored) as stale cached reading"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Failed to detect 0.0 V during OL as stale"
fi

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if ! is_voltage_stale "OL CHRG" "230.0"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} Accepts 230.0 V during OL (mains restored) as valid fresh reading"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Incorrectly marked 230.0 V during OL as stale"
fi

# 4. Test detect_ups_name from custom ups.conf file
TMP_UPS_CONF=$(mktemp)
printf "[custom_ups_unit]\n    driver = usbhid-ups\n" > "$TMP_UPS_CONF"
detected=$(UPS_NAME="" detect_ups_name "" "$TMP_UPS_CONF")
rm -f "$TMP_UPS_CONF"
assert_eq "custom_ups_unit" "$detected" "detect_ups_name extracts section name from ups.conf"

# 5. Test resolve_recipient fallback chain
TMP_EMAIL_FILE=$(mktemp)
printf "ops@company.org\n" > "$TMP_EMAIL_FILE"
resolved=$(NOTIFICATION_EMAIL="" resolve_recipient "" "$TMP_EMAIL_FILE" "/nonexistent")
rm -f "$TMP_EMAIL_FILE"
assert_eq "ops@company.org" "$resolved" "resolve_recipient reads from notification_email file"

# 6. Test on-demand manual poll refresh on power transition (OB with stale 230.0V -> refreshed 0.0V)
RAW_STATUS="OB DISCHRG"
VOLTAGE="230.0"
TRANSITION_RETRY_MAX=2
TRANSITION_RETRY_DELAY=0
upsc() {
    printf "ups.status: OB DISCHRG\nbattery.charge: 99\nbattery.runtime: 3500\ninput.voltage: 0.0\nups.load: 6\nups.realpower.nominal: 600\n"
}
refresh_telemetry_on_transition "ups"
unset -f upsc
assert_eq "0.0" "$VOLTAGE" "refresh_telemetry_on_transition updates stale 230.0V to 0.0V on blackout"

# 7. Test apply_ups_conf_overrides (manual override via .env or ups.conf)
TMP_OVERRIDE_CONF=$(mktemp)
cat <<EOF > "$TMP_OVERRIDE_CONF"
[ups]
    driver = usbhid-ups
    port = auto
    override.battery.charge.low = 30
    override.battery.runtime.low = 300
EOF
apply_ups_conf_overrides "$TMP_OVERRIDE_CONF" "45" "600" "90" "100"
override_content=$(cat "$TMP_OVERRIDE_CONF")
rm -f "$TMP_OVERRIDE_CONF"
assert_contains "$override_content" "ignorelb" "apply_ups_conf_overrides ensures ignorelb is present"
assert_contains "$override_content" "override.battery.charge.low = 45" "apply_ups_conf_overrides updates custom charge.low"
assert_contains "$override_content" "override.battery.runtime.low = 600" "apply_ups_conf_overrides updates custom runtime.low"
assert_contains "$override_content" "offdelay = 90" "apply_ups_conf_overrides sets custom offdelay"
assert_contains "$override_content" "ondelay = 100" "apply_ups_conf_overrides sets custom ondelay"
