#!/bin/sh
set -e

# =====================================================================
# CONTAINER ENTRYPOINT ORCHESTRATOR (image/entrypoint.sh)
# =====================================================================
# Responsibility:
#   Orchestrate the container startup lifecycle in clear, modular stages:
#     1. Initialize runtime & persistent state directories
#     2. Load & validate NUT configurations, Docker Secrets, and assets
#     3. Apply environment overrides to ups.conf
#     4. Configure SMTP client (msmtp), upsd.users, and NSS TLS database
#     5. Start the USB UPS hardware driver (upsdrvctl)
#     6. Launch background monitoring & post-FSD recovery daemons
#     7. Run upsd in foreground with graceful SIGTERM/SIGINT teardown
# =====================================================================

. /scripts/lib/bootstrap.sh
. /scripts/ups_telemetry.sh

RECOVERY_PID=""
NOTIFIER_PID=""
UPSD_PID=""

# ---------------------------------------------------------------------
# stop_nut: Gracefully stop background workers, upsd, and the UPS driver
# upon receiving SIGTERM or SIGINT.
# ---------------------------------------------------------------------
stop_nut() {
    echo "Received termination signal. Gracefully stopping daemons..."
    [ -n "$RECOVERY_PID" ] && kill -TERM "$RECOVERY_PID" 2>/dev/null || true
    [ -n "$NOTIFIER_PID" ] && kill -TERM "$NOTIFIER_PID" 2>/dev/null || true
    /usr/sbin/upsd -c stop 2>/dev/null || true
    /usr/sbin/upsdrvctl -u root stop 2>/dev/null || true
    exit 0
}

# ---------------------------------------------------------------------
# main: Execute ordered container bootstrap and daemon supervision.
# ---------------------------------------------------------------------
main() {
    APP_VERSION=$(tr -d '\r\n' < /VERSION 2>/dev/null || echo "1.0.0")
    echo "=== Initializing Network UPS Tools (NUT) Server v${APP_VERSION} ==="

    # 1. Runtime directories & config/secret bootstrap
    bootstrap_init_runtime_dirs
    bootstrap_load_nut_configs
    bootstrap_load_secrets
    bootstrap_validate_assets

    # 2. Synchronize Low Battery thresholds and shutdown delays into ups.conf
    apply_ups_conf_overrides "/etc/nut/ups.conf" \
        "${BATTERY_CHARGE_LOW:-}" \
        "${BATTERY_RUNTIME_LOW:-}" \
        "${UPS_OFFDELAY:-}" \
        "${UPS_ONDELAY:-}"

    # 3. Configure SMTP alerting, role-separated users, TLS, and permissions
    bootstrap_configure_smtp
    bootstrap_generate_upsd_users
    bootstrap_init_tls_nss
    bootstrap_harden_permissions

    # 4. Start UPS hardware driver and resolve monitored UPS identifier
    echo "Starting UPS driver (upsdrvctl)..."
    /usr/sbin/upsdrvctl -u root start

    UPS_NAME=$(detect_ups_name "${UPS_NAME:-}")
    echo "Monitored UPS: ${UPS_NAME}"

    # 5. Launch background event monitor and post-FSD recovery daemons
    echo "Starting event monitoring daemon..."
    /scripts/ups_notifier.sh "$NOTIFICATION_EMAIL" "$UPS_NAME" &
    NOTIFIER_PID=$!

    /scripts/fsd_recovery.sh daemon "$NOTIFICATION_EMAIL" "$UPS_NAME" &
    RECOVERY_PID=$!

    # 6. Register signal handlers and run upsd network daemon
    trap stop_nut SIGTERM SIGINT

    echo "Starting NUT upsd daemon with TLS on port 3493..."
    /usr/sbin/upsd -F &
    UPSD_PID=$!

    wait "$UPSD_PID"
}

main "$@"
