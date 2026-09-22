#!/bin/bash
# =====================================================================
# HARDWARE DETECTION MODULE (utils/setup/hardware.sh)
# Scans USB buses via 'lsusb' for connected UPS hardware, identifies
# manufacturer vendor IDs, and sets up the internal NUT identifier.
# =====================================================================

detect_ups_hardware() {
    print_step "1/7" "UPS Hardware Detection" "Scanning USB bus for connected UPS devices"

    # Scan the USB bus with 'lsusb' for connected UPS models (by vendor string or known UPS vendor IDs)
    local detected_usb
    detected_usb=$(lsusb 2>/dev/null | grep -iE "American Power Conversion|APC|Eaton|MGE|CyberPower|Cyber Power|Powercom|Tripp Lite|Tripp-Lite|Riello|Legrand|Keor|PowerWalker|BlueWalker|Uninterruptible Power Supply|UPS|051d:|0463:|0764:|0d9f:|09ae:|04b4:|14b0:|06da:|05b8:" | head -n1 || true)
    
    VENDOR_ID=""
    UPS_NAME="ups"

    if [ -n "$detected_usb" ]; then
        # Extract clean human-readable device name (strip Bus/Device/ID prefixes)
        local device_label
        device_label=$(echo "$detected_usb" | sed -E 's/^.*ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //')
        VENDOR_ID=$(echo "$detected_usb" | grep -oE "ID [0-9a-fA-F]{4}:" | head -n1 | tr -d 'ID :' || true)

        # Intelligently assign identifier name based on detected vendor (string or Vendor ID)
        local detected_lower="${detected_usb,,}"
        case "$detected_lower" in
            *051d:*|*apc*|*american\ power\ conversion*)
                UPS_NAME="apc"
                ;;
            *0463:*|*eaton*|*mge*)
                UPS_NAME="eaton"
                ;;
            *0764:*|*cyberpower*|*cyber\ power*)
                UPS_NAME="cyberpower"
                ;;
            *0d9f:*|*powercom*)
                UPS_NAME="powercom"
                ;;
            *09ae:*|*tripp*lite*|*tripp-lite*)
                UPS_NAME="tripplite"
                ;;
            *04b4:*|*riello*)
                UPS_NAME="riello"
                ;;
            *14b0:*|*legrand*|*keor*)
                UPS_NAME="legrand"
                ;;
            *06da:*|*05b8:*|*powerwalker*|*bluewalker*)
                UPS_NAME="powerwalker"
                ;;
            *)
                UPS_NAME="ups"
                ;;
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
