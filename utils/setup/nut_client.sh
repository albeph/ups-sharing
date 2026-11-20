#!/bin/bash
# =====================================================================
# NUT CLIENT CREDENTIALS MODULE (utils/setup/nut_client.sh)
# =====================================================================
# Responsibility:
#   Collect role-separated authentication credentials for NUT clients
#   connecting to TCP port 3493:
#     - Primary:   Bare-metal Docker host (upsmon) coordinating FSD
#     - Secondary: Remote network clients (read/monitor-only access)
#
# Public API:
#   configure_nut_client
# =====================================================================

# ---------------------------------------------------------------------
# configure_nut_client: Interactive wizard step for Primary and
# Secondary NUT client accounts.
# Populates: API_USER, API_PASSWORD, SECONDARY_USER, SECONDARY_PASSWORD
# ---------------------------------------------------------------------
configure_nut_client() {
    print_step "3/7" "NUT Client Credentials (Primary & Secondary)" "Role-based authentication for host shutdown control and remote clients"

    print_info "Primary user has full control (SET / instcmds) for the bare-metal Docker host."
    prompt_text "NUT Primary (admin) username" API_USER "upsmon"
    prompt_secret "Password for Primary user (${API_USER})" API_PASSWORD "upspassword"

    print_info "Secondary user has read/monitor-only access for remote network clients (servers, NAS, workstations)."
    prompt_text "NUT Secondary (client) username" SECONDARY_USER "upsmon_client"
    prompt_secret "Password for Secondary user (${SECONDARY_USER})" SECONDARY_PASSWORD "clientpassword"
}
