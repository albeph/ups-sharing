# AGENTS.md — AI Coding Agent Guidelines for `ups_sharing`

This document defines the architecture, security invariants, coding standards, and verification workflows for AI coding agents working on the `ups_sharing` repository.

For full architectural diagrams, security model details, and state machines, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. Project Overview & Architecture

`ups_sharing` is a lightweight, unprivileged **Alpine Linux Docker container** providing a **Network UPS Tools (NUT)** server (`upsd` + `usbhid-ups`) with TLS encryption and a modular Unix email notification pipeline (`msmtp`).

### Core Architectural Boundaries
- **Container Role (`nut-server`)**:
  - Manages USB UPS driver (`upsdrvctl`), network server (`upsd` on TCP `3493` with NSS TLS), real-time email alerting (`ups_notifier.sh`), and post-FSD recovery delivery (`fsd_recovery.sh`).
  - Does **not** execute host shutdown commands inside the container.
- **Host Bare-Metal Role (`primary`)**:
  - The Docker host runs `nut-client` (`upsmon`) on bare metal connected to `127.0.0.1:3493` using the **Primary** account (`API_USER`).
  - Coordinates network-wide **Forced Shutdown (`FSD`)** when the UPS hits Low Battery (`LB`).
- **Remote Network Nodes (`secondary`)**:
  - Remote machines (Linux servers, NAS appliances, hypervisors, workstations, monitoring dashboards) connect to `<HOST_IP>:3493` using the read-only **Secondary** account (`SECONDARY_USER`) with role `secondary`.

---

## 2. Repository Map & Module Responsibilities

```text
ups_sharing/
├── docker-compose.yml          # Unprivileged service, USB cgroup rules (189:*), Docker Secrets
├── AGENTS.md                   # AI Agent architectural & development guide
├── ARCHITECTURE.md             # Dedicated technical architecture & state machine guide
├── README.md                   # User-facing overview, features, and usage guide
├── configs/                    # Runtime configuration mounted at /etc/nut-config:ro
│   ├── .env.example            # Template for non-sensitive environment variables
│   ├── nut.conf                # NUT mode (MODE=netserver)
│   ├── ups.conf                # UPS driver config + safety low-battery overrides (gitignored)
│   ├── upsd.conf               # Network listener & NSS TLS certificate paths
│   └── secrets/                # RAM-mounted Docker Secrets (gitignored except .gitkeep)
│       ├── nut_password.txt            # Primary user password (chmod 400)
│       ├── nut_secondary_password.txt  # Secondary user password (chmod 400)
│       └── smtp_password.txt           # SMTP password (chmod 400)
├── image/                      # Container build context
│   ├── Dockerfile              # Alpine Linux + nut, libusb, nss-tools, msmtp
│   ├── entrypoint.sh           # Concise lifecycle orchestrator & signal handler
│   ├── alerts/                 # Localization dictionaries (en.lang, it.lang)
│   ├── smtp_configs/           # Provider templates (gmail.conf, outlook.conf, custom.conf.example)
│   └── scripts/                # Modular Unix notification & bootstrap pipeline (POSIX /bin/sh)
│       ├── lib/
│       │   ├── lock.sh         # Shared POSIX atomic directory lock with stale-PID recovery
│       │   └── bootstrap.sh    # Container bootstrap (configs, secrets, msmtp, upsd.users, TLS)
│       ├── ups_telemetry.sh    # Shared discovery, upsc snapshot parser, voltage refresh
│       ├── ups_notifier.sh     # Polling daemon & event state machine
│       ├── fsd_recovery.sh     # Independent post-FSD power recovery state & retry manager
│       ├── build_message.sh    # RFC-822 message builder & status translator
│       ├── calculate_power.sh  # Real-time Watt calculation (direct or nominal * load)
│       └── send_mail.sh        # STDIN parser & serialized msmtp dispatcher (with dry-run)
├── utils/                      # Host administrator CLI utilities (Bash / POSIX sh)
│   ├── setup.sh                # Interactive TUI wizard orchestrator
│   ├── host_shutdown.sh        # Primary SHUTDOWNCMD: marks FSD, schedules UPS power-off, halts host
│   ├── test_email.sh           # End-to-end notification pipeline tester
│   └── setup/                  # Single-responsibility setup modules
│       ├── ui.sh               # ANSI TUI controls, menus, masked secret inputs
│       ├── hardware.sh         # USB HID UPS auto-discovery & Low Battery safety thresholds
│       ├── localization.sh     # Language discovery & friendly naming
│       ├── nut_client.sh       # Primary & Secondary user credential prompts
│       ├── smtp.sh             # SMTP template loader & custom provider setup
│       ├── secrets.sh          # DAC 400 root:root secret writer
│       └── env_generator.sh    # Generator for configs/.env and configs/ups.conf
└── tests/                      # Automated unit & integration test suite
    ├── run_tests.sh            # Test runner & assertion framework
    ├── test_lock.sh            # Atomic POSIX lock & stale-PID recovery tests
    ├── test_bootstrap.sh       # Container bootstrap, secrets, msmtprc & upsd.users tests
    ├── test_ups_telemetry.sh   # Telemetry snapshot, decimal safety & voltage refresh tests
    ├── test_calculate_power.sh # Power calculation unit tests
    ├── test_build_message.sh   # Message formatting & localization tests
    ├── test_fsd_recovery.sh    # Post-FSD recovery, network retry & charging-deficit tests
    ├── test_send_mail.sh       # Mail pipeline & simulation tests
    └── test_setup_modules.sh   # Setup wizard generator, helpers & role-separation tests
```

---

## 3. Security & Design Invariants (MUST FOLLOW)

1. **Zero Plaintext Credentials in Git or `.env`**:
   - Never write passwords into `configs/.env`, `docker-compose.yml`, or static files tracked by Git.
   - All passwords MUST be stored in `configs/secrets/*.txt` (`chmod 400`) and injected via Docker Secrets (`/run/secrets/`).
2. **Unprivileged Container Execution**:
   - Never add `privileged: true` to `docker-compose.yml`.
   - USB pass-through relies strictly on `device_cgroup_rules: - 'c 189:* rmw'` and `/dev/bus/usb:/dev/bus/usb`.
3. **Shell Compatibility**:
   - Container scripts in `image/` (`entrypoint.sh`, `image/scripts/*.sh`, `image/scripts/lib/*.sh`) run in Alpine Linux under **POSIX `/bin/sh` (`ash`)**. Do **not** use Bash-only syntax (such as arrays `arr=()`, `[[ ... ]]`, `local`, or `${var,,}`) inside `image/`.
   - Host scripts in `utils/` and `tests/` use `#!/bin/bash` (except `utils/test_email.sh`, which remains POSIX `/bin/sh` for dual host/container execution).
4. **Modular Single-Responsibility Design**:
   - Avoid monolithic spaghetti scripts. Each script or module must own a single responsibility, encapsulate its helpers with clear English docblocks, and communicate via clean interfaces (library functions, CLI subcommands, environment variables, or UNIX pipes `stdin`/`stdout`).
5. **Open-Source Hygiene**:
   - Keep all code comments, logs, and documentation in English (localized strings belong strictly in `image/alerts/*.lang`).
   - Do not commit personal hardware models, personal brands, personal hostnames, or location-specific defaults (use neutral defaults like `TZ=UTC`, `UPS_NAME=ups`, `example.com`).

---

## 4. Running Tests

Before proposing or finalizing any code changes, run the automated test suite from the repository root:

```bash
./tests/run_tests.sh
```

All tests must pass with zero errors. When adding new features or fixing bugs, add corresponding test cases under `tests/`.
