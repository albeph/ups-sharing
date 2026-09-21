#!/bin/sh
set -e

# =====================================================================
# CONTAINER ENTRYPOINT SCRIPT (entrypoint.sh)
# Responsibilities: Initialize directories, load configurations, configure
# universal SMTP msmtprc, generate TLS NSS certificates, launch the UPS driver
# via upsdrvctl, start the notification daemon, and run upsd server.
# =====================================================================

APP_VERSION=$(cat /VERSION 2>/dev/null | tr -d '\r\n' || echo "1.0.0")
echo "=== Initializing Network UPS Tools (NUT) Server v${APP_VERSION} ==="

# 1. Clean up stale PID files in case of unclean container restarts
rm -f /var/run/nut/*.pid

# Ensure runtime directory exists with correct system permissions
mkdir -p /var/run/nut
chown -R nut:nut /var/run/nut
chmod 750 /var/run/nut

# ---------------------------------------------------------------------
# 2. PREREQUISITE & ESSENTIAL FILE VALIDATION
# ---------------------------------------------------------------------
echo "Validating required configuration files in /etc/nut-config..."

if [ ! -d "/etc/nut-config" ]; then
    echo "❌ FATAL ERROR: Configuration directory /etc/nut-config is not mounted!"
    echo "   Ensure './configs' is properly mounted in docker-compose.yml."
    exit 1
fi

MISSING_CONFIG=0
for conf_file in "nut.conf" "upsd.conf" "ups.conf"; do
    if [ ! -f "/etc/nut-config/$conf_file" ]; then
        echo "❌ FATAL ERROR: Required configuration file '$conf_file' is missing from configs/!"
        echo "   Please create configs/$conf_file or run: sudo ./utils/setup.sh"
        MISSING_CONFIG=1
    else
        cp -f "/etc/nut-config/$conf_file" "/etc/nut/$conf_file"
    fi
done

if [ "$MISSING_CONFIG" -eq 1 ]; then
    echo "Aborting container startup due to missing configuration files."
    exit 1
fi

# Copy any additional optional config files (e.g. upsd.users)
for f in /etc/nut-config/*.conf; do
    [ -f "$f" ] && cp -f "$f" /etc/nut/
done

# Check if ups.conf contains at least one active UPS definition section [ups_name]
if ! grep -qE '^\[[a-zA-Z0-9_-]+\]' /etc/nut/ups.conf; then
    echo "❌ FATAL ERROR: No UPS definition section (e.g. [apc950]) found in configs/ups.conf!"
    echo "   Check configs/ups.conf or run: sudo ./utils/setup.sh"
    exit 1
fi

# Check USB bus pass-through availability
if [ ! -d "/dev/bus/usb" ]; then
    echo "⚠️ WARNING: /dev/bus/usb directory is not present or mounted."
    echo "   USB-connected UPS hardware will not be accessible to the driver."
fi

API_USER="${API_USER:-upsmon}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
ALERT_LANG="${ALERT_LANG:-en}"
UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"
export ALERT_LANG UPS_FRIENDLY_NAME

# Load NUT password from Docker Secrets (RAM-backed /run/secrets)
if [ -f "/run/secrets/nut_password" ] && [ -s "/run/secrets/nut_password" ]; then
    echo "Loading NUT client password from Docker Secret (nut_password)..."
    API_PASSWORD=$(cat /run/secrets/nut_password | tr -d '\r\n')
else
    echo "❌ FATAL ERROR: Docker Secret 'nut_password' is missing or empty!"
    echo "   Please create configs/secrets/nut_password.txt or run: sudo ./utils/setup.sh"
    exit 1
fi

# Load SMTP password from Docker Secrets
SMTP_PASSWORD=""
if [ -f "/run/secrets/smtp_password" ] && [ -s "/run/secrets/smtp_password" ]; then
    echo "Loading SMTP password from Docker Secret (smtp_password)..."
    SMTP_PASSWORD=$(cat /run/secrets/smtp_password | tr -d '\r\n')
fi

# Validate alert language dictionary
if [ ! -f "/alerts/${ALERT_LANG}.lang" ]; then
    echo "⚠️ NOTICE: Alert language file '/alerts/${ALERT_LANG}.lang' not found. Falling back to English ('en.lang')."
    ALERT_LANG="en"
fi

# Validate essential internal scripts
for s in "/scripts/ups_notifier.sh" "/scripts/build_message.sh" "/scripts/send_mail.sh"; do
    if [ ! -x "$s" ]; then
        echo "❌ FATAL ERROR: Essential script '$s' is missing or not executable!"
        exit 1
    fi
done

# 3. Configure Universal SMTP Client (msmtp)
SMTP_PROVIDER="${SMTP_PROVIDER:-none}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_TLS="${SMTP_TLS:-on}"
SMTP_STARTTLS="${SMTP_STARTTLS:-on}"
SMTP_AUTH="${SMTP_AUTH:-on}"
SMTP_USER="${SMTP_USER:-}"

if [ -n "$SMTP_HOST" ] && { [ -n "$SMTP_USER" ] || [ "$SMTP_AUTH" = "off" ]; }; then
    if [ "$SMTP_AUTH" = "on" ] && [ -z "$SMTP_PASSWORD" ]; then
        echo "⚠️ WARNING: SMTP authentication is enabled for '$SMTP_USER', but no password secret was found!"
        echo "   Email alerts disabled until configs/secrets/smtp_password.txt is provided."
    else
        echo "Configuring universal SMTP client (msmtp) for provider '${SMTP_PROVIDER}' ($SMTP_HOST:$SMTP_PORT)..."
        cat <<EOF > /etc/msmtprc
defaults
logfile /var/log/msmtp.log

account ${SMTP_PROVIDER}
host ${SMTP_HOST}
port ${SMTP_PORT}
EOF

        if [ "$SMTP_TLS" = "on" ]; then
            cat <<EOF >> /etc/msmtprc
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
EOF
            if [ "$SMTP_STARTTLS" = "on" ]; then
                echo "tls_starttls on" >> /etc/msmtprc
            else
                echo "tls_starttls off" >> /etc/msmtprc
            fi
        else
            echo "tls off" >> /etc/msmtprc
        fi

        if [ "$SMTP_AUTH" = "on" ]; then
            cat <<EOF >> /etc/msmtprc
auth on
from ${SMTP_USER}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
EOF
        else
            cat <<EOF >> /etc/msmtprc
auth off
from ${SMTP_USER:-ups-alert@localhost}
EOF
        fi

        cat <<EOF >> /etc/msmtprc

account default : ${SMTP_PROVIDER}
EOF
        chmod 600 /etc/msmtprc
        echo "✅ Universal SMTP configuration (/etc/msmtprc) successfully generated."
    fi
else
    echo "SMTP credentials not configured: email alerts disabled."
fi

# Save notification email address for runtime scripts
if [ -n "${NOTIFICATION_EMAIL:-}" ]; then
    echo "$NOTIFICATION_EMAIL" > /etc/notification_email
    chmod 644 /etc/notification_email
fi

# 4. Generate upsd.users with active credentials
if [ -f "/etc/nut-config/upsd.users" ]; then
    echo "Using custom upsd.users provided in mounted config..."
    cp -f /etc/nut-config/upsd.users /etc/nut/upsd.users
else
    echo "Generating NUT user credentials ($API_USER)..."
    cat <<EOF > /etc/nut/upsd.users
[$API_USER]
    password = $API_PASSWORD
    actions = SET
    instcmds = ALL
    upsmon primary
EOF
fi

# 5. Initialize TLS certificate database (NSS) if not already present
if [ ! -f "/etc/nut/certs/cert9.db" ] && [ ! -f "/etc/nut/certs/cert8.db" ]; then
    echo "Generating TLS certificate database (NSS) for secure client connections..."
    mkdir -p /etc/nut/certs
    echo "" > /tmp/pw.txt
    certutil -N -d /etc/nut/certs -f /tmp/pw.txt
    dd if=/dev/urandom of=/tmp/noise count=1 bs=2048 2>/dev/null
    certutil -S -d /etc/nut/certs -n "nut-server" -s "CN=nut-server" -x -t "u,u,u" -m 1000 -v 120 -f /tmp/pw.txt -z /tmp/noise >/dev/null 2>&1
    rm -f /tmp/pw.txt /tmp/noise
fi

chown -R root:nut /etc/nut/certs
chmod 750 /etc/nut/certs
chmod 640 /etc/nut/certs/* 2>/dev/null || true

# Secure permissions on NUT configuration files
chown -R root:nut /etc/nut
find /etc/nut -type f -exec chmod 640 {} +
chmod 750 /etc/nut

# Ensure read/write access to mapped USB device node
chmod -R a+w /dev/bus/usb 2>/dev/null || true

# 6. Start UPS hardware driver
echo "Starting UPS driver (upsdrvctl)..."
/usr/sbin/upsdrvctl -u root start

# 7. Auto-detect UPS name
if [ -z "${UPS_NAME:-}" ]; then
    UPS_NAME=$(upsc -l localhost 2>/dev/null | head -n1 || true)
fi
if [ -z "$UPS_NAME" ] && [ -f "/etc/nut/ups.conf" ]; then
    UPS_NAME=$(sed -n 's/^\[\([^]]*\)\]/\1/p' /etc/nut/ups.conf | head -n1 || true)
fi
UPS_NAME="${UPS_NAME:-ups}"
echo "Monitored UPS: $UPS_NAME"

# 8. Start background notification daemon
echo "Starting event monitoring daemon..."
/scripts/ups_notifier.sh "$NOTIFICATION_EMAIL" "$UPS_NAME" &
NOTIFIER_PID=$!

# Graceful termination handler for SIGTERM / SIGINT
stop_nut() {
    echo "Received termination signal. Gracefully stopping daemons..."
    kill -TERM "$NOTIFIER_PID" 2>/dev/null || true
    /usr/sbin/upsd -c stop 2>/dev/null || true
    /usr/sbin/upsdrvctl -u root stop 2>/dev/null || true
    exit 0
}

trap stop_nut SIGTERM SIGINT

echo "Starting NUT upsd daemon with TLS on port 3493..."
/usr/sbin/upsd -F 2>&1 | grep -v "SSL handshake done successfully" &
UPSD_PID=$!

wait $UPSD_PID
