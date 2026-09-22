#!/bin/bash
# =====================================================================
# HARDWARE DETECTION MODULE (utils/setup/hardware.sh)
# Scans USB buses via 'lsusb' for connected UPS hardware, identifies
# manufacturer vendor IDs, and sets up the internal NUT identifier.
# =====================================================================

detect_ups_hardware() {
    print_step "1/7" "UPS Hardware Detection" "Scanning USB bus for connected UPS devices"

    # Scan the USB bus with 'lsusb' for connected UPS models (APC, Eaton, CyberPower, etc.)
    local detected_usb
    detected_usb=$(lsusb 2>/dev/null | grep -iE "American Power Conversion|APC|Eaton|CyberPower|Powercom|Uninterruptible Power Supply|UPS" | head -n1 || true)
    
    VENDOR_ID=""
    UPS_NAME="ups"

    if [ -n "$detected_usb" ]; then
        # Extract clean human-readable device name (strip Bus/Device/ID prefixes)
        local device_label
        device_label=$(echo "$detected_usb" | sed -E 's/^.*ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //')
        VENDOR_ID=$(echo "$detected_usb" | grep -oE "ID [0-9a-fA-F]{4}:" | head -n1 | tr -d 'ID :' || true)

        # Intelligently assign identifier name based on detected vendor
        case "$detected_usb" in
            *APC*|*American\ Power\ Conversion*) UPS_NAME="apc" ;;
            *Eaton*)                             UPS_NAME="eaton" ;;
            *CyberPower*)                        UPS_NAME="cyberpower" ;;
            *)                                   UPS_NAME="ups" ;;
        esac

        echo -e "  ${GREEN}✅ Found connected UPS:${RESET} ${BOLD}$device_label${RESET}"
        echo -e "     (Identifier: ${CYAN}${BOLD}$UPS_NAME${RESET})\n"

        local is_correct
        prompt_confirm "Is this your UPS device?" is_correct "Y"
        if [ "$is_correct" = false ]; then
            prompt_text "Enter custom internal identifier for NUT" UPS_NAME "$UPS_NAME"
        fi
    else
        echo -e "  ${YELLOW}ℹ️  No USB UPS detected. Ensure the device is connected.${RESET}\n"
        prompt_text "Enter internal identifier for NUT" UPS_NAME "ups"
    fi
}
