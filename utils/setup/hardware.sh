#!/bin/bash
# =====================================================================
# HARDWARE DETECTION MODULE (utils/setup/hardware.sh)
# =====================================================================
# Responsibility:
#   Scan USB buses via 'lsusb' for USB HID Power Device Class UPS units
#   using generic descriptors and standard USB-IF UPS vendor IDs, and
#   collect Low Battery (LB) and shutdown delay safety thresholds.
#
# Public API:
#   hardware_scan_usb_ups
#   hardware_extract_label <lsusb_line>
#   hardware_extract_vendor_id <lsusb_line>
#   detect_ups_hardware
# =====================================================================

# Standard USB-IF hexadecimal vendor IDs commonly used by USB HID UPS units
readonly HARDWARE_USB_UPS_PATTERN="Uninterruptible Power Supply|\bUPS\b|051d:|0463:|0764:|0d9f:|09ae:|04b4:|14b0:|06da:|05b8:"

# ---------------------------------------------------------------------
# hardware_scan_usb_ups: Query lsusb and return the first matching USB
# UPS device line (empty if none detected).
# ---------------------------------------------------------------------
hardware_scan_usb_ups() {
    lsusb 2>/dev/null | grep -iE "$HARDWARE_USB_UPS_PATTERN" | head -n1 || true
}

# ---------------------------------------------------------------------
# hardware_extract_label: Extract the human-readable device description
# from a raw lsusb output line.
# Arguments:
#   $1 - Raw lsusb line (e.g. "Bus 001 Device 002: ID 0001:0002 USB UPS")
# ---------------------------------------------------------------------
hardware_extract_label() {
    local usb_line="$1"
    printf "%s" "$usb_line" | sed -E 's/^.*ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //'
}

# ---------------------------------------------------------------------
# hardware_extract_vendor_id: Extract the 4-hex-digit USB vendor ID
# from a raw lsusb output line.
# Arguments:
#   $1 - Raw lsusb line
# ---------------------------------------------------------------------
hardware_extract_vendor_id() {
    local usb_line="$1"
    printf "%s" "$usb_line" | grep -oE 'ID [0-9a-fA-F]{4}:' | head -n1 | tr -d 'ID :' || true
}

# ---------------------------------------------------------------------
# detect_ups_hardware: Interactive wizard step to detect USB UPS
# hardware and configure Low Battery & shutdown delay parameters.
# Populates: VENDOR_ID, UPS_NAME, BATTERY_CHARGE_LOW,
#            BATTERY_RUNTIME_LOW, UPS_OFFDELAY, UPS_ONDELAY
# ---------------------------------------------------------------------
detect_ups_hardware() {
    print_step "1/7" "UPS Hardware Detection" "Scanning USB bus for connected UPS devices"

    local detected_usb
    detected_usb=$(hardware_scan_usb_ups)

    VENDOR_ID=""
    UPS_NAME="ups"

    if [ -n "$detected_usb" ]; then
        local device_label
        device_label=$(hardware_extract_label "$detected_usb")
        VENDOR_ID=$(hardware_extract_vendor_id "$detected_usb")

        echo -e "  ${GREEN}✅ Found connected UPS:${RESET} ${BOLD}${device_label}${RESET}"
        echo -e "     (Vendor ID: ${CYAN}${BOLD}${VENDOR_ID:-auto}${RESET}, Identifier: ${CYAN}${BOLD}${UPS_NAME}${RESET})\n"

        local is_correct
        prompt_confirm "Is this your UPS device?" is_correct "Y"
        if [ "$is_correct" = false ]; then
            VENDOR_ID=""
            prompt_text "Enter custom internal identifier for NUT" UPS_NAME "ups"
        else
            prompt_text "Internal UPS identifier for NUT" UPS_NAME "ups"
        fi
    else
        echo -e "  ${YELLOW}ℹ️  No USB UPS detected. Ensure the device is connected.${RESET}\n"
        prompt_text "Enter internal identifier for NUT" UPS_NAME "ups"
    fi

    print_info "Safety thresholds determine when NUT triggers Low Battery (LB) and initiates network-wide shutdown."
    prompt_text "Low battery charge threshold (%)" BATTERY_CHARGE_LOW "30"
    prompt_text "Low battery remaining runtime threshold (seconds)" BATTERY_RUNTIME_LOW "300"

    print_info "UPS power-off delay gives the host time to finish halting before the UPS cuts outlet power."
    prompt_text "UPS power-off delay after shutdown command (seconds)" UPS_OFFDELAY "60"
    UPS_ONDELAY=$(( ${UPS_OFFDELAY:-60} + 10 ))

    print_info "Output wattage is auto-detected from the UPS via USB. Leave empty unless your UPS does not report nominal Watts."
    prompt_text "Optional nominal power fallback in Watts (leave empty for auto)" UPS_NOMINAL_WATTS ""
}
