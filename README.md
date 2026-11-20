# ups-sharing — Docker NUT Server with TLS & SMTP Alerts

A lightweight (~25 MB disk, ~7 MB RAM), unprivileged **Alpine Linux** Docker stack for sharing any **USB HID Uninterruptible Power Supply (UPS)** over a local network using **Network UPS Tools (NUT)**, complete with TLS encryption, role-based access control, localized email notifications, and persistent post-shutdown recovery alerts.

---

## Key Features

- **Unprivileged Docker & Dynamic USB Re-enumeration**: Runs without `privileged: true`, using Linux cgroup rules (`c 189:* rmw`) so USB reboots and replug events are handled automatically without host `udev` scripts or container restarts.
- **Universal USB HID Auto-Discovery**: Automatically detects USB HID Power Device Class UPS units during setup (`lsusb`) and reads live hardware metadata (`ups.mfr`, `ups.model`, active/nominal wattage) dynamically at runtime.
- **Security by Default**:
  - Passwords are stored exclusively in **Docker Secrets** (`configs/secrets/*.txt`, `chmod 400`) mounted into RAM — never in `.env` or Git.
  - Auto-generated NSS **TLS** certificates encrypt client traffic on TCP port `3493`.
  - Role-separated NUT accounts: a **Primary** account for host shutdown coordination and a read-only **Secondary** account for remote clients.
- **Interactive TUI Setup Wizard**: Guided terminal setup (`sudo ./utils/setup.sh`) with arrow-key menus for UPS detection, Low Battery thresholds, alert language, NUT credentials, and SMTP configuration.
- **Real-Time Localized Email Alerts**:
  - Multi-provider SMTP support (built-in templates for Gmail and Outlook, plus custom/LAN SMTP relays or alerts disabled).
  - Localized alert dictionaries (`en` and `it` included, easily extensible with zero image rebuild).
  - Full event coverage:
    - Power Outage (`blackout`) with live load, wattage, and estimated runtime
    - Power Restored (`power_restored`) with computed outage duration
    - Battery Discharge Thresholds (`70%`, `50%`, `35%`) with charging-deficit storm suppression
    - Electrical Overload (`overload` / `overload_cleared`)
    - Forced Shutdown (`fsd`)
    - Post-FSD Power Restored (`fsd_power_restored`) with automatic post-reboot network/SMTP retry and mains stability verification
- **Safe Host & UPS Power-Cycle Helper**: Includes `utils/host_shutdown.sh` to schedule delayed UPS outlet power-off (`offdelay`/`ondelay`) before halting the Docker host so systems power back on cleanly when mains returns.

---

## Prerequisites

- Linux host with **Docker** and **Docker Compose** (`docker compose`)
- A **USB HID-compliant UPS** connected to the host via USB
- *(Optional, for automated OS shutdown)* `nut-client` installed on the host and any remote machines you want to shut down automatically

---

## Quick Start

### 1. Clone and Configure

#### Option A: Interactive Setup Wizard (Recommended)

Run the guided configuration wizard (requires `sudo` to enforce `root:root 400` permissions on Docker Secret files):

```bash
sudo ./utils/setup.sh
```

The wizard scans for your connected USB UPS, configures Low Battery safety thresholds, alert language, NUT Primary/Secondary credentials, and SMTP settings, then generates `configs/.env`, `configs/ups.conf`, and `configs/secrets/*.txt`.

#### Option B: Manual Configuration

```bash
# 1. Copy the environment template and edit your settings
cp configs/.env.example configs/.env
nano configs/.env

# 2. Create your configs/ups.conf driver definition (example)
cat <<'EOF' > configs/ups.conf
maxretry = 3
retrydelay = 5

[ups]
    driver = usbhid-ups
    port = auto
    pollinterval = 2
    ignorelb
    override.battery.charge.low = 30
    override.battery.runtime.low = 300
    offdelay = 60
    ondelay = 70
EOF

# 3. Store passwords in Docker Secret files
printf "%s" "your_primary_password"   > configs/secrets/nut_password.txt
printf "%s" "your_secondary_password" > configs/secrets/nut_secondary_password.txt
printf "%s" "your_smtp_password"      > configs/secrets/smtp_password.txt

# 4. Lock down permissions
chmod 600 configs/.env
chmod 400 configs/secrets/*.txt
```

### 2. Start the NUT Server

```bash
docker compose up -d --build
```

### 3. Verify Telemetry & Email Alerts

Check live metrics from the connected UPS:

```bash
docker compose exec nut-server /bin/sh -c 'upsc $UPS_NAME@localhost'
```

Send a live test alert email (or inspect dry-run output if SMTP is disabled):

```bash
./utils/test_email.sh
# Or override the recipient for a one-off test:
./utils/test_email.sh admin@example.com
```

---

## Configuration Reference (`configs/.env`)

| Variable | Default | Description |
| :--- | :--- | :--- |
| `TZ` | `UTC` | Container timezone (e.g. `UTC`, `America/New_York`, `Europe/London`) |
| `UPS_NAME` | `ups` | Internal NUT UPS identifier (must match `[<UPS_NAME>]` in `configs/ups.conf`) |
| `UPS_FRIENDLY_NAME` | `Home UPS` | Human-readable label shown in email alert subjects |
| `UPS_NOMINAL_WATTS` | *(auto)* | Optional fallback nominal power (Watts) if the UPS does not report `ups.realpower.nominal` via USB |
| `ALERT_LANG` | `en` | Alert dictionary language code (`en`, `it`, or custom `.lang` file) |
| `BATTERY_CHARGE_LOW` | `30` | Custom Low Battery (`LB`) trigger threshold (%) |
| `BATTERY_RUNTIME_LOW` | `300` | Custom Low Battery (`LB`) remaining runtime threshold (seconds) |
| `UPS_OFFDELAY` | `60` | Delay before UPS cuts outlet power after `shutdown.return` (seconds) |
| `UPS_ONDELAY` | `70` | Delay before UPS restores outlets when mains returns (must be `> UPS_OFFDELAY`) |
| `API_USER` | `upsmon` | Privileged **Primary** NUT username |
| `SECONDARY_USER` | `upsmon_client` | Read-only **Secondary** NUT username |
| `SMTP_PROVIDER` | `gmail` | Provider identifier (`gmail`, `outlook`, `custom`, or `none`) |
| `SMTP_HOST` / `SMTP_PORT` | `smtp.gmail.com` / `587` | Outgoing SMTP server address and port |
| `SMTP_TLS` / `SMTP_STARTTLS` / `SMTP_AUTH` | `on` | Transport security and SMTP authentication toggles (`on`/`off`) |
| `SMTP_USER` | — | Outgoing sender address / SMTP login username |
| `NOTIFICATION_EMAIL` | — | Default alert recipient email address |
| `FSD_RECOVERY_STABLE_SEC` | `15` | Optional: continuous `OL` seconds required before post-FSD recovery email |
| `FSD_RECOVERY_RETRY_INITIAL` / `_MAX` | `15` / `60` | Optional: exponential backoff range (seconds) for post-boot SMTP retries |
| `FSD_RECOVERY_MAX_ATTEMPTS` | `1440` | Optional: maximum post-boot retry attempts before clearing recovery state |

---

## Connecting Network Clients

### 1. Primary Host (Bare-Metal Docker Host)

Install `nut-client` on the host running Docker so it coordinates network-wide Forced Shutdown (`FSD`) when Low Battery is reached:

```bash
sudo apt update && sudo apt install nut-client
```

Set `/etc/nut/nut.conf`:

```ini
MODE=netclient
```

Configure `/etc/nut/upsmon.conf`:

```ini
MONITOR <UPS_NAME>@127.0.0.1:3493 1 <API_USER> <PRIMARY_PASSWORD> primary
MINSUPPLIES 1
SHUTDOWNCMD "/path/to/ups_sharing/utils/host_shutdown.sh"
FINALDELAY 60
HOSTSYNC 15
CERTVERIFY 0
```

> **Tip**: Verify `host_shutdown.sh` safely without powering off your machine:
> ```bash
> sudo ./utils/host_shutdown.sh --dry-run
> ```

### 2. Secondary Network Clients (Remote Servers, Workstations, NAS)

On any remote machine powered by the same UPS, install `nut-client`, set `MODE=netclient` in `/etc/nut/nut.conf`, and add to `/etc/nut/upsmon.conf`:

```ini
MONITOR <UPS_NAME>@<DOCKER_HOST_IP>:3493 1 <SECONDARY_USER> <SECONDARY_PASSWORD> secondary
SHUTDOWNCMD "/sbin/shutdown -h +0"
CERTVERIFY 0
```

- Replace `<UPS_NAME>`, `<DOCKER_HOST_IP>`, `<SECONDARY_USER>`, and `<SECONDARY_PASSWORD>` with your values from `configs/.env` and `configs/secrets/nut_secondary_password.txt`.
- `CERTVERIFY 0` accepts the container's auto-generated self-signed NSS TLS certificate.
- Any NUT-compatible monitoring dashboard or home automation integration can also connect to `<DOCKER_HOST_IP>:3493` using the **Secondary** credentials.

---

## Adding a New Alert Language

To add another language without rebuilding the image:

1. Copy `image/alerts/en.lang` to `image/alerts/<lang_code>.lang` (for example, `de.lang` or `fr.lang`).
2. Translate the values on the right-hand side of each `KEY="value"` pair.
3. Set `ALERT_LANG=<lang_code>` in `configs/.env` and restart the container.

If an unknown language code is configured, the notification pipeline automatically falls back to English (`en.lang`).

---

## Useful Commands

```bash
# List all UPS devices exposed by the server
docker compose exec nut-server upsc -l localhost

# Inspect all live UPS telemetry metrics
docker compose exec nut-server /bin/sh -c 'upsc $UPS_NAME@localhost'

# Stream notification and recovery daemon logs
docker compose logs -f | grep -E "NOTIFIER|FSD-RECOVERY|MAILER"

# Check post-FSD recovery state
docker compose exec nut-server /scripts/fsd_recovery.sh status

# Run the automated unit & integration test suite
./tests/run_tests.sh
```

---

## Architecture & Development

For a detailed technical breakdown of the security model, privilege separation, module structure, Unix notification pipeline, state machines, and FSD power-cycle sequence, see the dedicated **[Architecture Guide](ARCHITECTURE.md)**.

---

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)** — see the [LICENSE](LICENSE) file for details.
