#!/bin/bash
# =====================================================================
# NUT CLIENT CREDENTIALS MODULE (utils/setup/nut_client.sh)
# Configures username and password for network clients (Home Assistant,
# Proxmox, NAS, remote upsmon) querying TCP port 3493.
# =====================================================================

configure_nut_client() {
    print_step "3/7" "NUT Client Credentials (API / upsmon)" "Authentication for network clients (Home Assistant, Proxmox, NAS)"

    prompt_text "NUT client username" API_USER "upsmon"
    prompt_secret "Password for NUT user ($API_USER)" API_PASSWORD "upspassword"
}
