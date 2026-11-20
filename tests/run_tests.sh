#!/bin/bash
set -u

# =====================================================================
# MODULAR TEST RUNNER & ASSERTION FRAMEWORK (tests/run_tests.sh)
# Executes all unit and integration test suites for ups_sharing.
# =====================================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"

# ANSI Styling
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# ---------------------------------------------------------------------
# Assertion Methods
# ---------------------------------------------------------------------
assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ "$expected" = "$actual" ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  ${GREEN}✔ PASS:${RESET} $message"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  ${RED}✘ FAIL:${RESET} $message"
        echo -e "         Expected: '${CYAN}$expected${RESET}'"
        echo -e "         Actual:   '${RED}$actual${RESET}'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Output should contain expected substring}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$haystack" == *"$needle"* ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  ${GREEN}✔ PASS:${RESET} $message"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  ${RED}✘ FAIL:${RESET} $message"
        echo -e "         Expected to find: '${CYAN}$needle${RESET}'"
        echo -e "         In output:        '${RED}$haystack${RESET}'"
    fi
}

assert_file_exists() {
    local filepath="$1"
    local message="${2:-File should exist: $filepath}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ -f "$filepath" ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  ${GREEN}✔ PASS:${RESET} $message"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  ${RED}✘ FAIL:${RESET} $message (File not found: $filepath)"
    fi
}

assert_file_mode() {
    local filepath="$1"
    local expected_mode="$2"
    local message="${3:-File permissions should match $expected_mode}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    local actual_mode
    actual_mode=$(stat -c "%a" "$filepath" 2>/dev/null || echo "missing")
    if [ "$actual_mode" = "$expected_mode" ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "  ${GREEN}✔ PASS:${RESET} $message"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "  ${RED}✘ FAIL:${RESET} $message (Expected: $expected_mode, Actual: $actual_mode)"
    fi
}

run_suite() {
    local suite_file="$1"
    local suite_name
    suite_name=$(basename "$suite_file" .sh)
    echo ""
    echo -e "${CYAN}${BOLD}━━━ Running Suite: ${suite_name} ━━━${RESET}"
    source "$suite_file"
}

echo -e "${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RESET}"
echo -e "${BOLD}${CYAN}┃             UPS_SHARING AUTOMATED TEST SUITE                ┃${RESET}"
echo -e "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RESET}"

for test_file in "$TESTS_DIR"/test_*.sh; do
    if [ -f "$test_file" ]; then
        run_suite "$test_file"
    fi
done

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Total Tests: ${BOLD}$TOTAL_TESTS${RESET} | ${GREEN}Passed: $PASSED_TESTS${RESET} | ${RED}Failed: $FAILED_TESTS${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if [ "$FAILED_TESTS" -gt 0 ]; then
    exit 1
fi
exit 0
