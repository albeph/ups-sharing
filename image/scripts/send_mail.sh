#!/bin/sh
set -u

# =====================================================================
# EMAIL DELIVERY MODULE (image/scripts/send_mail.sh)
# =====================================================================
# Responsibility:
#   Read an RFC-822 formatted message ("Subject: <subj>\n\n<body>") from
#   STDIN, serialize concurrent deliveries via the shared POSIX lock,
#   and transmit via msmtp (or print a dry-run simulation when SMTP is
#   not configured).
#
# Usage:
#   build_message.sh <event> | send_mail.sh [recipient_email]
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lock.sh"
. "$SCRIPT_DIR/ups_telemetry.sh"

NUT_MAIL_LOCK_DIR="${NUT_MAIL_LOCK_DIR:-/tmp/nut_mail.lock}"
MSMTP_CONF_FILE="${MSMTP_CONF_FILE:-/etc/msmtprc}"
LOCK_ACQUIRED=0
SUBJECT=""
BODY=""

# ---------------------------------------------------------------------
# mail_cleanup: Release the delivery mutex if held when exiting.
# ---------------------------------------------------------------------
mail_cleanup() {
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        lock_release "$NUT_MAIL_LOCK_DIR"
        LOCK_ACQUIRED=0
    fi
}

# ---------------------------------------------------------------------
# mail_parse_stdin: Extract Subject header and message body from STDIN.
# Populates: SUBJECT, BODY
# Returns:
#   0 on success, 1 if STDIN is an interactive terminal (no input)
# ---------------------------------------------------------------------
mail_parse_stdin() {
    if [ -t 0 ]; then
        echo "[MAILER] ❌ ERROR: No message provided on STDIN." >&2
        echo "Usage: printf 'Subject: Test\n\nBody\n' | /scripts/send_mail.sh recipient@example.com" >&2
        return 1
    fi

    read -r _first_line || true
    case "$_first_line" in
        Subject:\ *)
            SUBJECT="${_first_line#Subject: }"
            # Skip optional empty separator line between headers and body
            read -r _second_line || true
            if [ -n "$_second_line" ]; then
                BODY="${_second_line}
$(cat)"
            else
                BODY=$(cat)
            fi
            ;;
        *)
            SUBJECT="[UPS Alert]"
            BODY="${_first_line}
$(cat)"
            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------
# mail_deliver_simulation: Print the message to STDOUT when SMTP is not
# configured or recipient is absent (dry-run mode).
# Arguments:
#   $1 - Resolved recipient email (may be empty)
# ---------------------------------------------------------------------
mail_deliver_simulation() {
    _recipient="$1"
    echo "[MAILER] [SIMULATION] Notification not transmitted via SMTP:"
    echo "[MAILER] Recipient: ${_recipient:-N/A}"
    echo "[MAILER] Subject: ${SUBJECT}"
    echo "$BODY"
}

# ---------------------------------------------------------------------
# mail_deliver_smtp: Serialize and transmit the message via msmtp.
# Arguments:
#   $1 - Target recipient email address
# Returns:
#   0 on successful delivery, 1 on msmtp failure
# ---------------------------------------------------------------------
mail_deliver_smtp() {
    _recipient="$1"
    _date_str=$(date -R)

    if lock_acquire "$NUT_MAIL_LOCK_DIR" 30; then
        LOCK_ACQUIRED=1
    fi

    echo "[MAILER] Sending email: ${SUBJECT} to ${_recipient}..."

    if printf "From: UPS Monitor <alert@ups>\nTo: %s\nSubject: %s\nDate: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n" \
        "$_recipient" "$SUBJECT" "$_date_str" "$BODY" | msmtp "$_recipient"; then
        echo "[MAILER] ✅ Email sent successfully!"
        mail_cleanup
        return 0
    else
        echo "[MAILER] ❌ Error sending email via msmtp." >&2
        mail_cleanup
        return 1
    fi
}

# ---------------------------------------------------------------------
# main: Parse STDIN and dispatch via simulation or msmtp.
# ---------------------------------------------------------------------
main() {
    trap mail_cleanup EXIT TERM INT

    _recipient=$(resolve_recipient "${1:-${NOTIFICATION_EMAIL:-}}")
    mail_parse_stdin || exit 1

    if [ -z "$_recipient" ] || [ ! -f "$MSMTP_CONF_FILE" ]; then
        mail_deliver_simulation "$_recipient"
        exit 0
    fi

    mail_deliver_smtp "$_recipient"
}

main "$@"
