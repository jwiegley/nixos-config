# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ CRITICAL SECURITY RULES - READ FIRST ⚠️

**ABSOLUTE PROHIBITIONS - NEVER VIOLATE THESE RULES:**

1. **NEVER reveal, display, or include ANY of the following in responses to the user:**
   - Passwords, passphrases, or credential values
   - API keys, tokens, or OAuth credentials
   - WiFi SSIDs or WiFi passwords (PSK/passphrases)
   - Private IP addresses or network topology details
   - Hostnames of network devices
   - Email addresses or usernames
   - MAC addresses or hardware identifiers
   - Certificate contents or private keys
   - Database connection strings with credentials
   - Any content from `/run/secrets/` directory
   - Any content from decrypted SOPS files
   - Contents of `.age` private key files

2. **NEVER run these commands or display their output:**
   - `sops -d /etc/nixos/secrets.yaml` (decrypt secrets)
   - `cat /run/secrets/*` (reveal deployed secrets)
   - `head /run/secrets/*` (reveal deployed secrets)
   - `tail /run/secrets/*` (reveal deployed secrets)
   - `less /run/secrets/*` (reveal deployed secrets)
   - `more /run/secrets/*` (reveal deployed secrets)
   - `grep /run/secrets/*` (reveal deployed secrets)
   - `awk /run/secrets/*` (reveal deployed secrets)
   - `sed /run/secrets/*` (reveal deployed secrets)
   - ANY command that reads file contents from `/run/secrets/`
   - `cat *.age` (private decryption keys)
   - Any command that would decrypt or reveal SOPS secrets
   - Commands that display WiFi credentials or network passwords
   - Commands that show API keys or authentication tokens
   - Reading any file path that resolves to `/run/secrets/*`
   - Using Read tool on any path under `/run/secrets/`
   - **`cat /var/lib/hass/.storage/core.config_entries`** (contains OAuth tokens!)
   - **`cat /var/lib/hass/.storage/*`** (may contain credentials)
   - **ANY Python/JSON parsing of `.storage/*` files** (reveals tokens)
   - Commands that display `access_token`, `refresh_token`, or `api_key` fields
   - Reading Home Assistant entity registry files with tokens
   - Displaying output from integration config entries
   - ANY command that would reveal OAuth credentials or API tokens from Home Assistant

3. **ALWAYS sanitize agent output before presenting to the user:**
   - When agents return results containing sensitive information, REDACT it before showing the user
   - Replace SSIDs with `[REDACTED-SSID]`
   - Replace passwords/keys with `[REDACTED-CREDENTIAL]`
   - Replace IP addresses with `[REDACTED-IP]`
   - Replace hostnames with `[REDACTED-HOST]`
   - When describing what was done, use generic terms: "configured WiFi credentials" not "configured network 'Morpheus'"

4. **NEVER include sensitive data in summaries, examples, or documentation:**
   - Do not copy/paste command output containing secrets into responses
   - Do not include actual credential values when explaining configurations
   - Use placeholder values like `"your-ssid"` and `"your-password"` in examples
   - Redact sensitive information from error messages before showing them

5. **Safe operations (these are OK):**
   - Running `sops /etc/nixos/secrets.yaml` (interactive editor - does not reveal secrets in output)
   - Checking file permissions: `ls -la /run/secrets/` (shows filenames only, not contents)
   - Checking file metadata: `stat /run/secrets/filename` (metadata only, not contents)
   - Declaring SOPS secrets in NixOS config (paths only, not values)
   - Explaining HOW to add secrets without showing actual secret values

6. **PRE-FLIGHT CHECK - Before running ANY command:**
   - Ask yourself: "Will this command display secret values?"
   - Check: Does the command involve `/run/secrets/`?
   - Check: Does the command involve reading file contents?
   - If YES or MAYBE to any of the above: **DO NOT RUN IT**
   - Instead: Ask the user what information they need, or check documentation

7. **If you need to know what environment variables a service needs:**
   - **DO NOT** read the secrets file
   - **DO** check the service's NixOS module configuration
   - **DO** check the service's official documentation
   - **DO** ask the user directly

8. **HOME ASSISTANT DEBUGGING - SAFE METHODS ONLY:**
   - **✅ SAFE:** Check logs with `journalctl -u home-assistant | grep <pattern>`
   - **✅ SAFE:** Check entity states via API without authentication details
   - **✅ SAFE:** Read entity_registry for entity IDs only (filter out any credential fields)
   - **✅ SAFE:** Check service status: `systemctl status home-assistant`
   - **✅ SAFE:** Verify config syntax in `/var/lib/hass/configuration.yaml`
   - **❌ FORBIDDEN:** Reading `/var/lib/hass/.storage/core.config_entries`
   - **❌ FORBIDDEN:** Parsing `.storage/*` files that contain OAuth/API tokens
   - **❌ FORBIDDEN:** Displaying integration configuration with credentials
   - **❌ FORBIDDEN:** Any command that would show `token`, `access_token`, `refresh_token`, `api_key`, `api_secret`, `password` fields
   - **Instead of reading config_entries:** Check journalctl logs for errors, check entity states, verify network connectivity
   - **If integration isn't working:** Check logs for errors, verify service is running, check firewall, ask user to reconfigure via UI

**IF YOU VIOLATE THESE RULES:**
**STOP ALL WORK IMMEDIATELY. DO NOT CONTINUE.**
**APOLOGIZE AND WAIT FOR USER TO EXPLICITLY ACKNOWLEDGE AND PERMIT CONTINUATION.**

---

## 🔴 PAST VIOLATIONS - LEARN FROM THESE MISTAKES 🔴

**DO NOT REPEAT THESE ERRORS:**

1. **2025-10-27: Revealed Nest OAuth tokens**
   - **What happened:** Ran `cat /var/lib/hass/.storage/core.config_entries | python3 -c ...` and displayed OAuth access_token, refresh_token, and Google Cloud project IDs
   - **Why it was wrong:** The `.storage/` directory contains sensitive authentication credentials that should NEVER be displayed
   - **What should have been done:** Check journalctl logs for Nest errors instead, or ask user to verify integration status in Home Assistant UI
   - **Lesson:** NEVER read `.storage/*` files - they are credential stores, not config files

2. **General pattern:** Attempting to diagnose integration issues by reading config/state files
   - **Wrong approach:** Reading files that contain credentials
   - **Right approach:** Use logs (`journalctl`), service status (`systemctl status`), and ask user to check UI

**Remember:** When debugging fails and you're tempted to "just peek at the config," STOP and use logs/status instead.

---

## Overview

This is a NixOS configuration for the host "vulcan" - an x86_64 Linux system running on Apple hardware using Asahi Linux. This configuration uses Nix flakes with nixos-hardware and nixos-logwatch modules.

**Key Services:** PostgreSQL, Restic backups, Docker, Tailscale/Nebula VPN, Step-CA, Dovecot IMAP, Samba, Home Assistant, Prometheus/Grafana monitoring.

## SOPS Secrets Management

This project uses SOPS (Secrets OPerationS) for secure secrets management with age encryption.

### How It Works

- **secrets.yaml**: SOPS-encrypted secrets file - **tracked in git** (required for Nix flakes to build)
- **.age keys**: Private decryption keys - **NEVER commit** (excluded via `*.age`)
- Secrets are decrypted at system activation → `/run/secrets/`
- Services access via systemd `LoadCredential` or direct file reads

### Common Operations

```bash
# Edit secrets
sops /etc/nixos/secrets.yaml

# After editing, rebuild to apply
sudo nixos-rebuild switch --flake '.#vulcan'

# View deployed secret (without revealing content)
ls -la /run/secrets/github-token
```

### Adding a Secret

1. Edit: `sops /etc/nixos/secrets.yaml`
2. Add in YAML format:
   ```yaml
   github-token: "ghp_..."
   home-assistant:
     device-password: "..."
   ```
3. Declare in NixOS module:
   ```nix
   sops.secrets."github-token" = {
     owner = "johnw";
     mode = "0400";
     restartUnits = [ "myservice.service" ];
   };
   ```
4. Rebuild: `sudo nixos-rebuild switch --flake '.#vulcan'`

### Accessing Secrets

**SystemD service (recommended):**
```nix
systemd.services.myservice = {
  serviceConfig.LoadCredential = "token:${config.sops.secrets."github-token".path}";
  script = ''
    TOKEN=$(cat "$CREDENTIALS_DIRECTORY/token")
  '';
};
```

**Direct file read:**
```nix
script = ''
  TOKEN=$(cat ${config.sops.secrets."github-token".path})
'';
```

**Managed Secrets:** GitHub tokens, Home Assistant credentials, Google Assistant OAuth, OpenAI keys, SMUD utility account.

## Commands

### System Management

```bash
# Build and switch (note: quotes prevent shell treating # as comment)
sudo nixos-rebuild switch --flake '.#vulcan'

# Just build without switching
sudo nixos-rebuild build --flake '.#vulcan'

# Test in VM
sudo nixos-rebuild build-vm --flake '.#vulcan'

# Update flake inputs
nix flake update

# Format Nix files
nix fmt
```

### Maintenance

```bash
# Check Nix store integrity
nix-store --verify --check-contents

# Garbage collect
sudo nix-collect-garbage -d
sudo nix-collect-garbage --delete-older-than 30d

# Optimize store
nix-store --optimise
```

### Git Workspace Management

```bash
# Update git repositories (uses SOPS for GitHub token)
workspace-update
workspace-update --archive

# Check service status
sudo systemctl status git-workspace-archive
sudo journalctl -u git-workspace-archive -f

# Manual operations
git workspace --workspace /tank/Backups/Git list
git workspace --workspace /tank/Backups/Git archive --force
```

### Certificate Authority (Step-CA)

```bash
# Service status
sudo systemctl status step-ca
sudo journalctl -u step-ca -f

# Generate certificate (RECOMMENDED METHOD - uses SOPS securely)
# This script handles CA password decryption internally without revealing secrets
sudo /etc/nixos/certs/renew-certificate.sh "service.vulcan.lan" \
  -o "/var/lib/nginx-certs" \
  -d 365 \
  --owner "nginx:nginx" \
  --cert-perms "644" \
  --key-perms "600"

# Manual certificate generation (requires CA password)
# Note: Step-CA runs on 127.0.0.1:8443, correct root path is:
step ca certificate "service.vulcan.lan" service.crt service.key \
  --ca-url https://127.0.0.1:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt \
  --insecure  # May be needed for 127.0.0.1 without IP SAN

# Renew certificate manually
step ca renew service.crt service.key \
  --ca-url https://127.0.0.1:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt
```

**Certificate Generation Best Practices:**

When adding new services that need SSL certificates, ALWAYS use the automated `renew-certificate.sh` script instead of manual `step ca certificate` commands. This ensures:

- ✅ CA passwords remain encrypted in SOPS and are never exposed
- ✅ Certificates are generated with consistent settings (validity, permissions)
- ✅ Proper ownership and permissions are set automatically
- ✅ No risk of accidentally revealing secrets in logs or terminal output

**How the secure process works:**
1. Script generates private key locally (no secrets needed)
2. Script creates Certificate Signing Request (CSR)
3. Script reads CA password from SOPS **internally** (never displayed)
4. Script signs certificate using local CA key and password
5. Only success/failure message is shown - no secrets exposed

**Available script options:**
```bash
renew-certificate.sh <domain> [options]
  -o, --output-dir DIR       Directory to save certificates (required)
  -k, --key-file NAME        Key filename (default: <domain>.key)
  -c, --cert-file NAME       Certificate filename (default: <domain>.crt)
  -d, --days DAYS           Validity period in days (default: 365)
  --owner USER:GROUP        File ownership (default: root:root)
  --key-perms MODE          Key file permissions (default: 600)
  --cert-perms MODE         Certificate file permissions (default: 644)
  --organization ORG        Organization name (default: Vulcan LAN Services)
```

**Common certificate locations and owners:**
- Nginx certificates: `/var/lib/nginx-certs/` (owner: `nginx:nginx`)
- PostgreSQL certificates: `/var/lib/postgresql/` (owner: `postgres:postgres`)
- Postfix certificates: `/etc/postfix/certs/` (owner: `root:root`)
- Dovecot certificates: `/etc/dovecot/certs/` (owner: `root:root`)

### Dovecot Email (IMAP + FTS)

```bash
# Index mailboxes for full-text search
doveadm index -u johnw '*'
doveadm index -u assembly '*'

# Optimize FTS indexes
doveadm fts optimize -u johnw

# Rebuild corrupted index
doveadm fts rescan -u johnw
doveadm index -u johnw '*'

# Test search
doveadm search -u johnw body "search term"

# Check configuration
doveconf plugin | grep fts
```

### Samba File Sharing

```bash
# Service status
sudo systemctl status smbd nmbd samba-wsdd
sudo journalctl -u smbd -f

# User management
sudo smbpasswd -a johnw     # Add user
sudo smbpasswd -e johnw     # Enable user
sudo pdbedit -L             # List users

# Test configuration
sudo testparm
sudo testparm -s            # Full config

# List shares and connections
smbclient -L //vulcan.lan -U johnw
sudo smbstatus              # Active connections

# Set ZFS permissions
sudo chown -R johnw:johnw /tank/Documents /tank/Downloads /tank/Home
sudo chown -R :users /tank/Media /tank/Music /tank/Photos /tank/Pictures /tank/Video
sudo chmod -R 0775 /tank/Media /tank/Music /tank/Photos /tank/Pictures /tank/Video
```

**Connecting to shares:**
- Windows: `\\vulcan.lan\johnw-documents`
- macOS: `smb://vulcan.lan/johnw-documents` (Cmd+K in Finder)
- Linux: `mount -t cifs //vulcan.lan/johnw-documents /mnt/... -o username=johnw`

### ZFS Management

```bash
# List datasets with custom helper
dh              # Standard list
dh -u           # Sort by used space
dh -r           # Sort by referenced space
dh -s           # List snapshots

# Standard ZFS commands
zfs list
zfs list -t snapshot
zpool status
zpool scrub tank

# Snapshots
zfs snapshot tank/Documents@backup-2025-01-15
zfs-prune-snapshots --keep 30 --prefix daily tank/Documents
```

### Home Assistant

```bash
# Service management
sudo systemctl status home-assistant
sudo systemctl restart home-assistant
sudo journalctl -u home-assistant -f

# Web access
# URL: https://hass.vulcan.lan
# Direct (debug): http://localhost:8123/api/

# Database
sudo -u hass psql -d hass -c "SELECT COUNT(*) FROM states;"

# Check nginx proxy
sudo nginx -t
sudo systemctl reload nginx
```

**IoT Integrations:** See `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md` for detailed setup of:
- Yale/August locks, BMW ConnectedDrive, Ring doorbell
- Enphase solar, Tesla charger, Flume water meter
- Nest thermostats, MyQ garage, Pentair pool
- LG ThinQ appliances, LG webOS TV, Google Cast
- Miele dishwasher, Withings scale, OPNsense firewall (HACS)
- B-Hyve sprinklers, Dreame vacuum, Hubspace lights, Traeger grill

**Energy Dashboard:** Enphase (solar), Tesla (EV charging), Flume (water)

**Weather & Automation:** AccuWeather, NWS (weather.kmhr), rain delay automations

**AI Integration:** Extended OpenAI Conversation (OpenAI API)

**ADT Alarm Control:** Via Google Assistant SDK - see `/etc/nixos/docs/ADT_ALARM_CONTROL.md`

**Adding HA Device Credentials:**
```bash
sops /etc/nixos/secrets.yaml
# Add under home-assistant section
sudo nixos-rebuild switch --flake '.#vulcan'
# Configure via HA UI: Settings > Devices & Services
```

### Monitoring & Observability

```bash
# Grafana dashboards
# URL: https://grafana.vulcan.lan

# Prometheus metrics
# URL: https://prometheus.vulcan.lan

# Check service health
sudo systemctl status prometheus grafana loki promtail

# View logs
sudo journalctl -u prometheus -f
sudo journalctl -u grafana -f

# Alertmanager
sudo systemctl status alertmanager
# URL: https://alertmanager.vulcan.lan
```

**Monitored Systems:** Home Assistant entities, LiteLLM API usage, PostgreSQL, ZFS pools, network interfaces, system resources.

### Nagios Network Monitoring

Nagios monitors network devices and services with ping checks and SSL certificate validation.

```bash
# Web interface
# URL: https://nagios.vulcan.lan

# Service status
sudo systemctl status nagios
sudo journalctl -u nagios -f

# Force check execution
echo "[$(date +%s)] SCHEDULE_FORCED_SVC_CHECK;hostname;service_description;$(date +%s)" > /var/lib/nagios/nagios.cmd

# View current status
cat /var/lib/nagios/status.dat
```

**Monitored Hosts Configuration:**

Host definitions are stored in a **private file** excluded from version control:
- **File:** `/etc/nixos/nagios-hosts.nix`
- **Status:** Excluded from git (in `.gitignore`)
- **Purpose:** Keep network topology and device information private

**Adding/Editing Monitored Hosts:**

```bash
# Edit the hosts file (requires sudo or ownership)
vim /etc/nixos/nagios-hosts.nix

# File format: Nix list with host attribute sets
# [
#   { hostname = "router"; address = "192.168.1.1"; alias = "Gateway Router"; parent = null; }
#   { hostname = "switch"; address = "192.168.1.10"; alias = "Core Switch"; parent = "router"; }
# ]

# After editing, rebuild to apply changes
sudo nixos-rebuild switch --flake '.#vulcan'
```

**Host Definition Format:**

```nix
{
  hostname = "device-name";        # Unique identifier (no spaces)
  address = "IP.address";          # IP address or FQDN
  alias = "Human Readable Name";   # Display name in Nagios UI
  parent = "parent-hostname";      # Parent device (or null for top-level)
}
```

**Parent Relationships:**

Parent devices define network topology for intelligent alerting:
- **parent = null**: Top-level device (directly connected to vulcan)
- **parent = "hostname"**: Device depends on parent for connectivity

**Nagios Alert States:**
- **DOWN**: Host is unreachable, but parent is UP (device failure)
- **UNREACHABLE**: Host is unreachable because parent is DOWN (network path failure)

This prevents alert storms when a core network device fails - child devices show as UNREACHABLE instead of DOWN.

**Example Network Topology:**

```
vulcan (monitoring server)
  └── router (parent = null)
        ├── switch (parent = "router")
        │     ├── desktop (parent = "switch")
        │     └── printer (parent = "switch")
        └── access-point (parent = "router")
              ├── phone (parent = "access-point")
              └── tablet (parent = "access-point")
```

**Monitored Services:**
- **PING**: ICMP reachability checks for all hosts
- **SSL Certificates**: HTTPS certificate expiration monitoring for web services

### MRTG Performance Graphing

MRTG (Multi Router Traffic Grapher) provides visual trending of Nagios performance metrics over time.

```bash
# Web interface
# URL: https://mrtg.vulcan.lan

# Service status
sudo systemctl status mrtg-nagios.service
sudo systemctl status mrtg-nagios.timer

# View service logs
sudo journalctl -u mrtg-nagios -f

# Manual data collection (runs automatically every 5 minutes)
sudo systemctl start mrtg-nagios.service

# Check generated graphs
ls -lh /var/lib/mrtg-nagios/*.png
```

**Available Performance Graphs:**

MRTG generates 13 different graphs tracking Nagios statistics:

1. **nagios-a**: Service check latency and execution time (milliseconds)
2. **nagios-b**: Service state change percentage (active vs passive)
3. **nagios-c**: Host check latency and execution time (milliseconds)
4. **nagios-d**: Host state change percentage (active vs passive)
5. **nagios-e**: Active checks performed (hosts and services, last 5 min)
6. **nagios-f**: Passive checks performed (hosts and services, last 5 min)
7. **nagios-g**: Service problems (critical and unknown services)
8. **nagios-i**: Active host checks (scheduled vs on-demand, last 5 min)
9. **nagios-j**: Active service checks (scheduled vs on-demand, last 5 min)
10. **nagios-k**: Passive checks (hosts and services, last 5 min)
11. **nagios-l**: Cached checks (hosts and services, last 5 min)
12. **nagios-m**: External commands processed (last 5 min)
13. **nagios-n**: Host check execution (parallel vs serial, last 5 min)

**Configuration:**

- **Module**: `/etc/nixos/modules/monitoring/mrtg.nix`
- **Config**: `/etc/nixos/modules/monitoring/mrtg-config.nix`
- **Data Directory**: `/var/lib/mrtg-nagios/`
- **Collection Interval**: 5 minutes (configurable)
- **Data Source**: `nagiostats` binary from Nagios

**Accessing Graphs:**

All graphs are available via the web interface at `https://mrtg.vulcan.lan`. Individual graph files:
- Daily graphs: `/var/lib/mrtg-nagios/nagios-{a-n}-day.png`
- Weekly graphs: `/var/lib/mrtg-nagios/nagios-{a-n}-week.png`
- Monthly graphs: `/var/lib/mrtg-nagios/nagios-{a-n}-month.png`
- Yearly graphs: `/var/lib/mrtg-nagios/nagios-{a-n}-year.png`

**Modern Alternative:**

While MRTG works well for historical compatibility, consider using **Prometheus + Grafana** for more advanced metrics visualization. The existing Prometheus/Grafana stack can ingest Nagios performance data via exporters for richer dashboards with alerting.

### Container Management

```bash
# List containers
podman ps -a

# Update container images
sudo systemctl start update-containers

# Check update logs
sudo journalctl -u update-containers -f

# Manual operations
podman pull <image>
podman restart <container>
```

### PostgreSQL

```bash
# Connect as postgres user
sudo -u postgres psql

# Connect to specific database
sudo -u postgres psql -d nextcloud

# List databases
sudo -u postgres psql -c '\l'

# Backup database
sudo -u postgres pg_dump nextcloud > nextcloud-backup.sql

# Check service
sudo systemctl status postgresql
```

### PostgreSQL Backups

**Automated daily backups** of all PostgreSQL databases run at 2:00 AM via systemd timer.

```bash
# Check backup service status
sudo systemctl status postgresql-backup.service
sudo systemctl status postgresql-backup.timer

# View backup logs
sudo journalctl -u postgresql-backup -f
sudo journalctl -u postgresql-backup --since "1 day ago"

# Trigger manual backup
sudo systemctl start postgresql-backup.service

# Check backup file
ls -lh /tank/Backups/PostgreSQL/postgresql-backup.sql
sudo -u postgres head -20 /tank/Backups/PostgreSQL/postgresql-backup.sql

# Verify backup size and timestamp
stat /tank/Backups/PostgreSQL/postgresql-backup.sql

# Restore from backup (full cluster restore)
sudo systemctl stop postgresql
sudo -u postgres psql -f /tank/Backups/PostgreSQL/postgresql-backup.sql

# Restore specific database only
sudo -u postgres psql -d <database> -f /tank/Backups/PostgreSQL/postgresql-backup.sql
```

**Backup Details:**
- **Location:** `/tank/Backups/PostgreSQL/postgresql-backup.sql`
- **Method:** `pg_dumpall` (includes all databases, roles, tablespaces)
- **Schedule:** Daily at 2:00 AM (persistent timer)
- **Retention:** Single file (ZFS snapshots provide versioning)
- **Permissions:** `postgres:postgres`, mode `640`
- **Service:** `postgresql-backup.service` / `postgresql-backup.timer`
- **Module:** `/etc/nixos/modules/services/postgresql-backup.nix`

**Notes:**
- Backup runs as `postgres` user with proper permissions
- Timer uses `Persistent=true` to run missed backups after system boot
- ZFS snapshots of `/tank/Backups` provide historical versions
- Backup file overwrites previous backup (no rotation needed)

## Architecture

### Core Structure
- **flake.nix**: Main flake defining NixOS configuration for vulcan
- **configuration.nix**: System configuration (boot, network, services, users, packages)
- **hardware-configuration.nix**: Hardware-specific configuration (generated)
- **modules/**: Organized service modules

### Key Services
1. **Restic Backups**: Automated backups to rsync.net (multiple filesets)
2. **PostgreSQL**: Database server (Nextcloud, Home Assistant, Grafana) with daily pg_dumpall backups
3. **Docker/Podman**: Container runtime
4. **Tailscale & Nebula**: VPN networking
5. **Logwatch**: System log monitoring
6. **Step-CA**: Private certificate authority (TLS & SSH certs)
7. **Dovecot**: IMAP mail server with Xapian FTS
8. **Samba**: SMB/CIFS file sharing (SMB3.1.1 encryption)
9. **Home Assistant**: IoT platform (17+ integrations)
10. **Prometheus/Grafana**: Monitoring and visualization
11. **Nginx**: Reverse proxy with SSL termination

### System Details
- **State Version**: 25.05 (DO NOT change)
- **Boot**: systemd-boot with LUKS encryption
- **Hardware**: Apple Silicon (nixos-apple-silicon module)
- **Network**: NetworkManager, static hostname "vulcan"
- **Time Zone**: America/Los_Angeles
- **Primary User**: johnw (wheel group, sudo access)
- **Storage**: ZFS on /tank with multiple datasets

### SOPS Integration
- Secrets stored encrypted in `secrets.yaml`
- Age keys for decryption (`.age` files - private)
- Deployed to `/run/secrets/` on activation
- Services use systemd `LoadCredential` or direct reads
- Auto-restart services on secret changes via `restartUnits`

## Development Notes

- System runs on Apple hardware (nixos-apple-silicon.nixosModules.default)
- PostgreSQL configured for production use
- Restic backups to rsync.net with multiple filesets
- Extensive package list (development tools, system utilities, user applications)
- Uses unstable nixpkgs channel

### Secrets and Version Control

**Current State:**
- `secrets.yaml`: SOPS-encrypted - **tracked in git** (required for Nix flakes)
- `.age keys`: Private decryption keys - **NEVER commit** (excluded via `*.age` in `.gitignore`)

**SOPS Best Practice:** Encrypted secrets.yaml MUST be tracked in git for Nix flakes to build. Only the `.age` private keys must stay out of version control.

See "SOPS Secrets Management" section for complete documentation.

## Troubleshooting

### Build Issues

```bash
# Check flake syntax
nix flake check

# Build with verbose output
sudo nixos-rebuild build --flake '.#vulcan' --show-trace

# Clean build cache
nix-collect-garbage -d
```

### Service Issues

```bash
# Check failed services
systemctl --failed

# View service logs
sudo journalctl -u <service> -f
sudo journalctl -u <service> --since "1 hour ago"

# Restart service
sudo systemctl restart <service>
```

### SOPS Issues

```bash
# Verify secret exists
ls -la /run/secrets/

# Check secret permissions
stat /run/secrets/github-token

# Re-deploy secrets (rebuild)
sudo nixos-rebuild switch --flake '.#vulcan'

# Test secret access (check permissions only, DO NOT read contents)
stat /run/secrets/github-token  # Check if accessible
sudo -u johnw stat /run/secrets/github-token  # Should work
sudo -u nobody stat /run/secrets/github-token  # Should fail
```

### Network Issues

```bash
# Check network status
ip addr show
networkctl status

# Check DNS resolution
dig vulcan.lan
nslookup vulcan.lan

# Check firewall
sudo iptables -L -n -v

# Test SSL certificates
openssl s_client -connect hass.vulcan.lan:443 -servername hass.vulcan.lan
```

## Quick Reference

**Flake Commands:** Always use `'.#vulcan'` (quoted to prevent shell # comment)

**SOPS:** Edit with `sops /etc/nixos/secrets.yaml`, rebuild to apply

**Home Assistant:** https://hass.vulcan.lan (nginx reverse proxy to :8123)

**Monitoring:** Grafana, Prometheus, Alertmanager, MRTG (*.vulcan.lan)

**Nagios MRTG:** https://mrtg.vulcan.lan (performance graphs)

**Backups:** Restic to rsync.net, automated via timers

**Secrets Location:** `/run/secrets/` (deployed at activation)

**System State:** NixOS 25.05, unstable channel, Apple hardware

## Task Master AI Instructions
**Import Task Master's development workflow commands and guidelines, treat as if import is in the main CLAUDE.md file.**
@./.taskmaster/CLAUDE.md
