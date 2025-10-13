# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a NixOS configuration for the host "vulcan" - an x86_64 Linux system running on Apple T2 hardware. This configuration uses Nix flakes with nixos-hardware and nixos-logwatch modules.

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

**Managed Secrets:** GitHub tokens, Home Assistant credentials, MinIO, Google Assistant OAuth, OpenAI keys, SMUD utility account.

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

# Generate certificate
step ca certificate "service.vulcan.local" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# Renew certificate
step ca renew service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt
```

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

**Monitored Systems:** Home Assistant entities, LiteLLM API usage, PostgreSQL, ZFS pools, network interfaces, system resources, Chainweb node.

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
- **Hardware**: Apple T2 (nixos-hardware module)
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

- System runs on Apple T2 hardware (nixos-hardware.nixosModules.apple-t2)
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

# Test secret access
sudo -u johnw cat /run/secrets/github-token  # Should work
sudo -u nobody cat /run/secrets/github-token  # Should fail
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

**Monitoring:** Grafana, Prometheus, Alertmanager (*.vulcan.lan)

**Backups:** Restic to rsync.net, automated via timers

**Secrets Location:** `/run/secrets/` (deployed at activation)

**System State:** NixOS 25.05, unstable channel, Apple T2 hardware
