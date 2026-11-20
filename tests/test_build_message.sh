#!/bin/bash
# =====================================================================
# UNIT TESTS: build_message.sh (tests/test_build_message.sh)
# =====================================================================

BUILD_SCRIPT="$PROJECT_ROOT/image/scripts/build_message.sh"

run_builder() {
    local event="$1"
    local lang="$2"
    local status="${3:-OL}"
    ALERT_LANG="$lang" \
    UPS_NAME="ups" \
    UPS_FRIENDLY_NAME="Lab UPS" \
    TIMESTAMP="07/11/2026 12:00:00" \
    RAW_STATUS="$status" \
    CHARGE="45" \
    RUNTIME="900" \
    RUNTIME_MIN="15" \
    VOLTAGE="230" \
    LOAD="25" \
    REALPOWER="" \
    NOMINAL_REALPOWER="600" \
    DURATION_MIN="4" \
    DURATION_SEC="240" \
    "$BUILD_SCRIPT" "$event"
}

# 1. Blackout event in Italian
msg_it=$(run_builder "blackout" "it" "OB DISCHRG")
assert_contains "$msg_it" "Subject: 🔌 [Lab UPS] INTERRUZIONE CORRENTE" "Italian blackout subject"
assert_contains "$msg_it" "OB (On Battery" "Italian OB status translation"
assert_contains "$msg_it" "~150 W (su 600 W nominali)" "Calculated power embedded in Italian details"

# 2. Power Restored event in English with outage duration
msg_en=$(run_builder "power_restored" "en" "OL CHRG")
assert_contains "$msg_en" "Subject: 💡 [Lab UPS] UTILITY POWER RESTORED" "English power_restored subject"
assert_contains "$msg_en" "Outage duration: approximately 4 minutes (240 seconds)" "Outage duration included in power_restored body"

# 3. Forced Shutdown (FSD) event
msg_fsd=$(run_builder "fsd" "it" "OB LB FSD")
assert_contains "$msg_fsd" "Subject: 🛑 [Lab UPS] COMANDO DI SPEGNIMENTO INIZIATO (FSD)" "FSD subject line"
assert_contains "$msg_fsd" "FSD (Forced ShutDown" "FSD status flag translated"
assert_contains "$msg_fsd" "LB (Low Battery" "LB status flag translated"

# 4. Battery threshold events (70%, 50%, 35%)
msg_35=$(run_builder "batt_35" "en" "OB DISCHRG")
assert_contains "$msg_35" "CRITICAL ALARM: Battery at 35%" "35% battery critical alarm subject"

# 5. Fallback to English on unsupported language code
msg_fallback=$(run_builder "test" "fr_unknown" "OL")
assert_contains "$msg_fallback" "Subject: 🧪 [TEST] Test Notification: Lab UPS" "Fallback to English dictionary when language file is missing"

# 6. Decimal runtime and charge handling in /bin/sh without arithmetic error
msg_decimal=$(ALERT_LANG="it" UPS_NAME="ups" UPS_FRIENDLY_NAME="Lab UPS" RAW_STATUS="OB DISCHRG" CHARGE="69.5" RUNTIME="3584.0" VOLTAGE="0.0" LOAD="6.5" NOMINAL_REALPOWER="600" "$BUILD_SCRIPT" "blackout")
assert_contains "$msg_decimal" "59 minuti (3584.0 sec)" "Handles decimal runtime (3584.0) without /bin/sh syntax error"

# 7. Post-FSD power restored event (Italian, with charging deficit warning & multi-cycle note)
msg_fsd_rec=$(FSD_TIMESTAMP="20/11/2026 08:15:00" FSD_COUNT="2" run_builder "fsd_power_restored" "it" "OL CHRG")
assert_contains "$msg_fsd_rec" "Subject: ✅ [Lab UPS] CORRENTE RIPRISTINATA DOPO SPEGNIMENTO" "Italian fsd_power_restored subject"
assert_contains "$msg_fsd_rec" "Precedente comando di spegnimento (FSD): 20/11/2026 08:15:00" "Includes previous FSD timestamp"
assert_contains "$msg_fsd_rec" "2 cicli consecutivi di spegnimento" "Includes consecutive FSD cycles note"
assert_contains "$msg_fsd_rec" "la batteria dell'UPS è ancora in ricarica (45%)" "Includes charging deficit warning when charge < 50%"

# 8. Post-FSD power restored event (English)
msg_fsd_rec_en=$(FSD_TIMESTAMP="20/11/2026 08:15:00" FSD_COUNT="1" run_builder "fsd_power_restored" "en" "OL CHRG")
assert_contains "$msg_fsd_rec_en" "Subject: ✅ [Lab UPS] POWER RESTORED AFTER SHUTDOWN" "English fsd_power_restored subject"
assert_contains "$msg_fsd_rec_en" "Previous shutdown command (FSD): 20/11/2026 08:15:00" "English previous FSD timestamp"
