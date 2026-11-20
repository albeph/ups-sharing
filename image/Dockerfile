# =====================================================================
# DOCKERFILE (Dockerfile)
# Lightweight Alpine Linux image package containing Network UPS Tools
# (NUT), NSS cryptographic utilities for TLS, libusb, and msmtp for alerts.
# =====================================================================

FROM alpine:latest

# Install Network UPS Tools (NUT), USB/crypto libraries, SSL, and SMTP client
RUN apk add --no-cache \
    nut \
    libusb \
    udev \
    tzdata \
    openssl \
    nss-tools \
    msmtp \
    ca-certificates

# Create runtime directories with appropriate permissions and clean default package templates
RUN mkdir -p /var/run/nut /var/lib/nut-state /etc/nut /etc/nut-config /etc/nut/certs /scripts /alerts /smtp_configs && \
    rm -rf /etc/nut/* && \
    chown -R nut:nut /var/run/nut /etc/nut && \
    chmod 750 /var/run/nut /var/lib/nut-state

# Copy application scripts, alert templates, SMTP configurations, VERSION, and entrypoint
COPY VERSION /VERSION
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts /scripts
COPY alerts /alerts
COPY smtp_configs /smtp_configs
RUN chmod +x /usr/local/bin/entrypoint.sh /scripts/*.sh /scripts/lib/*.sh && \
    chmod 644 /alerts/* /smtp_configs/* /VERSION

EXPOSE 3493

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
