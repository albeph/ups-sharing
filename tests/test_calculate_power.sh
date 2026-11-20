#!/bin/bash
# =====================================================================
# UNIT TESTS: calculate_power.sh (tests/test_calculate_power.sh)
# =====================================================================

CALC_SCRIPT="$PROJECT_ROOT/image/scripts/calculate_power.sh"

# 1. Direct hardware reading with nominal power label
out=$("$CALC_SCRIPT" "OL" "25" "150" "600" "W" "(out of %s %s nominal)")
assert_eq "150 W (out of 600 W nominal)" "$out" "Direct realpower with nominal label formatting"

# 2. Direct hardware reading without nominal power
out=$("$CALC_SCRIPT" "OL" "25" "130" "" "W" "")
assert_eq "130 W" "$out" "Direct realpower without nominal power"

# 3. Dynamic calculation from Load % and Nominal Power (20% of 550W = 110W)
out=$("$CALC_SCRIPT" "OB DISCHRG" "20" "" "550" "W" "(out of %s %s nominal)")
assert_eq "~110 W (out of 550 W nominal)" "$out" "Dynamic calculation from load % and nominal watts"

# 4. Dynamic calculation with decimal load (33.3% of 600W = ~200W)
out=$("$CALC_SCRIPT" "OL" "33.3" "" "600" "W" "")
assert_eq "~200 W" "$out" "Dynamic calculation with decimal load percentage"

# 5. Unavailable status (N/D) with no readings
out=$("$CALC_SCRIPT" "N/D" "0" "" "" "W" "")
assert_eq "N/D" "$out" "Returns N/D when status is N/D and no power data exists"

# 6. Fallback when both realpower and nominal power are missing
out=$("$CALC_SCRIPT" "OL" "15" "" "" "W" "")
assert_eq "N/D" "$out" "Returns N/D when neither direct nor nominal power is available"
