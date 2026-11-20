#!/bin/sh
set -e

# =====================================================================
# NOTIFICATION PIPELINE TESTER (utils/test_email.sh)
# =====================================================================
# Responsibility:
#   Verify SMTP authentication and live UPS telemetry by dispatching a
#   test alert through the Unix pipeline (build_message -> send_mail).
#   Automatically delegates into the running Docker container when run
#   on the host, or runs locally if executed inside the container.
#
# Usage:
#   ./utils/test_email.sh [recipient@example.com]
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------
# test_email_via_docker: Execute the test notification inside the
# running nut-server container using docker compose.
# Arguments:
#   $1 - Optional override recipient email address
# ---------------------------------------------------------------------
test_email_via_docker() {
    _recipient_arg="$1"
    docker compose -f "${BASE_DIR}/docker-compose.yml" exec -T nut-server /bin/sh -c '
        if [ ! -f "/scripts/ups_telemetry.sh" ]; then
            echo "❌ ERROR: Running container image is outdated (/scripts/ups_telemetry.sh not found)."
            echo "   Please rebuild and restart the container first:"
            echo "   docker compose up -d --build"
            exit 1
        fi
        . /scripts/ups_telemetry.sh
        RECIPIENT=$(resolve_recipient "$1")
        if [ -z "$RECIPIENT" ]; then
            echo "❌ ERROR: No recipient email address specified."
            echo "   Set NOTIFICATION_EMAIL in configs/.env or pass it as an argument:"
            echo "   ./utils/test_email.sh your_email@example.com"
            exit 1
        fi
        echo "=== Test Email Notification (SMTP & Telemetry) ==="
        echo "Test recipient: ${RECIPIENT}"
        echo "Generating test message and delivering via pipeline..."
        /scripts/build_message.sh "test" | /scripts/send_mail.sh "$RECIPIENT"
    ' test_email "$_recipient_arg"
}

# ---------------------------------------------------------------------
# test_email_local: Execute the test notification directly inside the
# container or local workspace environment.
# Arguments:
#   $1 - Optional override recipient email address
# ---------------------------------------------------------------------
test_email_local() {
    _recipient_arg="$1"

    if [ -f "/scripts/ups_telemetry.sh" ]; then
        _scripts_path="/scripts"
    else
        _scripts_path="${BASE_DIR}/image/scripts"
    fi

    . "${_scripts_path}/ups_telemetry.sh"

    echo "=== Test Email Notification (SMTP & Telemetry) ==="

    if [ ! -f "/etc/msmtprc" ]; then
        echo "⚠️ WARNING: SMTP configuration is not active (/etc/msmtprc not found)."
        echo "   Verify SMTP_USER in configs/.env and configs/secrets/smtp_password.txt."
        echo "   Running in simulation mode (printing to stdout only)."
    fi

    _recipient=$(resolve_recipient "$_recipient_arg")
    if [ -z "$_recipient" ]; then
        echo "❌ ERROR: No recipient email address specified."
        echo "   Set NOTIFICATION_EMAIL in configs/.env or pass it as an argument:"
        echo "   ./utils/test_email.sh your_email@example.com"
        exit 1
    fi

    echo "Test recipient: ${_recipient}"
    echo "Generating test message and delivering via pipeline..."
    "${_scripts_path}/build_message.sh" "test" | "${_scripts_path}/send_mail.sh" "$_recipient"
}

# ---------------------------------------------------------------------
# main: Choose Docker delegation or local execution mode.
# ---------------------------------------------------------------------
main() {
    _recipient_arg="${1:-}"
    if [ ! -f "/.dockerenv" ] && [ -f "${BASE_DIR}/docker-compose.yml" ]; then
        test_email_via_docker "$_recipient_arg"
    else
        test_email_local "$_recipient_arg"
    fi
}

main "$@"
