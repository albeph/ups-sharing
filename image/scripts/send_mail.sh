#!/bin/sh
set -u

# =====================================================================
# EMAIL DELIVERY SCRIPT (send_mail.sh)
# Responsibilities: Read message from STDIN formatted with "Subject: <subj>",
# parse MIME headers, and transmit via msmtp (or print dry-run simulation).
# =====================================================================

RECIPIENT="${1:-${NOTIFICATION_EMAIL:-}}"

# If still not set, inspect /etc/notification_email
if [ -z "$RECIPIENT" ] && [ -f "/etc/notification_email" ]; then
    RECIPIENT=$(cat /etc/notification_email | tr -d ' \r\n')
fi

# Read Subject and Body from STDIN
if [ -t 0 ]; then
    echo "[MAILER] ❌ ERROR: No message provided on STDIN." >&2
    echo "Usage: echo -e 'Subject: Test\n\nBody' | /scripts/send_mail.sh recipient@email.com" >&2
    exit 1
fi

read -r FIRST_LINE || true
case "$FIRST_LINE" in
    Subject:\ *)
        SUBJECT="${FIRST_LINE#Subject: }"
        # Skip empty separator line if present
        read -r SECOND_LINE || true
        if [ -n "$SECOND_LINE" ]; then
            BODY="${SECOND_LINE}
$(cat)"
        else
            BODY=$(cat)
        fi
        ;;
    *)
        SUBJECT="[UPS Alert]"
        BODY="${FIRST_LINE}
$(cat)"
        ;;
esac

# If credentials or recipient are missing, run in simulation mode
if [ -z "$RECIPIENT" ] || [ ! -f "/etc/msmtprc" ]; then
    echo "[MAILER] [SIMULATION] Notification not transmitted via SMTP:"
    echo "[MAILER] Recipient: ${RECIPIENT:-N/A}"
    echo "[MAILER] Subject: $SUBJECT"
    echo "$BODY"
    exit 0
fi

DATE_STR=$(date -R)
echo "[MAILER] Sending email: $SUBJECT to $RECIPIENT..."

if printf "From: UPS Monitor <alert@ups>\nTo: %s\nSubject: %s\nDate: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n" \
    "$RECIPIENT" "$SUBJECT" "$DATE_STR" "$BODY" | msmtp "$RECIPIENT"; then
    echo "[MAILER] ✅ Email sent successfully!"
else
    echo "[MAILER] ❌ Error sending email via msmtp." >&2
    exit 1
fi
