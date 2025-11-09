# CLAUDE.md

Guidance for Claude Code when working with this NixOS repository.

## ⚠️ CRITICAL SAFETY RULES ⚠️

### DATA LOSS PREVENTION

**NEVER use systemd tmpfiles.rules for persistent data directories:**

- **`d` directive** = Creates directory if it doesn't exist, **PRESERVES contents**
- **`D` directive** = Creates OR **EMPTIES directory** when `systemd-tmpfiles --remove` runs (on every boot/rebuild)
- **`e` directive** = Adjusts permissions only, never creates or deletes

**CRITICAL: The D directive is for temporary directories like /tmp, NOT for data storage!**

**For persistent data directories, use ZFS datasets or regular directories WITHOUT tmpfiles.rules.**

**Before modifying tmpfiles.rules:**
1. STOP and verify: Is this data meant to persist or be temporary?
2. For persistent data: Use ZFS datasets, NOT tmpfiles.rules
3. For temporary data: Use `D` directive with age parameters
4. Wait for explicit user approval

**Past incidents:**
- **2025-11-04**: Changed `/var/mail/johnw` from `d` to `D`, causing mail deletion
- **2025-11-09**: Used `D` for Monica/MariaDB, lost database twice due to emptying on rebuild

### SECURITY - NO SECRETS IN OUTPUT

**NEVER reveal or display:**
- Passwords, API keys, tokens, OAuth credentials
- WiFi SSIDs/passwords, network topology, IP addresses
- Contents from `/run/secrets/` or decrypted SOPS files
- Home Assistant `.storage/*` files (contain OAuth tokens)
- Certificate contents or private keys

**FORBIDDEN commands:**
- `sops -d` (decrypts secrets)
- Any command reading `/run/secrets/*`
- Reading `/var/lib/hass/.storage/*` files
- Commands showing `access_token`, `refresh_token`, `api_key` fields

**SAFE operations:**
- `sops /etc/nixos/secrets.yaml` (interactive editor)
- `ls -la /run/secrets/` (metadata only)
- Checking logs with `journalctl`
- Using `systemctl status` commands

**Past violation (2025-10-27):** Displayed OAuth tokens from Home Assistant storage. Should have used journalctl logs instead.

**If you violate these rules: STOP ALL WORK. Apologize and wait for user acknowledgment.**

---

## System Overview

**Host:** vulcan - aarch64 Linux on Apple hardware (Asahi Linux)
**Key Services:** PostgreSQL, Step-CA, Dovecot, Samba, Home Assistant, Prometheus/Grafana, Nginx
**Storage:** ZFS on /tank
**State Version:** 25.05 (DO NOT change)

## SOPS Secrets Management

Secrets are encrypted in `secrets.yaml` (tracked in git) using age encryption.
Private `.age` keys must NEVER be committed.

```bash
# Edit secrets
sops /etc/nixos/secrets.yaml

# Apply changes
sudo nixos-rebuild switch --flake '.#vulcan'

# Secrets deploy to
/run/secrets/
```

**Adding secrets:**
1. Edit with `sops /etc/nixos/secrets.yaml`
2. Declare in NixOS module with owner/permissions
3. Access via systemd `LoadCredential` or direct path
4. Rebuild to deploy

## Quick Command Reference

### System Management
```bash
sudo nixos-rebuild switch --flake '.#vulcan'  # Build and switch
sudo nixos-rebuild build --flake '.#vulcan'   # Build only
nix flake update                              # Update inputs
nix fmt                                        # Format Nix files
```

### Service Status
```bash
sudo systemctl status <service>
sudo journalctl -u <service> -f
sudo systemctl restart <service>
```

### Certificate Authority
```bash
# ALWAYS use the secure script (handles SOPS internally):
sudo /etc/nixos/certs/renew-certificate.sh "domain.lan" \
  -o "/output/dir" -d 365 --owner "user:group"

# Common locations:
# Nginx: /var/lib/nginx-certs/ (nginx:nginx)
# PostgreSQL: /var/lib/postgresql/ (postgres:postgres)
# Dovecot: /etc/dovecot/certs/ (root:root)
```

### Database Backups
Daily automated backups at 2 AM to `/tank/Backups/PostgreSQL/`
```bash
sudo systemctl status postgresql-backup.timer
sudo systemctl start postgresql-backup.service  # Manual backup
```

### Common Services

**Home Assistant**
- URL: https://hass.vulcan.lan
- Config: `/var/lib/hass/`
- Integrations: See `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md`

**Monitoring**
- Grafana: https://grafana.vulcan.lan
- Prometheus: https://prometheus.vulcan.lan
- Nagios: https://nagios.vulcan.lan

**Email**
```bash
doveadm index -u <user> '*'        # Index for search
doveadm fts optimize -u <user>     # Optimize FTS
```

**File Sharing (Samba)**
- Connect: `smb://vulcan.lan/<share>`
- Shares defined in `/etc/nixos/modules/services/samba.nix`

**ZFS**
```bash
dh              # Custom dataset helper
zfs list        # Standard listing
zpool status    # Pool health
```

## Module Organization

```
/etc/nixos/
├── flake.nix                 # Main flake configuration
├── configuration.nix         # System configuration
├── secrets.yaml             # SOPS-encrypted secrets (in git)
├── *.age                    # Private keys (NEVER commit)
├── modules/
│   ├── services/            # Service configurations
│   ├── monitoring/          # Prometheus, Grafana, etc.
│   └── containers/          # Container definitions
├── docs/                    # Additional documentation
└── nagios-hosts.nix        # Private network topology (gitignored)
```

## Troubleshooting

**Build issues:**
```bash
nix flake check
sudo nixos-rebuild build --flake '.#vulcan' --show-trace
```

**Secret issues:**
```bash
ls -la /run/secrets/         # Check deployment
stat /run/secrets/<name>     # Check permissions
```

**Service issues:**
```bash
systemctl --failed           # List failed services
journalctl -u <service> -f  # View logs
```

## Important Files

- `/etc/nixos/nagios-hosts.nix` - Private network topology (excluded from git)
- `/etc/nixos/docs/` - Detailed service documentation
- `/tank/Backups/` - Backup storage location
- `/run/secrets/` - Runtime secret deployment

## Task Master AI Instructions
@./.taskmaster/CLAUDE.md
