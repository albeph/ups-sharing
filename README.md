# Network UPS Tools (NUT) Server - with TLS & Universal SMTP Alerts

A universal, secure, and minimal (~25 MB disk footprint, ~7 MB RAM usage) solution based on **Alpine Linux** to share any USB-connected Uninterruptible Power Supply (UPS) (APC, Eaton, CyberPower, etc.) over the local network using **Network UPS Tools (NUT)**.

---

## 🛡️ Key Features

- **Dynamic USB Discovery & Native Linux Kernel Protection**: No `privileged: true` container mode required. Utilizes Linux cgroup rules (`device_cgroup_rules: - 'c 189:* rmw'`) and `/dev/bus/usb` volume pass-through. Automatically handles dynamic USB re-enumeration (reboots, replug events, incrementing device IDs) without host udev scripts or container restarts, while guaranteeing hardware-level security.
- **Universal Auto-Discovery**: Dynamically detects any configured UPS brand or model (`upsc -l`), automatically tailoring texts, alerts, and telemetry without hardcoded names.
- **Clean Standard Security**:
  - Zero credentials committed to Git (`configs/.env` protected in `.gitignore`, provided template `configs/.env.example`).
  - Sensitive passwords managed via **Docker Secrets** mounted into RAM.
  - Encrypted **TLS / SSL** communication between NUT server and network clients (port 3493) using an auto-generated NSS certificate database.
- **Universal SMTP Provider Support & Templates**:
  - Multi-provider mail delivery: Google Gmail, Microsoft Outlook / Office 365, Local LAN SMTP relays (e.g. Synology, Postfix, Proxmox port 25 without auth), and custom SMTP servers.
  - Ready-to-use template files in `image/smtp_configs/`.
- **Interactive TUI Setup Wizard (`sudo ./utils/setup.sh`)**:
  - Interactive terminal UI with arrow-key navigation (`↑`/`↓` and `Enter`) for selecting alert language and SMTP provider.
  - Modular decomposition in `utils/setup/` (`ui.sh`, `hardware.sh`, `localization.sh`, `nut_client.sh`, `smtp.sh`, `secrets.sh`, `env_generator.sh`).
- **Modular Unix Alert Pipeline**:
  - 🔌 **Power Outage (Blackout)**: Instant alert on switch to battery power with current load and runtime.
  - 💡 **Power Restored**: Mains power restored with automatic calculation of blackout duration.
  - 📉 **70% Threshold**: Autonomy advisory.
  - ⚠️ **50% Threshold**: Pre-alarm warning.
  - 🚨 **35% Threshold**: Critical alert (imminent system shutdown).
  - 🛑 **FSD (Forced Shutdown)**: Clean network-wide client shutdown event.
  - ⚠️ **Electrical Overload**: Alert and clearance tracking.

---

## 🔐 Security Model & Privilege Separation

The project follows the **Principle of Least Privilege (PoLP)** and rigorous privilege separation:

### 1. Protection of Secrets at Rest (Docker Secrets)
- **Secrets isolation**: Sensitive credentials (NUT client password and SMTP password) reside in `configs/secrets/` with strict permissions (`chmod 400 root:root`).
- **No environment variable exposure**: Passwords are **never stored in `configs/.env`** and do not pass through Docker environment variables. Inspecting the container (`docker inspect`) reveals no credentials in container metadata.
- **Secure RAM injection**: Docker mounts secrets directly into volatile memory (`/run/secrets/`). The folder structure is tracked via `configs/secrets/.gitkeep` while secret files are excluded by `.gitignore`.

### 2. Native Linux Kernel Protection & Single-Bus Isolation
- **Unprivileged Container**: The container is strictly unprivileged (`privileged: false`). Docker strips dangerous Linux capabilities, specifically `CAP_SYS_RAWIO`, `CAP_NET_ADMIN`, and `CAP_NET_RAW`.
- **Shared Bus Protection (Raspberry Pi Zero 2W)**: On SBCs where a USB hub connects both the UPS and a USB-Ethernet adapter to a single USB bus controller, the Linux kernel natively enforces that userspace cannot detach kernel drivers (e.g. `usbnet`, `cdc_ether`, `ax88179`):
  > The kernel's `USBDEVFS_DISCONNECT` ioctl explicitly requires `CAP_SYS_RAWIO`. Because the container lacks this capability, any attempt to unbind or tamper with the host network adapter returns `-EPERM` (Operation not permitted) directly from the kernel.
- **Dynamic Re-enumeration**: Using `device_cgroup_rules: - 'c 189:* rmw'`, the container can access newly created USB device nodes (major 189) on the fly when the UPS is replugged or after a host reboot, while NUT's `libusb` walks the bus (`port = auto`) to claim the UPS without manual configuration.

### 3. Privilege Drop in Container Runtime
- **Startup phase (2 seconds)**: The entrypoint launches as root solely to load mounted secrets, generate TLS certificates, and initialize the USB device node permissions.
- **Steady-state daemon (Protected Network)**: The network daemon **`upsd`** (the only process listening on TCP port `3493`) immediately performs a **privilege drop**, transferring execution to the unprivileged system user **`nut`** (`UID=100`, `GID=101`).
  > In the event of an attempted network exploit against port 3493, an attacker remains confined to the unprivileged `nut` user without host or root escalation capabilities.

---

## 📁 Repository Structure

```text
ups_sharing/
├── docker-compose.yml      # Service orchestration, dynamic USB cgroup rules, secret mounts
├── .gitignore              # Secure ignore rules (configs/.env, configs/secrets/*)
├── configs/                # Configuration folder (mounted into container / runtime parameters)
│   ├── .env                # Active non-sensitive environment configuration (gitignored)
│   ├── .env.example        # Environment template for repository cloning
│   ├── nut.conf            # Operational mode (netserver)
│   ├── ups.conf            # Active UPS driver and communication configuration
│   ├── upsd.conf           # Network listening rules, access limits, and TLS paths
│   └── secrets/            # Docker Secrets directory (tracked via .gitkeep)
│       └── .gitkeep        # Git keep marker (password files are gitignored)
├── image/                  # Container build context and assets
│   ├── VERSION             # Semantic application version file (e.g. 1.0.0)
│   ├── Dockerfile          # Alpine Linux image with nut, nss-tools, msmtp, libusb
│   ├── entrypoint.sh       # Entrypoint: TLS setup, dynamic users, msmtp config, daemon launch
│   ├── smtp_configs/       # Universal SMTP templates (gmail, outlook, local, custom)
│   │   ├── gmail.conf      # Google Gmail template (port 587, STARTTLS, App Password)
│   │   ├── outlook.conf    # Microsoft Outlook / Office 365 template (port 587, STARTTLS)
│   │   ├── local.conf      # Local LAN SMTP relay template (port 25, no auth)
│   │   └── custom.conf.example # Custom SMTP provider template
│   ├── alerts/             # Pure key-value localization dictionaries (.lang)
│   │   ├── it.lang         # Italian alert subjects, messages, and telemetry labels
│   │   └── en.lang         # English alert subjects, messages, and telemetry labels
│   └── scripts/            # Modular Unix notification architecture (container)
│       ├── ups_notifier.sh # 1. Daemon: upsc polling, state transitions, threshold triggers
│       ├── build_message.sh# 2. Builder: loads .lang, formats status and telemetry block
│       └── send_mail.sh    # 3. Delivery: reads from STDIN and sends via msmtp
├── utils/                  # Administrator utility scripts (host)
│   ├── setup.sh            # Main interactive TUI wizard (arrow-key navigation)
│   ├── setup/              # Modular setup components
│   │   ├── ui.sh           # ANSI terminal controls & arrow-key menu component
│   │   ├── hardware.sh     # USB UPS hardware detection and identifier mapping
│   │   ├── localization.sh # Alert language selection & friendly labels
│   │   ├── nut_client.sh   # Client credentials for external integrations
│   │   ├── smtp.sh         # Multi-provider SMTP configuration & credentials
│   │   ├── secrets.sh      # Secure credential storage with root:root 400
│   │   └── env_generator.sh# Generation of configs/.env and configs/ups.conf
│   └── test_email.sh       # Instant email notification and telemetry test script
└── README.md
```

---

## 🚀 Quickstart Installation Guide

### Step 1: Initial Setup

#### Option A: Interactive Wizard (Recommended)
Run the automated modular setup wizard (requires root to protect secret files):
```bash
sudo ./utils/setup.sh
```
The wizard features interactive arrow-key selection (`↑`/`↓` and `Enter`), auto-detects your connected USB UPS via `lsusb`, lets you choose your alert language and SMTP provider, writes `configs/.env`, generates `configs/ups.conf`, and stores protected credentials in `configs/secrets/`.

#### Option B: Manual Setup
If you prefer manual configuration without running the wizard:
```bash
# 1. Copy environment template and customize parameters
cp configs/.env.example configs/.env
nano configs/.env

# 2. Store passwords in secrets files (folder already tracked via .gitkeep)
printf "%s" "your_nut_client_password" > configs/secrets/nut_password.txt
printf "%s" "your_smtp_app_password" > configs/secrets/smtp_password.txt

# 3. Secure file permissions
chmod 600 configs/.env
chmod 400 configs/secrets/*.txt
```

---

### Step 2: Start the NUT Server

Launch the container stack:
```bash
docker compose up -d --build
```
The container automatically connects to the UPS via dynamic Linux cgroup rules without requiring static USB device path pinning or host restarts.

---

### Step 3: Test Email Notifications (Optional)

Verify SMTP authentication and live UPS telemetry delivery without pulling the power plug:
```bash
./utils/test_email.sh
```
*(You can also test delivery to a custom address: `./utils/test_email.sh custom@domain.com`)*.

---

## 🌍 Localization & Adding Languages

Language and friendly names are chosen interactively during Step 1 (`sudo ./utils/setup.sh`) or via `configs/.env`:
- `ALERT_LANG`: Active notification language (`en` or `it` provided by default, defaults to `en`).
- `UPS_FRIENDLY_NAME`: Custom label (e.g. `"Home UPS"`, `"Lab UPS"`) displayed in alert subjects.
- **Automatic Fallback**: If an unsupported language code is specified, the system automatically falls back to English (`en`) with a console notice.

### Adding a New Language (e.g. German, French, Spanish)
To add a new language without rebuilding the Docker container:
1. Copy `image/alerts/en.lang` to your new language code (e.g. `image/alerts/de.lang`).
2. Translate the key-value dictionary values.
3. Set `ALERT_LANG=de` in `configs/.env`.
## 💻 Connecting Network Clients

To safely shut down other machines (Proxmox nodes, TrueNAS systems, Home Assistant, Linux servers) during extended power outages:

### Linux Clients (Debian, Ubuntu, Proxmox)
1. Install client package:
   ```bash
   sudo apt update && sudo apt install nut-client
   ```
2. In `/etc/nut/nut.conf`:
   ```ini
   MODE=netclient
   ```
3. In `/etc/nut/upsmon.conf`:
   ```ini
   MONITOR <ups_name>@<DOCKER_HOST_IP> 1 <API_USER> <API_PASSWORD> secondary
   SHUTDOWNCMD "/sbin/shutdown -h +0"
   POWERDOWNFLAG /etc/killpower
   ```
   > **Parameters**:
   > - `<ups_name>`: UPS identifier configured in `configs/.env` (`UPS_NAME`) and `configs/ups.conf` (e.g. `apc950`).
   > - `<API_USER>`: Client username configured in `configs/.env` (`API_USER`, default `upsmon`).
   > - `<API_PASSWORD>`: Client password stored in `configs/secrets/nut_password.txt`.
   > *(Connections automatically use TLS to encrypt passwords and shutdown signals).*

### Home Assistant
1. Navigate to **Settings** > **Devices & services** > **Add Integration**.
2. Search for **Network UPS Tools (NUT)**.
3. Enter the Docker host IP address, port `3493`, `API_USER` (from `configs/.env`), and `API_PASSWORD` (from `configs/secrets/nut_password.txt`).

---

## 🧪 Useful Diagnostic Commands

* **Inspect all live UPS telemetry metrics (over SSL)**:
  ```bash
  # Universal command (automatically uses UPS_NAME configured in configs/.env):
  docker compose exec nut-server /bin/sh -c 'upsc $UPS_NAME@localhost'

  # Or specifying your UPS identifier explicitly (e.g. eaton, cyberpower, ups, upc):
  docker compose exec nut-server upsc <UPS_NAME>@localhost
  ```

* **List all configured UPS devices on the server**:
  ```bash
  docker compose exec nut-server upsc -l localhost
  ```

* **Inspect live notification daemon logs**:
  ```bash
  docker compose logs -f | grep NOTIFIER
  ```
