#!/bin/sh
set -e

# =====================================================================
# NOTIFICATION TEST SCRIPT (test_email.sh)
# Verifies SMTP authentication and live UPS telemetry by triggering
# a test email through the Unix pipeline (build_message -> send_mail).
# Can be run directly from the host machine or inside the container.
# =====================================================================

# If executed on the host, forward the execution into the Docker container (-T disables TTY allocation)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -f "/.dockerenv" ] && [ -f "$BASE_DIR/docker-compose.yml" ]; then
    RECIPIENT="${1:-}"
    docker compose -f "$BASE_DIR/docker-compose.yml" exec -T nut-server /bin/sh -c '
        RECIPIENT="'"$RECIPIENT"'"
        if [ -z "$RECIPIENT" ] && [ -f "/etc/notification_email" ]; then
            RECIPIENT=$(cat /etc/notification_email | tr -d " \r\n")
        fi
        if [ -z "$RECIPIENT" ] && [ -f "/etc/msmtprc" ]; then
            RECIPIENT=$(grep -E "^from " /etc/msmtprc | awk "{print \$2}")
        fi
        if [ -z "$RECIPIENT" ]; then
            echo "❌ ERROR: No recipient email address specified."
            echo "   Set NOTIFICATION_EMAIL in configs/.env or pass it as an argument:"
            echo "   ./utils/test_email.sh your_email@domain.com"
            exit 1
        fi
        echo "=== Test Email Notification (SMTP & Telemetry) ==="
        echo "Test recipient: $RECIPIENT"
        echo "Generating test message and delivering via pipeline..."
        /scripts/build_message.sh "test" | /scripts/send_mail.sh "$RECIPIENT"
    '
    exit $?
fi

echo "=== Test Email Notification (SMTP & Telemetry) ==="

if [ ! -f "/etc/msmtprc" ]; then
    echo "⚠️ WARNING: SMTP configuration is not active (/etc/msmtprc not found)."
    echo "   Verify SMTP_USER in configs/.env and configs/secrets/smtp_password.txt."
    echo "   Running in simulation mode (printing to stdout only)."
fi

RECIPIENT="${1:-}"

# 1. If not supplied as argument, use configured notification email
if [ -z "$RECIPIENT" ] && [ -f "/etc/notification_email" ]; then
    RECIPIENT=$(cat /etc/notification_email | tr -d ' \r\n')
fi

# 2. If still empty, use sender address from msmtprc as fallback
if [ -z "$RECIPIENT" ] && [ -f "/etc/msmtprc" ]; then
    RECIPIENT=$(grep -E "^from " /etc/msmtprc | awk '{print $2}')
fi

if [ -z "$RECIPIENT" ]; then
    echo "❌ ERROR: No recipient email address specified."
    echo "   Set NOTIFICATION_EMAIL in configs/.env or pass it as an argument:"
    echo "   ./utils/test_email.sh your_email@domain.com"
    exit 1
fi

echo "Test recipient: $RECIPIENT"
echo "Generating test message and delivering via pipeline..."

# Invoke the Unix pipeline: build_message.sh -> send_mail.sh
/scripts/build_message.sh "test" | /scripts/send_mail.sh "$RECIPIENT"
