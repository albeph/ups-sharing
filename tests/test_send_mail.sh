#!/bin/bash
# =====================================================================
# UNIT TESTS: send_mail.sh (tests/test_send_mail.sh)
# =====================================================================

SEND_SCRIPT="$PROJECT_ROOT/image/scripts/send_mail.sh"

# 1. Simulation mode when /etc/msmtprc is absent
sim_out=$(printf "Subject: [UPS] Test Alert\n\nBody line 1\nBody line 2\n" | "$SEND_SCRIPT" "admin@example.com")
assert_contains "$sim_out" "[SIMULATION]" "Runs in simulation mode when msmtprc is not present"
assert_contains "$sim_out" "Recipient: admin@example.com" "Extracts recipient argument"
assert_contains "$sim_out" "Subject: [UPS] Test Alert" "Parses Subject header from STDIN"
assert_contains "$sim_out" "Body line 1" "Preserves message body from STDIN"

# 2. Fallback subject when Subject: prefix is missing
fallback_out=$(printf "Plain body without header\n" | "$SEND_SCRIPT" "admin@example.com")
assert_contains "$fallback_out" "Subject: [UPS Alert]" "Assigns default subject when Subject header is missing"
assert_contains "$fallback_out" "Plain body without header" "Preserves first line in body when no Subject header"
