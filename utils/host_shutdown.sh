#!/bin/bash
set -u

# =====================================================================
# PRIMARY HOST SHUTDOWN & UPS DELAYED POWER-OFF (utils/host_shutdown.sh)
# =====================================================================
# Responsibility:
#   Serve as SHUTDOWNCMD in /etc/nut/upsmon.conf on the Primary bare-metal
#   Docker host. Because Docker stops before systemd completes host halt,
#   this script executes three ordered actions while the container is still
#   running:
#     1. Persist the post-FSD recovery marker via fsd_recovery.sh.
#     2. Schedule a delayed UPS outlet power-off ('shutdown.return' using
#        ups.conf offdelay/ondelay, or fallback 'load.off.delay <sec>')
#        using credentials read from configs/.env and configs/secrets/.
#     3. Immediately halt the host OS (/sbin/shutdown -h +0).
#
#   Note: Waiting for Secondary network nodes is handled by HOSTSYNC and
#   FINALDELAY in /etc/nut/upsmon.conf (no redundant sleep here).
#
# Usage:
#   In /etc/nut/upsmon.conf:
#     SHUTDOWNCMD "/path/to/ups_sharing/utils/host_shutdown.sh"
#   Dry-run verification:
#     sudo ./utils/host_shutdown.sh --dry-run
# =====================================================================

DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${UPS_SHARING_BASE_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="${BASE_DIR}/configs/.env"
SECRET_FILE="${BASE_DIR}/configs/secrets/nut_password.txt"

UPS_NAME="ups"
API_USER="upsmon"
CONTAINER_NAME="nut-server"
UPS_OFFDELAY="60"
API_PASSWORD=""

# ---------------------------------------------------------------------
# log_msg: Write a message to STDOUT and syslog (when logger exists).
# Arguments:
#   $1 - Log message string
# ---------------------------------------------------------------------
log_msg() {
    local msg="$1"
    echo "[HOST-SHUTDOWN] ${msg}"
    if command -v logger >/dev/null 2>&1; then
        logger -t "nut-host-shutdown" "$msg" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------
# read_env_var: Read a single key=value setting from configs/.env.
# Arguments:
#   $1 - Key name
#   $2 - Default fallback value
# ---------------------------------------------------------------------
read_env_var() {
    local key="$1"
    local default_val="$2"
    local val=""

    if [ -f "$ENV_FILE" ]; then
        val=$(grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d'=' -f2- | tr -d '"\r\n' || true)
    fi
    printf "%s" "${val:-$default_val}"
}

# ---------------------------------------------------------------------
# load_host_config: Populate runtime settings from .env and Docker Secret.
# ---------------------------------------------------------------------
load_host_config() {
    UPS_NAME=$(read_env_var "UPS_NAME" "ups")
    API_USER=$(read_env_var "API_USER" "upsmon")
    CONTAINER_NAME=$(read_env_var "CONTAINER_NAME" "nut-server")
    UPS_OFFDELAY=$(read_env_var "UPS_OFFDELAY" "60")

    API_PASSWORD=""
    if [ -r "$SECRET_FILE" ]; then
        API_PASSWORD=$(tr -d '\r\n' < "$SECRET_FILE")
    fi
}

# ---------------------------------------------------------------------
# run_upscmd_list: Query supported instant commands from the NUT server.
# ---------------------------------------------------------------------
run_upscmd_list() {
    if command -v docker >/dev/null 2>&1 && docker exec "$CONTAINER_NAME" true >/dev/null 2>&1; then
        docker exec "$CONTAINER_NAME" upscmd -l "${UPS_NAME}@localhost" 2>/dev/null || true
    elif command -v upscmd >/dev/null 2>&1; then
        upscmd -l "${UPS_NAME}@127.0.0.1:3493" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------
# select_poweroff_cmd: Select the preferred delayed power-off command
# supported by the connected UPS hardware.
# Arguments:
#   $1 - Output of 'upscmd -l'
# ---------------------------------------------------------------------
select_poweroff_cmd() {
    local supported_cmds="$1"
    if printf "%s\n" "$supported_cmds" | grep -qE '^shutdown\.return([[:space:]]|$)'; then
        printf "shutdown.return"
    elif printf "%s\n" "$supported_cmds" | grep -qE '^load\.off\.delay([[:space:]]|$)'; then
        printf "load.off.delay %s" "$UPS_OFFDELAY"
    else
        printf "shutdown.return"
    fi
}

# ---------------------------------------------------------------------
# schedule_ups_poweroff: Issue delayed outlet power-off to the UPS.
# ---------------------------------------------------------------------
schedule_ups_poweroff() {
    if [ -z "$API_PASSWORD" ]; then
        log_msg "⚠️ WARNING: Primary secret '${SECRET_FILE}' unreadable or empty; skipping UPS delayed power-off."
        return 1
    fi

    local supported_cmds selected_cmd
    supported_cmds=$(run_upscmd_list)
    selected_cmd=$(select_poweroff_cmd "$supported_cmds")

    if [ "$DRY_RUN" = true ]; then
        log_msg "[DRY-RUN] Would send UPS command: '${selected_cmd}' to '${UPS_NAME}' (user: ${API_USER}, offdelay: ${UPS_OFFDELAY}s)"
        return 0
    fi

    log_msg "Scheduling UPS delayed power-off ('${selected_cmd}', offdelay=${UPS_OFFDELAY}s) on '${UPS_NAME}'..."

    # Prefer executing inside the container over loopback to avoid host TLS CA mismatches
    if command -v docker >/dev/null 2>&1 && docker exec "$CONTAINER_NAME" true >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if docker exec "$CONTAINER_NAME" upscmd -u "$API_USER" -p "$API_PASSWORD" "${UPS_NAME}@localhost" $selected_cmd >/dev/null 2>&1; then
            log_msg "✅ UPS delayed power-off scheduled successfully via container '${CONTAINER_NAME}'."
            return 0
        fi
    fi

    # Fallback: host upscmd directly against 127.0.0.1:3493
    if command -v upscmd >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if upscmd -u "$API_USER" -p "$API_PASSWORD" "${UPS_NAME}@127.0.0.1:3493" $selected_cmd >/dev/null 2>&1; then
            log_msg "✅ UPS delayed power-off scheduled successfully via local upscmd."
            return 0
        fi
    fi

    log_msg "⚠️ WARNING: Could not schedule UPS delayed power-off. Proceeding with host shutdown anyway."
    return 1
}

# ---------------------------------------------------------------------
# record_fsd_recovery_marker: Persist the post-FSD marker via the
# container's fsd_recovery.sh module before halting (idempotent backup
# in case ups_notifier.sh did not poll FSD before shutdown began).
# ---------------------------------------------------------------------
record_fsd_recovery_marker() {
    if [ "$DRY_RUN" = true ]; then
        log_msg "[DRY-RUN] Would persist post-FSD recovery marker via container '${CONTAINER_NAME}'"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && docker exec "$CONTAINER_NAME" test -x /scripts/fsd_recovery.sh >/dev/null 2>&1; then
        if docker exec "$CONTAINER_NAME" /scripts/fsd_recovery.sh mark-fsd >/dev/null 2>&1; then
            log_msg "✅ Post-FSD recovery marker persisted via container '${CONTAINER_NAME}'."
            return 0
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------
# main: Parse CLI flags and execute the ordered shutdown sequence.
# ---------------------------------------------------------------------
main() {
    if [ "${1:-}" = "--dry-run" ]; then
        DRY_RUN=true
    fi

    load_host_config
    record_fsd_recovery_marker || true
    schedule_ups_poweroff || true

    if [ "$DRY_RUN" = true ]; then
        log_msg "[DRY-RUN] Would execute: /sbin/shutdown -h +0"
        exit 0
    fi

    log_msg "Initiating host OS shutdown (/sbin/shutdown -h +0)..."
    exec /sbin/shutdown -h +0
}

main "$@"
