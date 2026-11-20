#!/bin/bash
# =====================================================================
# UNIT & INTEGRATION TESTS: Post-FSD Power Recovery & Anti-Overlap
# (tests/test_fsd_recovery.sh)
# =====================================================================

FSD_SCRIPT="$PROJECT_ROOT/image/scripts/fsd_recovery.sh"
NOTIFIER_SCRIPT="$PROJECT_ROOT/image/scripts/ups_notifier.sh"

FSD_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$FSD_TMP_DIR"' EXIT

# Helper to build a mock PATH directory with fake upsc & upsrw
create_mock_bin() {
    local mock_dir="$1"
    local status_file="$2"
    mkdir -p "$mock_dir"

    cat <<'EOF' > "$mock_dir/upsc"
#!/bin/sh
STATE_SEQ_FILE="${MOCK_UPSC_SEQ_FILE:-}"
STATE_IDX_FILE="${MOCK_UPSC_IDX_FILE:-}"

# Handle 'upsc ups@localhost ups.status' readiness check
if [ "$#" -ge 2 ] && [ "$2" = "ups.status" ]; then
    printf "OL CHRG\n"
    exit 0
fi

# Pop next status line from sequence file (sticking on last line)
LINE=""
if [ -f "$STATE_SEQ_FILE" ]; then
    IDX=1
    if [ -f "$STATE_IDX_FILE" ]; then
        IDX=$(cat "$STATE_IDX_FILE")
    fi
    TOTAL=$(wc -l < "$STATE_SEQ_FILE" | tr -d ' ')
    if [ "$IDX" -gt "$TOTAL" ]; then
        IDX="$TOTAL"
    fi
    LINE=$(sed -n "${IDX}p" "$STATE_SEQ_FILE")
    NEXT=$((IDX + 1))
    printf "%s\n" "$NEXT" > "$STATE_IDX_FILE"
fi

STATUS_VAL=$(printf "%s" "$LINE" | cut -d'|' -f1)
CHARGE_VAL=$(printf "%s" "$LINE" | cut -d'|' -f2)
VOLT_VAL=$(printf "%s" "$LINE" | cut -d'|' -f3)

STATUS_VAL="${STATUS_VAL:-OL CHRG}"
CHARGE_VAL="${CHARGE_VAL:-32}"
VOLT_VAL="${VOLT_VAL:-230.0}"

printf "ups.status: %s\n" "$STATUS_VAL"
printf "battery.charge: %s\n" "$CHARGE_VAL"
printf "battery.runtime: 900\n"
printf "input.voltage: %s\n" "$VOLT_VAL"
printf "ups.load: 15\n"
printf "ups.realpower.nominal: 600\n"
EOF
    chmod +x "$mock_dir/upsc"
}

# ---------------------------------------------------------------------
# 1. Idle boot (no prior FSD): daemon exits immediately, zero emails
# ---------------------------------------------------------------------
STATE_1="$FSD_TMP_DIR/state1"
status_out=$(NUT_STATE_DIR="$STATE_1" "$FSD_SCRIPT" status || true)
assert_contains "$status_out" "RECOVERY_STATE=IDLE" "Initial recovery state is IDLE when no state file exists"

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if ! NUT_STATE_DIR="$STATE_1" "$FSD_SCRIPT" is-recovery-active; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} is-recovery-active returns false when IDLE"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} is-recovery-active should return false when IDLE"
fi

NUT_STATE_DIR="$STATE_1" "$FSD_SCRIPT" daemon "admin@example.com" "ups" >/dev/null 2>&1
assert_eq "0" "$?" "daemon exits 0 immediately on normal boot without FSD marker"

# ---------------------------------------------------------------------
# 2. mark-fsd persistence & idempotency within same shutdown
# ---------------------------------------------------------------------
STATE_2="$FSD_TMP_DIR/state2"
NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" mark-fsd "28" "1700000000" >/dev/null
status_2=$(NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" status)
assert_contains "$status_2" "RECOVERY_STATE=FSD_RECORDED" "mark-fsd persists RECOVERY_STATE=FSD_RECORDED"
assert_contains "$status_2" "FSD_COUNT=1" "mark-fsd initializes FSD_COUNT=1"
assert_contains "$status_2" "FSD_CHARGE=28" "mark-fsd records battery charge at FSD"
assert_contains "$status_2" "BLACKOUT_START=1700000000" "mark-fsd records BLACKOUT_START epoch"

# Second mark-fsd during same shutdown (e.g. host_shutdown.sh backup call) must be idempotent
NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" mark-fsd "" "0" >/dev/null
status_2b=$(NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" status)
assert_contains "$status_2b" "FSD_COUNT=1" "Duplicate mark-fsd in same shutdown is idempotent (FSD_COUNT stays 1)"
assert_contains "$status_2b" "FSD_CHARGE=28" "Duplicate mark-fsd preserves previously recorded charge"
assert_contains "$status_2b" "BLACKOUT_START=1700000000" "Duplicate mark-fsd preserves BLACKOUT_START"

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if ! NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" is-recovery-active; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} is-recovery-active is false before reboot (FSD_RECORDED)"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} is-recovery-active should be false before reboot"
fi

# Activate on reboot
NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" activate
assert_eq "0" "$?" "activate transitions FSD_RECORDED to RECOVERY_PENDING"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if NUT_STATE_DIR="$STATE_2" "$FSD_SCRIPT" is-recovery-active; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} is-recovery-active returns true after activate (RECOVERY_PENDING)"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} is-recovery-active should return true after activate"
fi

# ---------------------------------------------------------------------
# 3. Network unavailable at boot: retry with backoff, clear only after success
# ---------------------------------------------------------------------
STATE_3="$FSD_TMP_DIR/state3"
MOCK_BIN_3="$FSD_TMP_DIR/mock_bin_3"
SEQ_3="$FSD_TMP_DIR/seq_3.txt"
IDX_3="$FSD_TMP_DIR/idx_3.txt"
MAIL_CNT_3="$FSD_TMP_DIR/mail_cnt_3.txt"
MAIL_OUT_3="$FSD_TMP_DIR/mail_out_3.txt"
MOCK_MAIL_3="$FSD_TMP_DIR/mock_send_mail_3.sh"

create_mock_bin "$MOCK_BIN_3" "$SEQ_3"
printf "OL CHRG|32|230.0\n" > "$SEQ_3"
printf "0\n" > "$MAIL_CNT_3"

cat <<EOF > "$MOCK_MAIL_3"
#!/bin/sh
CNT=\$(cat "$MAIL_CNT_3")
CNT=\$((CNT + 1))
printf "%s\n" "\$CNT" > "$MAIL_CNT_3"
BODY=\$(cat)
if [ "\$CNT" -lt 3 ]; then
    exit 1
fi
printf "%s\n" "\$BODY" > "$MAIL_OUT_3"
exit 0
EOF
chmod +x "$MOCK_MAIL_3"

PAST_EPOCH=$(( $(date +%s) - 600 ))
NUT_STATE_DIR="$STATE_3" "$FSD_SCRIPT" mark-fsd "28" "$PAST_EPOCH" >/dev/null

PATH="$MOCK_BIN_3:$PATH" \
MOCK_UPSC_SEQ_FILE="$SEQ_3" \
MOCK_UPSC_IDX_FILE="$IDX_3" \
NUT_STATE_DIR="$STATE_3" \
ALERT_LANG="it" \
UPS_FRIENDLY_NAME="Test UPS" \
FSD_RECOVERY_STABLE_SEC=0 \
FSD_RECOVERY_POLL_INTERVAL=0 \
FSD_RECOVERY_RETRY_INITIAL=0 \
FSD_RECOVERY_RETRY_MAX=0 \
SEND_MAIL_BIN="$MOCK_MAIL_3" \
"$FSD_SCRIPT" daemon "admin@example.com" "ups" >/dev/null 2>&1

assert_eq "0" "$?" "daemon succeeds after network/SMTP becomes available on retry #3"
assert_eq "3" "$(cat "$MAIL_CNT_3")" "daemon retried SMTP exactly 3 times before succeeding"
mail_3_body=$(cat "$MAIL_OUT_3")
assert_contains "$mail_3_body" "CORRENTE RIPRISTINATA DOPO SPEGNIMENTO" "Delivered email has Italian post-FSD recovery subject"
assert_contains "$mail_3_body" "la batteria dell'UPS è ancora in ricarica (32%)" "Delivered email includes charging deficit warning at 32%"
assert_contains "$mail_3_body" "Durata black-out: circa 10 minuti" "Delivered email includes computed outage duration"

status_3_after=$(NUT_STATE_DIR="$STATE_3" "$FSD_SCRIPT" status || true)
assert_contains "$status_3_after" "RECOVERY_STATE=IDLE" "State file cleared after confirmed email delivery"

# ---------------------------------------------------------------------
# 4. Second blackout (OB) while recovery is pending suspends delivery
# ---------------------------------------------------------------------
STATE_4="$FSD_TMP_DIR/state4"
MOCK_BIN_4="$FSD_TMP_DIR/mock_bin_4"
SEQ_4="$FSD_TMP_DIR/seq_4.txt"
IDX_4="$FSD_TMP_DIR/idx_4.txt"
MAIL_LOG_4="$FSD_TMP_DIR/mail_log_4.txt"
MOCK_MAIL_4="$FSD_TMP_DIR/mock_send_mail_4.sh"

create_mock_bin "$MOCK_BIN_4" "$SEQ_4"
# Poll 1: OL (SMTP fails - router booting)
# Poll 2 & 3: OB DISCHRG (second blackout! Must NOT call send_mail!)
# Poll 4: OL CHRG (power back -> SMTP succeeds!)
cat <<'EOF' > "$SEQ_4"
OL CHRG|33|230.0
OB DISCHRG|31|0.0
OB DISCHRG|30|0.0
OL CHRG|35|230.0
EOF
: > "$MAIL_LOG_4"

cat <<EOF > "$MOCK_MAIL_4"
#!/bin/sh
MSG=\$(cat)
ATTEMPT=\$(wc -l < "$MAIL_LOG_4" | tr -d ' ')
ATTEMPT=\$((ATTEMPT + 1))
printf "ATTEMPT=%s STATUS=%s\n" "\$ATTEMPT" "\${RAW_STATUS:-}" >> "$MAIL_LOG_4"
if [ "\$ATTEMPT" -eq 1 ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_MAIL_4"

NUT_STATE_DIR="$STATE_4" "$FSD_SCRIPT" mark-fsd "28" "$PAST_EPOCH" >/dev/null

PATH="$MOCK_BIN_4:$PATH" \
MOCK_UPSC_SEQ_FILE="$SEQ_4" \
MOCK_UPSC_IDX_FILE="$IDX_4" \
NUT_STATE_DIR="$STATE_4" \
ALERT_LANG="en" \
FSD_RECOVERY_STABLE_SEC=0 \
FSD_RECOVERY_POLL_INTERVAL=0 \
FSD_RECOVERY_RETRY_INITIAL=0 \
FSD_RECOVERY_RETRY_MAX=0 \
SEND_MAIL_BIN="$MOCK_MAIL_4" \
"$FSD_SCRIPT" daemon "admin@example.com" "ups" >/dev/null 2>&1

assert_eq "0" "$?" "daemon completes cleanly after second blackout resolves"
mail_log_4_content=$(cat "$MAIL_LOG_4")
assert_eq "2" "$(wc -l < "$MAIL_LOG_4" | tr -d ' ')" "Never attempted recovery email while UPS was OB (exactly 2 attempts on OL)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [[ "$mail_log_4_content" != *"OB"* ]]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} Zero recovery emails sent during OB status"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Recovery email was attempted during OB status!"
fi

# ---------------------------------------------------------------------
# 5. Double FSD cycle (second FSD before recovery email sent) + unsynced clock
# ---------------------------------------------------------------------
STATE_5="$FSD_TMP_DIR/state5"
MOCK_BIN_5="$FSD_TMP_DIR/mock_bin_5"
SEQ_5="$FSD_TMP_DIR/seq_5.txt"
IDX_5="$FSD_TMP_DIR/idx_5.txt"
MAIL_OUT_5="$FSD_TMP_DIR/mail_out_5.txt"
MOCK_MAIL_5="$FSD_TMP_DIR/mock_send_mail_5.sh"

create_mock_bin "$MOCK_BIN_5" "$SEQ_5"
printf "OL CHRG|65|230.0\n" > "$SEQ_5"

cat <<EOF > "$MOCK_MAIL_5"
#!/bin/sh
cat > "$MAIL_OUT_5"
exit 0
EOF
chmod +x "$MOCK_MAIL_5"

# Simulate FSD #1 with clock ahead of boot clock (RTC-less host unsynced clock case)
FUTURE_EPOCH=$(( $(date +%s) + 3600 ))
NUT_STATE_DIR="$STATE_5" "$FSD_SCRIPT" mark-fsd "28" "$FUTURE_EPOCH" >/dev/null
# Reboot #1 activates recovery
NUT_STATE_DIR="$STATE_5" "$FSD_SCRIPT" activate
# Power fails again & hits FSD #2 before recovery could notify!
NUT_STATE_DIR="$STATE_5" "$FSD_SCRIPT" mark-fsd "24" "0" >/dev/null

status_5=$(NUT_STATE_DIR="$STATE_5" "$FSD_SCRIPT" status)
assert_contains "$status_5" "RECOVERY_STATE=FSD_RECORDED" "Second FSD resets state to FSD_RECORDED"
assert_contains "$status_5" "FSD_COUNT=2" "Second FSD increments FSD_COUNT to 2"
assert_contains "$status_5" "BLACKOUT_START=$FUTURE_EPOCH" "Second FSD preserves original BLACKOUT_START"

# Reboot #2 finally recovers with stable OL & internet
PATH="$MOCK_BIN_5:$PATH" \
MOCK_UPSC_SEQ_FILE="$SEQ_5" \
MOCK_UPSC_IDX_FILE="$IDX_5" \
NUT_STATE_DIR="$STATE_5" \
ALERT_LANG="en" \
UPS_FRIENDLY_NAME="Lab UPS" \
FSD_RECOVERY_STABLE_SEC=0 \
FSD_RECOVERY_POLL_INTERVAL=0 \
FSD_RECOVERY_RETRY_INITIAL=0 \
FSD_RECOVERY_RETRY_MAX=0 \
SEND_MAIL_BIN="$MOCK_MAIL_5" \
"$FSD_SCRIPT" daemon "admin@example.com" "ups" >/dev/null 2>&1

assert_eq "0" "$?" "daemon succeeds after double FSD cycle"
mail_5_body=$(cat "$MAIL_OUT_5")
assert_contains "$mail_5_body" "2 consecutive shutdown cycles" "Email reports 2 consecutive FSD shutdown cycles"
assert_contains "$mail_5_body" "system clock syncing after reboot" "Unsynced clock at boot handled gracefully without negative duration"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [[ "$mail_5_body" != *"still recharging"* ]]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}✔ PASS:${RESET} No charging deficit warning when battery is >= 50% (65%)"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}✘ FAIL:${RESET} Unexpected charging deficit warning at 65% battery"
fi

# ---------------------------------------------------------------------
# 6. Max retry attempts exhaustion clears state cleanly
# ---------------------------------------------------------------------
STATE_6="$FSD_TMP_DIR/state6"
MOCK_BIN_6="$FSD_TMP_DIR/mock_bin_6"
SEQ_6="$FSD_TMP_DIR/seq_6.txt"
IDX_6="$FSD_TMP_DIR/idx_6.txt"
MOCK_MAIL_6="$FSD_TMP_DIR/mock_send_mail_6.sh"

create_mock_bin "$MOCK_BIN_6" "$SEQ_6"
printf "OL CHRG|80|230.0\n" > "$SEQ_6"
cat <<'EOF' > "$MOCK_MAIL_6"
#!/bin/sh
cat >/dev/null
exit 1
EOF
chmod +x "$MOCK_MAIL_6"

NUT_STATE_DIR="$STATE_6" "$FSD_SCRIPT" mark-fsd "28" "$PAST_EPOCH" >/dev/null
set +e
PATH="$MOCK_BIN_6:$PATH" \
MOCK_UPSC_SEQ_FILE="$SEQ_6" \
MOCK_UPSC_IDX_FILE="$IDX_6" \
NUT_STATE_DIR="$STATE_6" \
FSD_RECOVERY_STABLE_SEC=0 \
FSD_RECOVERY_POLL_INTERVAL=0 \
FSD_RECOVERY_RETRY_INITIAL=0 \
FSD_RECOVERY_RETRY_MAX=0 \
FSD_RECOVERY_MAX_ATTEMPTS=2 \
SEND_MAIL_BIN="$MOCK_MAIL_6" \
"$FSD_SCRIPT" daemon "admin@example.com" "ups" >/dev/null 2>&1
rc_6=$?
set -e
assert_eq "1" "$rc_6" "daemon exits 1 when FSD_RECOVERY_MAX_ATTEMPTS is exhausted"
status_6_after=$(NUT_STATE_DIR="$STATE_6" "$FSD_SCRIPT" status || true)
assert_contains "$status_6_after" "RECOVERY_STATE=IDLE" "State cleared after max attempts exhausted"

# ---------------------------------------------------------------------
# 7. ups_notifier.sh state machine: charging-deficit guard & delegation
# ---------------------------------------------------------------------
STATE_7="$FSD_TMP_DIR/state7"
EVENTS_LOG="$FSD_TMP_DIR/events.log"
: > "$EVENTS_LOG"

(
    export UPS_NOTIFIER_LIB_ONLY=1
    export UPS_SCRIPTS_DIR="$PROJECT_ROOT/image/scripts"
    export NUT_STATE_DIR="$STATE_7"
    export FSD_RECOVERY_BIN="$FSD_SCRIPT"
    . "$NOTIFIER_SCRIPT" "admin@example.com" "ups"

    # Override side-effect helpers for deterministic state machine testing
    refresh_telemetry_on_transition() { return 0; }
    trigger_event() { printf "%s\n" "$1" >> "$EVENTS_LOG"; }

    # 7A. Charging deficit blackout: OL -> OB at 32% must fire ONLY 'blackout' (no 70/50/35 storm!)
    PREV_STATUS="OL CHRG"
    RAW_STATUS="OB DISCHRG"
    CHARGE="32"
    CHARGE_INT=32
    LOAD_INT=15
    VOLTAGE="0.0"
    process_ups_snapshot

    # Subsequent OB poll still at 32% must fire nothing extra
    process_ups_snapshot

    # 7B. FSD event records persistent marker AND fires 'fsd'
    RAW_STATUS="OB LB FSD"
    CHARGE="29"
    CHARGE_INT=29
    process_ups_snapshot
)

events_7ab=$(tr '\n' ',' < "$EVENTS_LOG")
assert_eq "blackout,fsd," "$events_7ab" "Charging-deficit blackout at 32% fires ONLY blackout then fsd (zero 70/50/35 email flood)"

status_7=$(NUT_STATE_DIR="$STATE_7" "$FSD_SCRIPT" status)
assert_contains "$status_7" "RECOVERY_STATE=FSD_RECORDED" "ups_notifier.sh persists FSD marker automatically on FSD event"

# 7C. Charging deficit at 48%: fires blackout, suppresses 70 & 50, fires 35 when charge drops to 35%
: > "$EVENTS_LOG"
(
    export UPS_NOTIFIER_LIB_ONLY=1
    export UPS_SCRIPTS_DIR="$PROJECT_ROOT/image/scripts"
    export NUT_STATE_DIR="$STATE_7"
    export FSD_RECOVERY_BIN="$FSD_SCRIPT"
    . "$NOTIFIER_SCRIPT" "admin@example.com" "ups"

    refresh_telemetry_on_transition() { return 0; }
    trigger_event() { printf "%s\n" "$1" >> "$EVENTS_LOG"; }

    PREV_STATUS="OL CHRG"
    RAW_STATUS="OB DISCHRG"
    CHARGE="48"
    CHARGE_INT=48
    LOAD_INT=15
    process_ups_snapshot

    # Drops to 35% -> must fire batt_35 (and NOT batt_50 or batt_70)
    CHARGE="35"
    CHARGE_INT=35
    process_ups_snapshot
)
events_7c=$(tr '\n' ',' < "$EVENTS_LOG")
assert_eq "blackout,batt_35," "$events_7c" "Charging-deficit blackout at 48% suppresses 70/50 and fires batt_35 at 35%"

# 7D. OB -> OL delegation when post-FSD recovery is active (NO duplicate power_restored!)
NUT_STATE_DIR="$STATE_7" "$FSD_SCRIPT" activate
: > "$EVENTS_LOG"
(
    export UPS_NOTIFIER_LIB_ONLY=1
    export UPS_SCRIPTS_DIR="$PROJECT_ROOT/image/scripts"
    export NUT_STATE_DIR="$STATE_7"
    export FSD_RECOVERY_BIN="$FSD_SCRIPT"
    . "$NOTIFIER_SCRIPT" "admin@example.com" "ups"

    refresh_telemetry_on_transition() { return 0; }
    trigger_event() { printf "%s\n" "$1" >> "$EVENTS_LOG"; }

    PREV_STATUS="OB DISCHRG"
    RAW_STATUS="OL CHRG"
    CHARGE="35"
    CHARGE_INT=35
    LOAD_INT=15
    process_ups_snapshot >/dev/null
)
events_7d=$(cat "$EVENTS_LOG")
assert_eq "" "$events_7d" "ups_notifier.sh delegates power_restored when post-FSD recovery daemon is active (zero duplicate emails)"

# 7E. OB -> OL normal behavior once post-FSD recovery is cleared
NUT_STATE_DIR="$STATE_7" "$FSD_SCRIPT" clear
: > "$EVENTS_LOG"
(
    export UPS_NOTIFIER_LIB_ONLY=1
    export UPS_SCRIPTS_DIR="$PROJECT_ROOT/image/scripts"
    export NUT_STATE_DIR="$STATE_7"
    export FSD_RECOVERY_BIN="$FSD_SCRIPT"
    . "$NOTIFIER_SCRIPT" "admin@example.com" "ups"

    refresh_telemetry_on_transition() { return 0; }
    trigger_event() { printf "%s\n" "$1" >> "$EVENTS_LOG"; }

    PREV_STATUS="OB DISCHRG"
    RAW_STATUS="OL CHRG"
    CHARGE="85"
    CHARGE_INT=85
    LOAD_INT=15
    process_ups_snapshot >/dev/null
)
events_7e=$(tr '\n' ',' < "$EVENTS_LOG")
assert_eq "power_restored," "$events_7e" "ups_notifier.sh sends normal power_restored once post-FSD recovery is idle"

# ---------------------------------------------------------------------
# 8. send_mail.sh stale lock recovery
# ---------------------------------------------------------------------
STALE_LOCK="$FSD_TMP_DIR/stale_mail.lock"
mkdir -p "$STALE_LOCK"
printf "999999\n" > "$STALE_LOCK/pid"
stale_out=$(printf "Subject: Lock Test\n\nBody\n" | NUT_MAIL_LOCK_DIR="$STALE_LOCK" "$PROJECT_ROOT/image/scripts/send_mail.sh" "admin@example.com")
assert_contains "$stale_out" "Subject: Lock Test" "send_mail.sh works cleanly with custom NUT_MAIL_LOCK_DIR"
