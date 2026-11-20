#!/bin/sh
# =====================================================================
# CONTAINER BOOTSTRAP MODULE (image/scripts/lib/bootstrap.sh)
# =====================================================================
# Responsibility:
#   Encapsulate container startup subsystems for the NUT server image:
#     - Runtime directory initialization
#     - Configuration validation & defaults generation
#     - RAM-backed Docker Secrets ingestion
#     - Universal SMTP (msmtp) configuration rendering
#     - Role-separated NUT user credentials generation (upsd.users)
#     - NSS TLS certificate database initialization
#     - Filesystem & USB permission hardening
#
# Public API:
#   bootstrap_init_runtime_dirs
#   bootstrap_load_nut_configs
#   bootstrap_read_secret <secret_file>
#   bootstrap_load_secrets
#   bootstrap_validate_assets
#   bootstrap_configure_smtp
#   bootstrap_generate_upsd_users
#   bootstrap_init_tls_nss
#   bootstrap_harden_permissions
# =====================================================================

# Configurable filesystem paths (overridable in automated tests)
NUT_RUN_DIR="${NUT_RUN_DIR:-/var/run/nut}"
NUT_STATE_DIR="${NUT_STATE_DIR:-/var/lib/nut-state}"
NUT_CONFIG_MOUNT_DIR="${NUT_CONFIG_MOUNT_DIR:-/etc/nut-config}"
NUT_ETC_DIR="${NUT_ETC_DIR:-/etc/nut}"
NUT_CERTS_DIR="${NUT_CERTS_DIR:-${NUT_ETC_DIR}/certs}"
NUT_SECRETS_DIR="${NUT_SECRETS_DIR:-/run/secrets}"
NUT_USB_BUS_DIR="${NUT_USB_BUS_DIR:-/dev/bus/usb}"
MSMTP_CONF_FILE="${MSMTP_CONF_FILE:-/etc/msmtprc}"
NOTIFICATION_EMAIL_FILE="${NOTIFICATION_EMAIL_FILE:-/etc/notification_email}"
ALERTS_DIR="${ALERTS_DIR:-/alerts}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"

# ---------------------------------------------------------------------
# bootstrap_init_runtime_dirs: Clean stale PIDs and prepare runtime
# and persistent state directories.
# ---------------------------------------------------------------------
bootstrap_init_runtime_dirs() {
    rm -f "${NUT_RUN_DIR}"/*.pid
    export NUT_STATE_DIR
    mkdir -p "$NUT_RUN_DIR" "$NUT_STATE_DIR"
    chown -R nut:nut "$NUT_RUN_DIR" 2>/dev/null || true
    chmod 750 "$NUT_RUN_DIR" "$NUT_STATE_DIR"
}

# ---------------------------------------------------------------------
# bootstrap_load_nut_configs: Validate mounted configuration directory,
# copy required NUT config files, and generate safe defaults if needed.
# ---------------------------------------------------------------------
bootstrap_load_nut_configs() {
    echo "Validating required configuration files in ${NUT_CONFIG_MOUNT_DIR}..."

    if [ ! -d "$NUT_CONFIG_MOUNT_DIR" ]; then
        echo "❌ FATAL ERROR: Configuration directory ${NUT_CONFIG_MOUNT_DIR} is not mounted!"
        echo "   Ensure './configs' is properly mounted in docker-compose.yml."
        return 1
    fi

    mkdir -p "$NUT_ETC_DIR"

    # Copy mandatory UPS driver configuration (ups.conf)
    if [ ! -f "${NUT_CONFIG_MOUNT_DIR}/ups.conf" ]; then
        echo "❌ FATAL ERROR: Required configuration file 'ups.conf' is missing from configs/!"
        echo "   Please create configs/ups.conf or run: sudo ./utils/setup.sh"
        echo "Aborting container startup due to missing configuration files."
        return 1
    fi
    cp -f "${NUT_CONFIG_MOUNT_DIR}/ups.conf" "${NUT_ETC_DIR}/ups.conf"

    # Copy nut.conf or generate standard netserver default if missing
    if [ -f "${NUT_CONFIG_MOUNT_DIR}/nut.conf" ]; then
        cp -f "${NUT_CONFIG_MOUNT_DIR}/nut.conf" "${NUT_ETC_DIR}/nut.conf"
    else
        echo "⚠️ NOTICE: 'nut.conf' not found in configs/. Using built-in default (MODE=netserver)."
        printf "MODE=netserver\n" > "${NUT_ETC_DIR}/nut.conf"
    fi

    # Copy upsd.conf or generate standard TLS network listener default if missing
    if [ -f "${NUT_CONFIG_MOUNT_DIR}/upsd.conf" ]; then
        cp -f "${NUT_CONFIG_MOUNT_DIR}/upsd.conf" "${NUT_ETC_DIR}/upsd.conf"
    else
        echo "⚠️ NOTICE: 'upsd.conf' not found in configs/. Using built-in default (0.0.0.0:3493 + NSS TLS)."
        cat <<EOF > "${NUT_ETC_DIR}/upsd.conf"
LISTEN 0.0.0.0 3493
MAXAGE 15
MAXCONN 1024
CERTPATH ${NUT_CERTS_DIR}
CERTIDENT "nut-server" ""
EOF
    fi

    # Copy any additional optional *.conf files from mounted configuration
    for _conf_file in "${NUT_CONFIG_MOUNT_DIR}"/*.conf; do
        [ -f "$_conf_file" ] && cp -f "$_conf_file" "${NUT_ETC_DIR}/"
    done

    # Verify ups.conf contains at least one active UPS section header [ups_name]
    if ! grep -qE '^\[[a-zA-Z0-9_-]+\]' "${NUT_ETC_DIR}/ups.conf"; then
        echo "❌ FATAL ERROR: No UPS definition section (e.g. [ups]) found in configs/ups.conf!"
        echo "   Check configs/ups.conf or run: sudo ./utils/setup.sh"
        return 1
    fi

    # Check USB bus pass-through availability
    if [ ! -d "$NUT_USB_BUS_DIR" ]; then
        echo "⚠️ WARNING: ${NUT_USB_BUS_DIR} directory is not present or mounted."
        echo "   USB-connected UPS hardware will not be accessible to the driver."
    fi

    return 0
}

# ---------------------------------------------------------------------
# bootstrap_read_secret: Read a single trimmed secret value from disk.
# Arguments:
#   $1 - Path to the secret file
# Outputs:
#   Trimmed secret value to STDOUT
# Returns:
#   0 if file exists and is non-empty, 1 otherwise
# ---------------------------------------------------------------------
bootstrap_read_secret() {
    _secret_path="$1"
    if [ -f "$_secret_path" ] && [ -s "$_secret_path" ]; then
        tr -d '\r\n' < "$_secret_path"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# bootstrap_load_secrets: Load NUT Primary, Secondary, and SMTP
# passwords from RAM-backed Docker Secrets (/run/secrets).
# Populates: API_PASSWORD, SECONDARY_PASSWORD, SMTP_PASSWORD
# ---------------------------------------------------------------------
bootstrap_load_secrets() {
    API_USER="${API_USER:-upsmon}"
    SECONDARY_USER="${SECONDARY_USER:-upsmon_client}"
    NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
    ALERT_LANG="${ALERT_LANG:-en}"
    UPS_FRIENDLY_NAME="${UPS_FRIENDLY_NAME:-}"
    UPS_NOMINAL_WATTS="${UPS_NOMINAL_WATTS:-}"
    export ALERT_LANG UPS_FRIENDLY_NAME UPS_NOMINAL_WATTS

    # Mandatory Primary NUT password
    if API_PASSWORD=$(bootstrap_read_secret "${NUT_SECRETS_DIR}/nut_password"); then
        echo "Loading NUT Primary password from Docker Secret (nut_password)..."
    else
        echo "❌ FATAL ERROR: Docker Secret 'nut_password' is missing or empty!"
        echo "   Please create configs/secrets/nut_password.txt or run: sudo ./utils/setup.sh"
        return 1
    fi

    # Optional Secondary NUT password (for remote read-only clients)
    SECONDARY_PASSWORD=""
    if SECONDARY_PASSWORD=$(bootstrap_read_secret "${NUT_SECRETS_DIR}/nut_secondary_password"); then
        echo "Loading NUT Secondary password from Docker Secret (nut_secondary_password)..."
    else
        SECONDARY_PASSWORD=""
        echo "⚠️ WARNING: Docker Secret 'nut_secondary_password' is not mounted or is empty!"
        echo "   Secondary user '${SECONDARY_USER}' will NOT be created in upsd.users."
        echo "   Ensure 'nut_secondary_password' is declared under 'secrets:' in docker-compose.yml."
    fi

    # Optional SMTP password
    SMTP_PASSWORD=""
    if SMTP_PASSWORD=$(bootstrap_read_secret "${NUT_SECRETS_DIR}/smtp_password"); then
        echo "Loading SMTP password from Docker Secret (smtp_password)..."
    else
        SMTP_PASSWORD=""
    fi

    return 0
}

# ---------------------------------------------------------------------
# bootstrap_validate_assets: Verify alert language dictionary (falling
# back to English if missing) and ensure internal scripts are executable.
# ---------------------------------------------------------------------
bootstrap_validate_assets() {
    if [ ! -f "${ALERTS_DIR}/${ALERT_LANG}.lang" ]; then
        echo "⚠️ NOTICE: Alert language file '${ALERTS_DIR}/${ALERT_LANG}.lang' not found. Falling back to English ('en.lang')."
        ALERT_LANG="en"
        export ALERT_LANG
    fi

    for _script in \
        "${SCRIPTS_DIR}/lib/lock.sh" \
        "${SCRIPTS_DIR}/ups_telemetry.sh" \
        "${SCRIPTS_DIR}/ups_notifier.sh" \
        "${SCRIPTS_DIR}/fsd_recovery.sh" \
        "${SCRIPTS_DIR}/build_message.sh" \
        "${SCRIPTS_DIR}/send_mail.sh" \
        "${SCRIPTS_DIR}/calculate_power.sh"; do
        if [ ! -x "$_script" ]; then
            echo "❌ FATAL ERROR: Essential script '${_script}' is missing or not executable!"
            return 1
        fi
    done

    return 0
}

# ---------------------------------------------------------------------
# bootstrap_configure_smtp: Generate /etc/msmtprc from environment
# variables and secrets, and persist default notification recipient.
# ---------------------------------------------------------------------
bootstrap_configure_smtp() {
    SMTP_PROVIDER="${SMTP_PROVIDER:-none}"
    SMTP_HOST="${SMTP_HOST:-}"
    SMTP_PORT="${SMTP_PORT:-587}"
    SMTP_TLS="${SMTP_TLS:-on}"
    SMTP_STARTTLS="${SMTP_STARTTLS:-on}"
    SMTP_AUTH="${SMTP_AUTH:-on}"
    SMTP_USER="${SMTP_USER:-}"

    if [ -n "$SMTP_HOST" ] && { [ -n "$SMTP_USER" ] || [ "$SMTP_AUTH" = "off" ]; }; then
        if [ "$SMTP_AUTH" = "on" ] && [ -z "${SMTP_PASSWORD:-}" ]; then
            echo "⚠️ WARNING: SMTP authentication is enabled for '${SMTP_USER}', but no password secret was found!"
            echo "   Email alerts disabled until configs/secrets/smtp_password.txt is provided."
        else
            echo "Configuring universal SMTP client (msmtp) for provider '${SMTP_PROVIDER}' (${SMTP_HOST}:${SMTP_PORT})..."
            cat <<EOF > "$MSMTP_CONF_FILE"
defaults
logfile /var/log/msmtp.log

account ${SMTP_PROVIDER}
host ${SMTP_HOST}
port ${SMTP_PORT}
EOF

            if [ "$SMTP_TLS" = "on" ]; then
                cat <<EOF >> "$MSMTP_CONF_FILE"
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
EOF
                if [ "$SMTP_STARTTLS" = "on" ]; then
                    echo "tls_starttls on" >> "$MSMTP_CONF_FILE"
                else
                    echo "tls_starttls off" >> "$MSMTP_CONF_FILE"
                fi
            else
                echo "tls off" >> "$MSMTP_CONF_FILE"
            fi

            if [ "$SMTP_AUTH" = "on" ]; then
                cat <<EOF >> "$MSMTP_CONF_FILE"
auth on
from ${SMTP_USER}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
EOF
            else
                cat <<EOF >> "$MSMTP_CONF_FILE"
auth off
from ${SMTP_USER:-ups-alert@localhost}
EOF
            fi

            cat <<EOF >> "$MSMTP_CONF_FILE"

account default : ${SMTP_PROVIDER}
EOF
            chmod 600 "$MSMTP_CONF_FILE"
            echo "✅ Universal SMTP configuration (${MSMTP_CONF_FILE}) successfully generated."
        fi
    else
        echo "SMTP credentials not configured: email alerts disabled."
    fi

    # Persist notification email address for runtime scripts
    if [ -n "${NOTIFICATION_EMAIL:-}" ]; then
        printf "%s\n" "$NOTIFICATION_EMAIL" > "$NOTIFICATION_EMAIL_FILE"
        chmod 644 "$NOTIFICATION_EMAIL_FILE"
    fi
}

# ---------------------------------------------------------------------
# bootstrap_generate_upsd_users: Copy custom upsd.users if supplied,
# otherwise generate role-separated Primary and Secondary accounts.
# ---------------------------------------------------------------------
bootstrap_generate_upsd_users() {
    _users_out="${NUT_ETC_DIR}/upsd.users"

    if [ -f "${NUT_CONFIG_MOUNT_DIR}/upsd.users" ]; then
        echo "Using custom upsd.users provided in mounted config..."
        cp -f "${NUT_CONFIG_MOUNT_DIR}/upsd.users" "$_users_out"
        return 0
    fi

    echo "Generating NUT Primary user credentials (${API_USER})..."
    cat <<EOF > "$_users_out"
[${API_USER}]
    password = ${API_PASSWORD}
    actions = SET
    instcmds = ALL
    upsmon primary
EOF

    if [ -n "${SECONDARY_PASSWORD:-}" ] && [ "$SECONDARY_USER" != "$API_USER" ]; then
        echo "Generating NUT Secondary user credentials (${SECONDARY_USER})..."
        cat <<EOF >> "$_users_out"

[${SECONDARY_USER}]
    password = ${SECONDARY_PASSWORD}
    upsmon secondary
EOF
    elif [ -n "${SECONDARY_PASSWORD:-}" ] && [ "$SECONDARY_USER" = "$API_USER" ]; then
        echo "⚠️ WARNING: SECONDARY_USER ('${SECONDARY_USER}') matches API_USER ('${API_USER}'); skipping duplicate entry."
    fi
}

# ---------------------------------------------------------------------
# bootstrap_init_tls_nss: Generate self-signed NSS certificate database
# for TLS-encrypted client connections if not already initialized.
# ---------------------------------------------------------------------
bootstrap_init_tls_nss() {
    if [ ! -f "${NUT_CERTS_DIR}/cert9.db" ] && [ ! -f "${NUT_CERTS_DIR}/cert8.db" ]; then
        echo "Generating TLS certificate database (NSS) for secure client connections..."
        mkdir -p "$NUT_CERTS_DIR"
        printf "\n" > /tmp/pw.txt
        certutil -N -d "$NUT_CERTS_DIR" -f /tmp/pw.txt
        dd if=/dev/urandom of=/tmp/noise count=1 bs=2048 2>/dev/null
        certutil -S -d "$NUT_CERTS_DIR" -n "nut-server" -s "CN=nut-server" -x -t "u,u,u" -m 1000 -v 120 -f /tmp/pw.txt -z /tmp/noise >/dev/null 2>&1
        rm -f /tmp/pw.txt /tmp/noise
    fi

    chown -R root:nut "$NUT_CERTS_DIR" 2>/dev/null || true
    chmod 750 "$NUT_CERTS_DIR"
    chmod 640 "${NUT_CERTS_DIR}"/* 2>/dev/null || true
}

# ---------------------------------------------------------------------
# bootstrap_harden_permissions: Restrict NUT config access to root:nut
# and allow driver read/write access on mapped USB bus device nodes.
# ---------------------------------------------------------------------
bootstrap_harden_permissions() {
    chown -R root:nut "$NUT_ETC_DIR" 2>/dev/null || true
    find "$NUT_ETC_DIR" -type f -exec chmod 640 {} +
    chmod 750 "$NUT_ETC_DIR"
    chmod -R a+w "$NUT_USB_BUS_DIR" 2>/dev/null || true
}
