# Vulcan - Production NixOS Configuration

A production-grade, modular NixOS configuration for self-hosted infrastructure running on Apple hardware using Asahi Linux. This configuration implements a comprehensive stack including web services, mail infrastructure, databases, monitoring, containerized applications, and multi-layer backup strategies.

## 🚀 Key Features

- **🏗️ Modular Architecture**: 237 well-organized module files across 13 category
  directories under `modules/` (count as of 2026-07-27)
- **📊 Full Observability**: Prometheus, Grafana, Alertmanager with custom exporters and alert rules
- **💾 Multi-Layer Backups**: ZFS snapshots + Restic cloud backups to Backblaze B2
- **🔐 Security First**: SOPS-nix secrets management, private CA (step-ca), security hardening
- **📧 Complete Mail Stack**: Postfix, Dovecot with FTS (Xapian), mbsync with Prometheus metrics
- **🐳 Container Orchestration**: Podman/Quadlet-based containers with proper networking
- **🏠 Home-Manager Integration**: Declarative user environment management
- **🍎 Apple Silicon Support**: Hardware-specific optimizations for Apple Silicon compatibility

## 📋 Table of Contents

- [Architecture](#architecture)
- [Infrastructure Components](#infrastructure-components)
- [Hardware & Platform](#hardware--platform)
- [Quick Start](#quick-start)
- [Management Commands](#management-commands)
- [Monitoring & Observability](#monitoring--observability)
- [Module Organization](#module-organization)
- [Secrets Management](#secrets-management)
- [Customization & Extension](#customization--extension)
- [State & Compatibility](#state--compatibility)
- [Contributing](#contributing)

## 🏛️ Architecture

This configuration follows a highly modular architecture, organizing system configuration into discrete, reusable modules by functional domain.

### Module Categories

| Category | Purpose | Key Modules |
|----------|---------|-------------|
| **Core** | System fundamentals | Boot (systemd-boot/EFI), networking, firewall, Nix config, systemd tuning — all in `modules/core/` (7 files; boot, firewall and `nix.settings` all live in `base.nix`) |
| **Services** | Application services | Web (Nginx), mail, databases, monitoring, DNS |
| **Storage** | Data management | ZFS configuration, snapshots, backups |
| **Containers** | Containerized apps | Podman/Quadlet setup, container services |
| **Security** | Security & secrets | Hardening, SOPS-nix, certificate management |
| **Users** | User management | User configs, home-manager integration |
| **Maintenance** | System maintenance | Timers, logwatch, automation |
| **Packages** | Custom packages | Shell configs, custom tools |

The table groups modules by role. On disk (2026-07-27) `modules/` holds **13**
directories — `containers core hardware lib maintenance monitoring options
packages security services storage test users` — and 237 `.nix` files; see
[Module Organization](#module-organization) for the real layout.

### Design Principles

1. **Separation of Concerns**: Each module has a single, well-defined responsibility
2. **Composability**: Modules can be easily added, removed, or replaced
3. **Reusability**: Common patterns extracted into library functions (e.g., `mkMbsyncModule`)
4. **Declarative**: Everything is version-controlled and reproducible
5. **Production-Ready**: Comprehensive monitoring, alerting, and disaster recovery

## 🏗️ Infrastructure Components

This is the main service catalog as actually deployed on `vulcan`. It is accurate
but not exhaustive — as of 2026-07-27 it omits, among others, memory-vault,
drafts-mcp, calendar-publisher, the rclone cloud-drive mirrors, NUT/UPS
monitoring, and the Hermes self-heal daemon. Each entry
notes the runtime model — **(native)** for native systemd services, **(Quadlet)**
for Podman containers managed by quadlet-nix (most of which now run *rootless*,
as per-user systemd units under a dedicated lingering service user declared in
`modules/users/home-manager/`; matter-server, wyoming-openai, BudgetBoard and the
Technitium exporter are still root-level system units), **(NixOS container)**
for `systemd-nspawn` / native NixOS containers, and **(microVM)** for hardware-isolated
guests. Internal services are reachable as `*.vulcan.lan` behind step-ca TLS;
external-facing services tunnel out via Cloudflare.

### Web & Reverse Proxy

- **Nginx** (native): central reverse proxy terminating step-ca TLS for ~40
  `*.vulcan.lan` virtual hosts; HTTP/2, HSTS, automatic HTTP → HTTPS redirect,
  per-upstream retry logic.
- **Cloudflared tunnels** (native): one persistent tunnel (`data`) whose ingress
  map (`modules/services/cloudflare-tunnels.nix:46-49`) exposes
  `data.newartisans.com` → `localhost:18080` (the static-nginx container, which
  serves `/tank/Public`), `gitea.newartisans.com` → Gitea,
  and `calendar.newartisans.com` → the
  Sacramento-cluster `.ics` publisher. Anything else through the tunnel gets a
  404.
- **Glance** (native): personal dashboard at `glance.vulcan.lan` with GitHub /
  RSS / weather widgets.
- **Static-nginx-container** (NixOS container): read-only static site declared as
  the `home.newartisans.com` vhost and served from `/tank/Public` (ZFS bind
  mount). The vhost is `default = true`, so it is also what the
  `data.newartisans.com` tunnel reaches on port 18080.

### Mail Stack

- **Postfix** (native): SMTP MTA with submission/TLS, milter integration to
  Rspamd, system-mail redirection.
- **Dovecot** (native): IMAP / POP3 with Xapian FTS, global Sieve filtering,
  `dovecot-archive` (auto-archive of stale Inbox / Spam mail), and
  `dovecot-imapsieve-monitor`.
- **Rspamd** (native): Lua-based spam filter with Redis backend, custom rules,
  `learn_spam` / `learn_ham` helpers, and a UI at `rspamd.vulcan.lan`.
- **Fetchmail** (native): pulls remote IMAP into Dovecot via LMTP to drive
  imapsieve learning; paired with `fetchmail-alerts`.
- **mbsync** (native): isync-based pull from Fastmail; `mkMbsyncModule` library
  abstracts per-account configuration; paired with `mbsync-alerts`.
- **Imapdedup** (native): scheduled doveadm-based mailbox deduplication.
- **Mailarchiver** (Quadlet): long-term mail archive web UI at
  `mailarchiver.vulcan.lan`.
- **email-tester-manual** (native): on-demand mail-pipeline tester (auto-runs
  disabled to avoid retraining Rspamd).

### Databases & Data Stores

- **PostgreSQL** (native): primary RDBMS backing Gitea, Home Assistant, Immich,
  OpenProject, Stock Trader, BudgetBoard, and others.
- **pgAdmin** (native): web admin UI at `postgres.vulcan.lan`.
- **Redis** (native, multi-instance): dedicated instances for Gitea, Rspamd,
  SearXNG, OpenProject, and Speedtest Tracker.
- **Qdrant** (native): vector database at `qdrant.vulcan.lan`; paired with
  `qdrant-inference-bridge` (translates Qdrant inference to OpenAI-compatible
  endpoints).
- **Mosquitto** (native): MQTT broker for Home Assistant and HASS.Agent.

### Monitoring, Logging & Alerting

- **Prometheus** (native): central metrics with auto-discovered alert rules
  from `modules/monitoring/alerts/`.
- **VictoriaMetrics** (native): long-term metrics storage at
  `victoriametrics.vulcan.lan`.
- **Alertmanager** (native): routes alerts via local Postfix; UI at
  `alertmanager.vulcan.lan`.
- **Grafana** (native): dashboards at `grafana.vulcan.lan` with prefetched
  community dashboards and a custom DNS-query-logs board.
- **Loki + Promtail** (native): log aggregation/shipping at `loki.vulcan.lan`
  and `promtail.vulcan.lan`.
- **Glances** (native): live system view at `glances.vulcan.lan`.
- **Blackbox monitoring** (native): HTTP / ICMP probes for local, DNS, and
  external host groups.
- **Prometheus exporters** (mostly native, some Quadlet): node (its `systemd`
  collector replaces a separate systemd exporter), zfs,
  postgres, redis, postfix, nginx, gitea, immich, node-red,
  vdirsyncer, qdrant, aria2, atd, restic, AIDE, ZFS pool health, certificate
  expiry, container health, HA backup freshness, stock-trader,
  git-workspace, OPNsense (Quadlet), Technitium DNS (Quadlet),
  copyparty, and remote-nodes.
- **opnsense-api-transformer** (Quadlet): Python proxy patching the OPNsense
  exporter's gateway-collector output.
- **service-reliability** (native): restart and back-off policies for critical
  services (databases, mail, monitoring).

### DNS, Networking & VPN

- **Technitium DNS Server** (native): authoritative + recursive DNS at
  `dns.vulcan.lan`; paired with `technitium-dns-backup` and a containerized
  exporter.
- **Avahi** (native): mDNS / zeroconf for local discovery.
- **OpenSSH** (native): with TCP keepalives and dedicated `gitea` host alias.
- **dirscan-share** + **dirscan-share-config** (native): scanned-document drop
  share with permission fix-ups.
- **home-assistant-metric-trick** (native): boot-time interface-metric swap so
  python-zeroconf binds to WiFi during HA startup.

### Authentication, PKI & Secrets

- **Step-CA** (native): private certificate authority issuing every `*.vulcan.lan`
  TLS cert (and SSH certificates).
- **certificate-automation** + **certificates** (native): renewal scripts and
  CA-trust-store integration so all system services trust the local CA.
- **SOPS-Nix** (native, activation-time): age-encrypted secrets decrypted into
  `/run/secrets/` at activation.
- **AIDE** (native, scheduled): file-system integrity baseline with both Prometheus
  and Prometheus integration.
- **Security hardening** (native): kernel sysctls, module blacklists (including
  AF_ALG to mitigate CVE-2026-31431), and systemd unit hardening.

### AI / LLM Services

- **Hermes Agent** (microVM): hardware-isolated AI-agent guest on its own bridge
  (`modules/services/hermes-microvm.nix` host side, `hermes-vm.nix` guest side).
  Outbound-only — no LAN-facing vhost; the guest reaches host loopback services
  through two-stage DNAT. Paired with `hermes-mcp`, `hermes-self-heal`, and a
  nightly health report.
- **Stock Trader** (native): hardened Python service at `trader.vulcan.lan`
  (Schwab OAuth-bootstrapped) pinned to a Gitea-hosted release tag.
- **model-config** (native): deploys `models.nix` as `/etc/models.json` for
  non-Nix consumers (CLI tools, scripts).

### Voice Assistant & Home Automation

- **Home Assistant** (native): full HA install at `hass.vulcan.lan` with a
  large `extraComponents` set (Yale, Tesla Wall Connector, BMW, Nest, Ring,
  LG ThinQ, HomeKit, Withings, Opower SMUD, MQTT, Cast, and more), including a
  patched `aiopnsense` for Python 3.13 compatibility.
- **Matter Server** (Quadlet): python-matter-server controller for HA's Matter
  integration.
- **wyoming-openai** (Quadlet): Wyoming STT bridge to the LLM
  `hera/cohere-transcribe-03-2026` route on loopback for the HA voice pipeline.
- **Mosquitto** (native, see above): MQTT broker for HA / HASS.Agent.
- **Node-RED** (native): flow-based automation at `nodered.vulcan.lan`.

### File Sharing, Storage & Media

- **Samba** (native): SMB / CIFS + NetBIOS + WSDD shares for ZFS datasets
  under `/tank`.
- **Copyparty** (NixOS container): multi-user file server bind-mounting ZFS
  datasets; reachable internally on `127.0.0.1:13923` (socket-activated proxy to
  the container). Its own config still sets `domain = data.newartisans.com`, but
  as of 2026-07-27 that tunnel hostname routes to the static-nginx container on
  18080 instead — see `modules/services/cloudflare-tunnels.nix:4-7`.
- **Immich** (native): photo / video library at `immich.vulcan.lan`.
- **Aria2** (native): download manager with the AriaNG UI at `aria.vulcan.lan`.
- **Jellyfin** (native, via `media.nix`): media server at `jellyfin.vulcan.lan`.
- **Speedtest Tracker** (Quadlet): historical speed-test tracking at
  `speedtracker.vulcan.lan` with Redis.
- **Zimit** (native): web-archive (ZIM) job-manager Flask UI.

### Productivity & Self-Hosted Apps

- **Gitea** (native): Git forge at `gitea.vulcan.lan` and
  `gitea.newartisans.com`, backed by Postgres + Redis.
- **gitea-actions-runner** (native): self-hosted CI runner.
- **github-gitea-mirror** (native): mirrors GitHub `jwiegley` → Gitea `johnw`
  every 8 h with a full sync at 03:00 daily.
- **OpenProject** (Quadlet): project-management platform at
  `openproject.vulcan.lan`.
- **Wallabag** (Quadlet): read-it-later / article archiving at
  `wallabag.vulcan.lan`.
- **BudgetBoard** (Quadlet pod): personal-finance app (C# server + React
  client) at `budget.vulcan.lan`.
- **ChangeDetection.io** (Quadlet): web-page change monitoring with
  sockpuppetbrowser at `changes.vulcan.lan`.
- **SearXNG** (native, via uwsgi): metasearch engine at `searxng.vulcan.lan`.
- **Vane** (Quadlet): AI / Perplexity-style search front-end at `vane.vulcan.lan`.
- **Radicale** (native): CalDAV / CardDAV server with git-backed collections
  at `radicale.vulcan.lan`.
- **vdirsyncer** (native): bidirectional Radicale ↔ Fastmail sync at
  `vdirsyncer.vulcan.lan`, paired with alerts.
- **atd web UI** (native): web front-end for `at`-job submission at
  `atd.vulcan.lan`, split across the `atd`, `atd-web`, and `atd-nginx` modules,
  with its own exporter and alert rules.

### Backup & Disaster Recovery

**ZFS Snapshots (Sanoid)**:
- `active` template: Hourly (24), Daily (7), Monthly (3)
- `archival` template: Hourly (24), Daily (30), Weekly (8), Monthly (12), Yearly (5)
- `production` template: Hourly (24), Daily (14), Weekly (4), Monthly (3)

**Restic Cloud Backups** (to Backblaze B2):
- Nine per-purpose filesets (`Audio Backups Databases Home Photos Public Video
  doc src`) with daily persistent timers, staggered 02:10–05:30, and
  7d / 5w / 12m / 3y retention.
- Status surfaced through a Prometheus textfile collector.
- Helper script: `restic-operations`, with two subcommands — `check` (unlock,
  check, prune, `repair snapshots` per fileset) and `snapshots`. It is not
  installed on `PATH`; it runs from the weekly `restic-check.service` and from
  the logwatch `restic` report.

**Other backup services**:
- **local-backup** (native): restic-driven local backups for selected directory
  sets, independent of cloud copies.
- **postgresql-backup** (native): daily `pg_dump` at 02:00 to
  `/tank/Backups/PostgreSQL/`.
- **technitium-dns-backup** (native): scheduled Technitium DNS configuration
  snapshot.
- **backup-monitoring** (native): restart / back-off policies and failure
  notifications layered over every restic unit.
- **HA backup freshness exporter** (native): tracks Home Assistant backup age
  and size for alerting.

### Maintenance & Reliability

- **maintenance/timers** (native): `git-workspace-archive` and
  `update-containers` systemd timers.
- **cleanup** (native): dirscan-driven systemd cleanup tasks.
- **service-reliability** (native, see above): centralised restart policies.
- **hd-idle** (native): spin-down for non-system disks.
- **ZFS** (native): pool management with 16 K page size for Apple Silicon
  and an ARC limit of 16 GiB.
- **podman autoPrune** (native): weekly (`podman-prune.timer`, Mondays)
  container/image cleanup of the *root* podman store; rootless per-user stores
  are pruned separately by `rootless-podman-image-prune.nix`.
- **container-health-exporter** (native): per-container liveness metrics for
  Prometheus.

## 🖥️ Hardware & Platform

### System Specifications

- **Platform**: Apple Hardware (aarch64-linux)
- **RAM**: 64GB installed / ~62 GiB usable (ZFS ARC: 16 GiB max, 2 GiB min —
  `modules/storage/zfs.nix:39-40`)
- **Storage**:
  - root filesystem: **ext4** (`hosts/vulcan/hardware-configuration.nix`)
  - `tank`: the only ZFS pool — all data storage, snapshots and shares
- **Network**: NetworkManager with static hostname
- **External Storage**: USB-C device auto-enrollment; `tank` itself lives in an
  external USB enclosure driven over BOT/usb-storage (UAS disabled)

### Hardware Configuration

- **Boot**: systemd-boot with EFI support (`modules/core/base.nix:18-22`,
  `configurationLimit = 10`)
  - ZFS ARC tuning for 64GB RAM
- **Initrd modules**: `xhci_pci`, `usbhid`, `usb_storage`, `sdhci_pci`
  (`hosts/vulcan/hardware-configuration.nix:21-26`)

## 🚀 Quick Start

### Prerequisites

1. NixOS installed on Apple hardware
2. Age/PGP keys for SOPS secrets decryption
3. Access to Backblaze B2 for backups (optional)

### Initial Setup

```bash
# Clone the repository
git clone <repository-url> /etc/nixos
cd /etc/nixos

# Configure your secrets (copy and edit)
# Set up SOPS keys and decrypt secrets
# See "Secrets Management" section below

# Update flake inputs
nix flake update

# Build and switch to new configuration
sudo nixos-rebuild switch --flake .#vulcan
```

### Testing Changes

```bash
# Build without switching (test for errors)
sudo nixos-rebuild build --flake .#vulcan

# Test in a VM (requires virtualization support)
sudo nixos-rebuild build-vm --flake .#vulcan
```

## 🛠️ Management Commands

### System Management

```bash
# Build and activate new configuration
sudo nixos-rebuild switch --flake .#vulcan

# Just build without switching
sudo nixos-rebuild build --flake .#vulcan

# Test configuration in a VM
sudo nixos-rebuild build-vm --flake .#vulcan

# Update flake inputs
nix flake update

# Format Nix files (formatter = nixfmt-tree, i.e. treefmt driving nixfmt-rfc-style)
nix fmt
```

### Maintenance Commands

```bash
# Check Nix store integrity
nix-store --verify --check-contents

# Garbage collect old generations
sudo nix-collect-garbage -d

# Delete generations older than 30 days
sudo nix-collect-garbage --delete-older-than 30d

# Optimize Nix store (deduplicate)
nix-store --optimise
```

### Certificate Authority (step-ca)

```bash
# Check step-ca service status
sudo systemctl status step-ca
sudo journalctl -u step-ca -f  # Follow logs

# Generate a new certificate
# (for service certs prefer the wrapper: sudo /etc/nixos/certs/renew-certificate.sh)
step ca certificate "service.vulcan.lan" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt

# Renew a certificate
step ca renew service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt

# Export root CA for client installation
sudo cp /var/lib/step-ca-state/certs/root_ca.crt ~/vulcan-ca.crt
# (a checked-in copy also lives at /etc/nixos/certs/vulcan-root-ca.crt)
```

### Dovecot Full-Text Search (FTS)

```bash
# Index all mailboxes for a user (initial setup)
doveadm index -u johnw '*'
doveadm index -u assembly '*'

# Index a specific mailbox
doveadm index -u johnw INBOX

# Optimize FTS indexes (reduce size, improve performance)
doveadm fts optimize -u johnw
doveadm fts optimize -u assembly

# Rescan and rebuild FTS index (if corrupted)
doveadm fts rescan -u johnw
doveadm index -u johnw '*'

# Test FTS search functionality
doveadm search -u johnw body "search term"

# Check mailbox statistics including FTS index size
doveadm mailbox status -u johnw all '*'
```

### Backup Operations

```bash
# Check all backup filesets (weekly timer; run it by hand with systemctl)
sudo systemctl start restic-check.service

# Per-fileset wrappers that ARE on PATH — one per fileset, capitalisation matters:
#   restic-Audio restic-Backups restic-Databases restic-doc restic-Home
#   restic-Photos restic-Public restic-src restic-Video
restic-Home snapshots
restic-doc check
restic-src stats

# Run one fileset's backup now
sudo systemctl start restic-backups-Home.service
```

### Container Management

```bash
# Interactive container management
lazydocker  # TUI for Docker/Podman
podman-tui  # Alternative Podman TUI

# List root-level containers (budget-board-*, matter-server, wyoming-openai,
# technitium-dns-exporter). Most app containers are rootless and belong to a
# per-service user, so they do NOT show up here.
sudo podman ps

# Root-level container units are plain systemd services
journalctl -u matter-server -f
sudo systemctl restart matter-server

# Rootless Home-Manager containers (open-webui, wallabag,
# wallabag, vane, …) run as *user* units under a lingering service user:
journalctl _SYSTEMD_USER_UNIT=wallabag.service -f
sudo -u wallabag XDG_RUNTIME_DIR=/run/user/$(id -u wallabag) \
  systemctl --user restart wallabag
```

### ZFS Management

```bash
# Check pool status
zpool status

# List ZFS filesystems and snapshots
zfs list -t all

# Recent snapshots per filesystem: `logwatch-zfs-snapshot` is NOT on PATH —
# it exists only as a logwatch report script (modules/services/monitoring.nix:19).
zfs list -t snapshot -o name,creation -s creation | tail -40
```

## 📊 Monitoring & Observability

### Prometheus Exporters

| Exporter | Port | Metrics |
|----------|------|---------|
| Node | 9100 | CPU, memory, disk, network, hwmon, systemd (`node_systemd_*`) |
| PostgreSQL | 9187 | Database stats, connections, queries |
| Postfix | 9154 | Mail queue, delivery stats |
| ZFS | 9134 | Pool health, dataset usage, I/O |
| Restic | Textfile | Backup status, snapshot counts |
| mbsync | Textfile | Sync status, message counts |

There is **no** separate systemd exporter on 9558: node-exporter's `systemd`
collector supersedes it (`modules/monitoring/services/system-exporters.nix:22`).
The table above is a sample — the full exporter set is much larger (see the
Monitoring entries in the service catalog).

### Alert Rules

Located in `modules/monitoring/alerts/` — **51** rule files as of 2026-07-27,
auto-discovered with `builtins.readDir`
(`modules/monitoring/services/alerting.nix`). A representative handful:

- **system.yaml**: CPU, memory, disk alerts
- **systemd.yaml**: Service failures, restarts
- **database.yaml**: PostgreSQL connection and performance
- **storage.yaml**: ZFS pool health, disk space
- **certificates.yaml**: Certificate expiration warnings
- **network.yaml**: Network connectivity and performance

Two sibling directories hold rules that are wired differently:
`modules/monitoring/vm-alerts/` (3 files, also auto-discovered, evaluated by
vmalert against VictoriaMetrics) and `modules/monitoring/loki-rules/` (10 files
that are **not** auto-discovered — each needs a hand-written `L+` tmpfiles
symlink in `modules/services/loki.nix`).

### Grafana Dashboards

Access Grafana for visualization:
- URL: `https://grafana.vulcan.lan`
- 7 prefetched community dashboards (node-exporter ×2, PostgreSQL,
  Loki/Promtail, logs-app, Immich, Qdrant) plus 10 local ones from
  `modules/monitoring/dashboards/`,
  `modules/monitoring/grafana-dashboards/` and
  `modules/storage/dns-query-logs-dashboard.json`
- All are hand-listed in `modules/services/grafana.nix` and copied into
  `/var/lib/grafana/dashboards/` — a new JSON file is not picked up until it is
  added there

### Logwatch Reports

Daily email reports include:

- Failed systemctl services
- SSH authentication attempts
- Sudo usage
- Kernel messages
- Audit logs
- ZFS pool status
- Restic backup snapshots
- ZFS snapshots overview
- Certificate validation report

## 📁 Module Organization

### Directory Structure

Two levels deep, as of 2026-07-27 (per-directory `.nix` counts in parentheses):

```
/etc/nixos/
├── flake.nix                      # Flake definition and 23 inputs
├── models.nix                     # Central LLM model registry (→ /etc/models.json)
├── hosts/
│   └── vulcan/
│       ├── default.nix            # The single host module — every import lives here
│       └── hardware-configuration.nix
├── modules/                       # 237 .nix in 13 category directories
│   ├── core/          (7)         # base.nix (systemd-boot, firewall, nix.settings),
│   │                              #   networking, system, programs, crash-debug,
│   │                              #   memory-limits, wifi
│   ├── services/     (92)         # web.nix, dovecot.nix, postfix.nix, mbsync.nix,
│   │                              #   databases.nix, certificates.nix, monitoring.nix,
│   │                              #   grafana.nix, *-microvm.nix / *-vm.nix, …
│   ├── monitoring/   (72)         # services/ (68, incl. a default.nix aggregator),
│   │                              #   alerts/ (51 Prometheus rule YAMLs),
│   │                              #   loki-rules/ (10), vm-alerts/ (3),
│   │                              #   dashboards/, grafana-dashboards/,
│   ├── users/        (25)         # johnw, assembly, bia, nasimw, rbcca,
│   │                              #   container-users-dedicated, home-manager/ (19)
│   ├── containers/   (22)         # quadlet.nix, copyparty-container.nix,
│   │                              #   static-nginx-container.nix, *-quadlet.nix —
│   │                              #   most -quadlet.nix files now hold only nginx /
│   │                              #   SOPS / redis config; the containers themselves
│   │                              #   moved to users/home-manager/
│   ├── lib/           (6)         # bindTankModule, common, mkMbsyncModule,
│   │                              #   mkPostgresUserSetup, mkQuadletService,
│   │                              #   resticOperations (+ README.md)
│   ├── storage/       (4)         # zfs.nix, backups.nix, backup-monitoring.nix,
│   │                              #   hd-idle.nix
│   ├── security/      (3)         # hardening.nix, aide.nix, root-ssh-gitea.nix
│   ├── packages/      (2)         # custom.nix, zsh.nix
│   ├── hardware/      (1)         # wifi-stability.nix
│   ├── maintenance/   (1)         # timers.nix
│   ├── options/       (1)         # default.nix — declares options.vulcan.*; no
│   │                              #   module outside this file reads them, but its
│   │                              #   own config block sets Prometheus retention /
│   │                              #   scrape interval and the restic keep-* counts
│   └── test/          (1)         # sops-ownership-test.nix (imported by nothing)
├── overlays/         (22)         # package overrides (default.nix + leaf overlays)
├── pkgs/                          # custom derivations (stock-trader, hermes-mcp, …)
├── tests/                         # checks.nix, wired from flake.nix
├── certs/                         # certificate scripts + CERTIFICATES.md
├── scripts/                       # helper scripts (Python/shell) used by modules
├── config/ · files/ · templates/  # static config/data shipped by modules
├── docs/                          # 90 .md files (47 top-level) + ports.txt registry
├── CLAUDE.md · SECURITY.md
└── (separate, gitignored git repos consumed as flake inputs)
    ├── secrets/secrets.yaml       # SOPS-encrypted secrets  (input `secrets`)
    └── firmware/                  # Apple firmware blobs    (input `firmware`)
```

Note: there is **no** `configuration.nix` and **no** `/etc/nixos/secrets.yaml` —
the host config is `hosts/vulcan/default.nix` and the encrypted secrets live in
the separate `secrets/` repo.

### Adding New Modules

1. Create module file in appropriate category directory
2. Import in `hosts/vulcan/default.nix`
3. Follow existing patterns for consistency
4. Test with `nixos-rebuild build`

Example module structure:

```nix
{ config, lib, pkgs, ... }:

{
  # Service configuration
  services.myservice = {
    enable = true;
    # ... configuration options
  };

  # Networking/firewall if needed
  networking.firewall.allowedTCPPorts = [ 1234 ];

  # Systemd services if needed
  systemd.services.myservice-helper = {
    # ... service definition
  };

  # Packages
  environment.systemPackages = with pkgs; [
    # ... packages
  ];
}
```

## 🔐 Secrets Management

This configuration uses **SOPS-nix** for managing secrets securely in git.

### How It Works

1. Secrets are encrypted with Age/PGP keys
2. The encrypted store is `secrets/secrets.yaml` — a **separate** git repo at
   `/etc/nixos/secrets/`, consumed as the `secrets` flake input
   (the `secrets` input in `flake.nix`, `flake = false`) and excluded from this
   repo by `.gitignore`. `sops.defaultSopsFile` in `modules/core/system.nix`
   points at it. There is no `/etc/nixos/secrets.yaml`.
3. At activation, secrets are decrypted and placed in `/run/secrets/`
   (per-user drops land in `/run/secrets-<user>/`)
4. Services reference secrets via SOPS paths

### Secret Configuration

**Never decrypt or expose secrets in plain text!**

Secrets are referenced in modules like this:

```nix
services.step-ca = {
  intermediatePasswordFile = config.sops.secrets."step-ca-password".path;
};

services.restic.backups.home = {
  passwordFile = "/run/secrets/restic-password";
  environmentFile = "/run/secrets/aws-keys";
};
```

### Adding New Secrets

1. Edit the store with `sops secrets/secrets.yaml`, then **commit it in the
   `secrets` repo and re-lock the flake input** — an uncommitted edit has no
   effect on the build
2. Add secret reference in module:
   ```nix
   sops.secrets."my-new-secret" = {
     owner = "service-user";
     group = "service-group";
     mode = "0400";
   };
   ```
3. Reference in service: `config.sops.secrets."my-new-secret".path`

### Required Secrets

The following secrets are used (see `secrets/secrets.yaml`, or `ls /run/secrets/`,
for the complete list — 133 `sops.secrets` entries are declared):

- `step-ca-password`: CA intermediate key password
- `restic-password`: Restic backup encryption password
- `aws-keys`: Backblaze B2 credentials
- `johnw-fastmail-password`: Mail account password
- `carmichael-imap-gmail-com`: Gmail app password
- Database passwords
- API keys and tokens

## 🎨 Customization & Extension

### Reusable Patterns

#### mkMbsyncModule Library

Create reusable mbsync configurations:

```nix
let
  mkMbsyncLib = import ../lib/mkMbsyncModule.nix { inherit config lib pkgs; };
  inherit (mkMbsyncLib) mkMbsyncService;
in
{
  imports = [
    (mkMbsyncService {
      name = "myaccount";
      user = "myuser";
      group = "mygroup";
      secretName = "my-imap-password";
      remoteConfig = ''
        Host imap.example.com
        User myuser@example.com
        PassCmd "cat /run/secrets/my-imap-password"
        # ... more config
      '';
      channels = ''
        # ... channel config
      '';
      timerInterval = "15min";
    })
  ];
}
```

#### Custom Service Patterns

Many services follow similar patterns:

1. **Service configuration**: Main service setup
2. **Secrets integration**: SOPS secret references
3. **Monitoring**: Prometheus exporter
4. **Alerts**: Alert rules in `modules/monitoring/alerts/`
5. **Backup**: Include in Restic backups if needed

### Flake Inputs & Overlays

Flake inputs (see `flake.nix` for current pin rationales):

- `nixpkgs`: `nixos-25.11` — stable NixOS module graph and core operating system
- `nixpkgs-user`: follows `nix-config-ai/nixpkgs` — Hera-aligned Home Manager and standalone app packages
- `nixpkgs-unstable`: pinned to rev `241313f4` (2026-07-19) for
  Home Assistant and other packages needing newer versions
- `nixos-apple-silicon`: Apple hardware support (pinned for ZFS/kernel compat)
- `home-manager`: `release-25.11` system module, using `nixpkgs-user` for user environments
- `sops-nix`: Secrets management
- `nixos-logwatch`: Log monitoring
- `quadlet-nix`: Podman container integration
- `microvm`: the Hermes microVM
- `hermes-agent`: Hermes agent source (pinned to rev `c47b9d12`; the `hermes-agent`
  input in `flake.nix` carries the reason)
- `nix-config-ai`, `nix-config`, `llm-agents`: shared AI / home-manager config; normal `./build` refreshes
  both shared source inputs and the top-level `pi` source before evaluation
- `stock-trader`: pinned to Gitea tag `v0.2.0` (`flake = false`)
- `git-scripts`, `org-jw`, `una`, `sizes`, `pushme`,
  `sacramento-cluster-ics`: personal tooling and data repos
- `secrets`, `firmware`: local, gitignored data repos
  (`git+file:///etc/nixos/...`, all `flake = false`)

Add new inputs in `flake.nix`:

```nix
inputs = {
  my-input.url = "github:user/repo";
};

outputs = { nixpkgs, my-input, ... }: {
  nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
    modules = [
      my-input.nixosModules.default
      # ...
    ];
  };
};
```

## 📌 State & Compatibility

### NixOS State Version

```nix
system.stateVersion = "25.11";
```

**⚠️ Important**: This value determines compatibility for stateful data. Do not change unless migrating the system. See [NixOS Manual](https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion) for details.

### Channel & Version

- **NixOS Version**: 25.11
- **Core nixpkgs Channel**: `nixos-25.11`; `nixpkgs-user` follows the portable AI input
  for the same user-package line as Hera. `nixpkgs-unstable` remains a separately pinned
  compatibility input for select packages.
- **System Architecture**: aarch64-linux

### Flake Lock

The `flake.lock` file records the resolution used by an invocation. Normal `./build` refreshes
`nix-config`, `nix-config-ai`, and `pi` while holding the build lock, then evaluates the result;
do not bypass the driver for a normal system build. The stable core `nixpkgs` input remains
deliberately unchanged by that refresh.

## 🤝 Contributing

### Code Style

- **Formatting**: Use `nix fmt` (`nixfmt-tree`, which runs nixfmt-rfc-style)
- **Indentation**: 2 spaces
- **Line Length**: Keep reasonable (80-100 chars when possible)
- **Comments**: Document complex logic and design decisions

### Module Guidelines

1. **Single Responsibility**: Each module should have one clear purpose
2. **Minimal Dependencies**: Avoid unnecessary inter-module dependencies
3. **Reusability**: Extract common patterns to `lib/`
4. **Documentation**: Add comments for non-obvious configurations
5. **Testing**: Test changes with `nixos-rebuild build` before committing

### Commit Messages

Follow conventional commits:

- `feat: Add new service module`
- `fix: Correct Dovecot FTS configuration`
- `refactor: Extract mbsync to library function`
- `docs: Update README with backup procedures`
- `chore: Update flake inputs`

### Development Workflow

1. Create a feature branch
2. Make changes in appropriate module
3. Test with `sudo nixos-rebuild build --flake .#vulcan`
4. Test in VM if possible: `sudo nixos-rebuild build-vm --flake .#vulcan`
5. Format code: `nix fmt`
6. Commit with clear message
7. Submit pull request (if applicable)

### Debugging

```bash
# Check Nix evaluation without building.
# NOTE (checked 2026-07-27): this currently FAILS on vulcan, and the failure is
# not in this repo — home-manager's johnw profile pulls in the external
# nix-config overlay `overlays/30-text-tools.nix`, whose `org2tc ? null` lambda
# rejects the `system` argument. Treat a failure here as "look at the trace"
# rather than "the module set is broken".
nix eval .#nixosConfigurations.vulcan.config.system.build.toplevel.drvPath

# Show full build log
sudo nixos-rebuild switch --flake .#vulcan --show-trace

# Inspect a single evaluated option
nix eval .#nixosConfigurations.vulcan.config.system.stateVersion
```

## 📚 Additional Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Nix Flakes Guide](https://nixos.wiki/wiki/Flakes)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [SOPS-nix Documentation](https://github.com/Mic92/sops-nix)
- [nixos-hardware](https://github.com/NixOS/nixos-hardware)

## 📄 License

This configuration is for personal use. Adapt and modify as needed for your own infrastructure.

---

**System**: Vulcan • **Platform**: Apple Silicon (aarch64-linux, Asahi) • **NixOS**: 25.11
