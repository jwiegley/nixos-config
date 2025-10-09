# Home Assistant Configuration Backup & Restoration Guide

## Overview

Your Home Assistant configuration is now **automatically backed up** and version-controllable, making your entire setup reproducible from scratch. This solves the problem of UI-configured integrations and automations that traditionally aren't declarative in NixOS.

## The Solution: Hybrid Declarative Approach

### What IS Declarative (in NixOS)

These are defined in `/etc/nixos/modules/services/home-assistant.nix` and fully reproducible:

✅ **System Configuration**
- Integration list (extraComponents)
- Python dependencies
- System settings (time zone, location, etc.)
- Template sensors (including presence detection)
- Prometheus export configuration
- HTTP server settings
- HomeKit bridge settings

✅ **Secrets Management**
- All credentials in SOPS-encrypted `/etc/nixos/secrets.yaml`
- Yale/August credentials
- OPNsense API keys
- BMW ConnectedDrive credentials
- LG ThinQ tokens
- OpenAI API keys
- Google Assistant SDK credentials

### What Requires Backup (UI-Configured)

These are created through the Home Assistant web UI and backed up to `/etc/nixos/home-assistant-backup`:

📦 **Automations** (`automations.yaml`)
- All automation rules
- Device triggers
- Service calls
- Conditions and actions

📦 **Scripts** (`scripts.yaml`)
- Custom scripts (e.g., ADT alarm control)
- Service call sequences
- Script parameters

📦 **Scenes** (`scenes.yaml`)
- Predefined device states
- Multi-device scenes

📦 **Integration Instances** (`.storage/core.config_entries`)
- OAuth tokens and sessions
- Device pairings
- API authentication states
- Integration-specific settings

📦 **Entity Registry** (`.storage/core.entity_registry`)
- Entity customizations (friendly names, icons)
- Entity IDs
- Area assignments
- Disabled entities

📦 **Device Registry** (`.storage/core.device_registry`)
- Discovered devices
- Device names and models
- Device identifiers

📦 **Areas & Floors** (`.storage/core.area_registry`, `.storage/core.floor_registry`)
- Room definitions
- Floor plans
- Area hierarchies

📦 **Custom Components** (`custom_components/`)
- HACS integrations
- Custom integrations (not in nixpkgs)

📦 **Blueprints** (`blueprints/`)
- Automation blueprints
- Script blueprints

## Current Backup Status

### Your Configuration

**26 Integrations Configured:**
- August (Yale Home) - 3 smart locks
- B-Hyve - Sprinkler control
- BMW ConnectedDrive - Vehicle tracking
- Enphase Envoy - Solar production
- Extended OpenAI Conversation - LLM automation
- Flume - Water monitoring
- Google Assistant SDK - Voice control & ADT alarm
- HACS - Community Store
- HomeKit Bridge - Apple Home integration
- IntelliCenter - Pool/spa control
- LG ThinQ - Smart appliances
- LG webOS TV - Smart TV control
- Miele - Dishwasher
- Mobile App - Presence detection (iPhones)
- Nest - Thermostats
- Ring - Doorbell & chimes
- Traeger - Grill control
- Withings - Health devices
- And more...

**Automations:** 125 lines (2 active automations for climate control)
**Scripts:** 36 lines (4 scripts for ADT alarm control)
**Scenes:** Empty

## Automated Backup System

### When Backups Run

1. **Daily at 3:00 AM** (via systemd timer)
   - Automatic daily backup
   - Randomized by up to 15 minutes
   - Persistent (runs if system was off)

2. **On Configuration Changes** (via systemd path watch)
   - Watches `automations.yaml`, `scripts.yaml`, `scenes.yaml`
   - Triggers backup when files change
   - Prevents data loss from UI edits

3. **Manual** (on demand)
   - Run: `backup-home-assistant`
   - Creates timestamped archive

### What Gets Backed Up

```
/etc/nixos/home-assistant-backup/
├── automations.yaml          # All automations (125 lines)
├── scripts.yaml              # All scripts (36 lines)
├── scenes.yaml               # All scenes (empty currently)
├── configuration.yaml        # Runtime config
├── secrets.yaml              # Local secrets (not SOPS)
├── .storage/                 # All UI configurations (972K)
│   ├── core.config_entries   # 27K - Integration configs
│   ├── core.entity_registry  # 549K - Entity customizations
│   ├── core.device_registry  # 41K - Device information
│   ├── core.area_registry    # 4.3K - Room definitions
│   └── ... (40+ files)
├── custom_components/        # HACS integrations (23 directories)
├── blueprints/               # Automation blueprints (4 files)
├── RESTORE-INSTRUCTIONS.md   # Detailed restoration guide
├── DECLARATIVE-VS-BACKUP.md  # Strategy explanation
└── backup-metadata.txt       # Backup information

Timestamped Archives:
/etc/nixos/home-assistant-backup_YYYYMMDD_HHMMSS.tar.gz
```

### Backup Size

- **Current Backup**: 32 MB uncompressed
- **Compressed Archive**: ~512 KB
- **Storage Impact**: Minimal (<1 GB for years of backups)

## Using the Backup System

### Manual Backup

```bash
# Run immediate backup
backup-home-assistant

# Check backup status
systemctl status home-assistant-backup

# View backup logs
sudo journalctl -u home-assistant-backup
```

### View Backup Contents

```bash
# List backed up files
ls -lh /etc/nixos/home-assistant-backup/

# View automations
cat /etc/nixos/home-assistant-backup/automations.yaml

# View scripts
cat /etc/nixos/home-assistant-backup/scripts.yaml

# Check integration list
cat /etc/nixos/home-assistant-backup/backup-metadata.txt

# Read restoration guide
cat /etc/nixos/home-assistant-backup/RESTORE-INSTRUCTIONS.md

# Read declarative vs backup strategy
cat /etc/nixos/home-assistant-backup/DECLARATIVE-VS-BACKUP.md
```

### Version Control

```bash
# Add backup to git
cd /etc/nixos
git add home-assistant-backup/

# Commit changes
git commit -m "Update Home Assistant configuration backup"

# Push to remote
git push

# View changes
git diff home-assistant-backup/
```

### Check Timer Status

```bash
# View next scheduled backup
systemctl list-timers home-assistant-backup

# Enable/disable automatic backups
sudo systemctl enable home-assistant-backup.timer   # Enable
sudo systemctl disable home-assistant-backup.timer  # Disable

# View timer configuration
systemctl cat home-assistant-backup.timer
```

## Restoration Process

### Full System Rebuild

If you need to rebuild the entire NixOS system from scratch:

1. **Clone your NixOS configuration repository**:
   ```bash
   git clone <your-repo> /etc/nixos
   cd /etc/nixos
   ```

2. **Rebuild NixOS** (this installs Home Assistant):
   ```bash
   sudo nixos-rebuild switch --flake '.#vulcan'
   ```

3. **Wait for Home Assistant to start** (initial setup):
   ```bash
   sudo journalctl -u home-assistant -f
   ```
   Wait until you see "Home Assistant Core has started"

4. **Stop Home Assistant**:
   ```bash
   sudo systemctl stop home-assistant
   ```

5. **Restore configuration**:
   ```bash
   restore-home-assistant
   ```
   This copies all backed-up files and restarts Home Assistant

6. **Verify restoration**:
   ```bash
   # Check logs
   sudo journalctl -u home-assistant -f

   # Access web UI
   firefox https://hass.vulcan.lan
   ```

### What Happens During Restoration

The `restore-home-assistant` command:

1. Stops Home Assistant service
2. Restores `automations.yaml`, `scripts.yaml`, `scenes.yaml`
3. Restores `.storage/` directory (all UI configs)
4. Restores `custom_components/` (HACS integrations)
5. Restores `blueprints/` (automation blueprints)
6. Fixes file ownership (`hass:hass`)
7. Starts Home Assistant service

### Post-Restoration Steps

**Most integrations will work automatically**, but some require re-authentication:

#### ✅ Automatic (No Action Needed)
- August locks (credentials from SOPS)
- Flume water meter
- Enphase Envoy
- Miele dishwasher
- Pentair IntelliCenter
- Ring doorbell
- Traeger grill
- LG ThinQ (token from SOPS)
- LG webOS TV
- Withings

#### ⚠️ May Need Re-Authentication
- **Google Nest**: OAuth may expire, re-authenticate via UI
- **BMW ConnectedDrive**: May require captcha, re-authenticate
- **Google Assistant SDK**: OAuth token may need refresh
- **Extended OpenAI Conversation**: Should work (API key from SOPS)

#### 🔧 HACS Components (Need HACS First)
1. Install HACS: `wget -O - https://get.hacs.xyz | bash -`
2. Restart Home Assistant
3. Add HACS via UI and authenticate with GitHub
4. Custom components will be detected automatically from backup

### Partial Restoration

If you only want to restore specific components:

```bash
# Restore only automations
sudo systemctl stop home-assistant
sudo cp /etc/nixos/home-assistant-backup/automations.yaml /var/lib/hass/
sudo chown hass:hass /var/lib/hass/automations.yaml
sudo systemctl start home-assistant

# Restore only scripts
sudo systemctl stop home-assistant
sudo cp /etc/nixos/home-assistant-backup/scripts.yaml /var/lib/hass/
sudo chown hass:hass /var/lib/hass/scripts.yaml
sudo systemctl start home-assistant

# Restore only integrations (.storage)
sudo systemctl stop home-assistant
sudo cp -r /etc/nixos/home-assistant-backup/.storage/* /var/lib/hass/.storage/
sudo chown -R hass:hass /var/lib/hass/.storage
sudo systemctl start home-assistant
```

## Troubleshooting

### Backup Not Running

```bash
# Check timer status
systemctl status home-assistant-backup.timer

# Check if timer is enabled
systemctl is-enabled home-assistant-backup.timer

# Enable if disabled
sudo systemctl enable home-assistant-backup.timer

# Manually trigger backup
sudo systemctl start home-assistant-backup
```

### Backup Fails

```bash
# View backup logs
sudo journalctl -u home-assistant-backup -n 100

# Check permissions
ls -la /var/lib/hass/

# Check disk space
df -h /etc/nixos

# Test backup script directly
sudo /etc/nixos/scripts/backup-home-assistant.sh
```

### Restoration Issues

```bash
# Check Home Assistant logs
sudo journalctl -u home-assistant -f

# Check file ownership
ls -la /var/lib/hass/

# Fix ownership if needed
sudo chown -R hass:hass /var/lib/hass

# Restart Home Assistant
sudo systemctl restart home-assistant
```

### Integration Not Loading After Restore

1. **Check logs for authentication errors**:
   ```bash
   sudo journalctl -u home-assistant | grep -i error
   ```

2. **Verify credentials in SOPS**:
   ```bash
   # Don't decrypt, but check keys exist
   grep "home-assistant" /etc/nixos/secrets.yaml
   ```

3. **Re-authenticate via UI** if OAuth expired:
   - Settings > Devices & Services
   - Click on integration
   - Re-configure or re-authorize

4. **Check integration is enabled in NixOS config**:
   ```bash
   grep extraComponents /etc/nixos/modules/services/home-assistant.nix
   ```

## System Files

### Configuration Files
- **Backup Script**: `/etc/nixos/scripts/backup-home-assistant.sh`
- **NixOS Module**: `/etc/nixos/modules/services/home-assistant-backup.nix`
- **Documentation**: `/etc/home-assistant-backup/README.md`
- **This Guide**: `/etc/nixos/docs/HOME_ASSISTANT_BACKUP_GUIDE.md`

### Systemd Units
- **Service**: `home-assistant-backup.service` - Runs the backup script
- **Timer**: `home-assistant-backup.timer` - Daily schedule at 3 AM
- **Path Watch**: `home-assistant-config-watch.path` - Monitors file changes

### Commands
- `backup-home-assistant` - Manual backup
- `restore-home-assistant` - Interactive restoration

## Best Practices

### 1. Commit After Changes

After making changes in the Home Assistant UI:
```bash
cd /etc/nixos
git diff home-assistant-backup/  # Review changes
git add home-assistant-backup/
git commit -m "Add new automation for climate control"
git push
```

### 2. Test Restoration Periodically

Every few months, test the restoration process:
```bash
# Backup current state
backup-home-assistant

# Test restoration (in a safe way)
# Option 1: Test on a VM
# Option 2: Restore to /tmp first
```

### 3. Keep Timestamped Archives

Don't delete the `.tar.gz` archives:
```bash
# List archives
ls -lh /etc/nixos/home-assistant-backup_*.tar.gz

# Keep at least the last 10 backups
# They're small (~512 KB each)
```

### 4. Document Integration Changes

When adding new integrations, document any manual steps:
```bash
git commit -m "Add BMW integration - requires captcha on first auth"
```

### 5. Backup SOPS Secrets Separately

The backup system **does not backup SOPS encrypted secrets**. Ensure you have:
- SOPS age keys backed up (`/etc/ssh/ssh_host_ed25519_key`)
- GPG keys backed up (`/etc/ssh/ssh_host_rsa_key`)
- `secrets.yaml` in your git repository

## Comparison: Before vs After

### Before (UI-Only Configuration)

❌ Configurations lost if system rebuilt
❌ No version control
❌ Manual documentation of integrations
❌ Difficult to reproduce setup
❌ Risk of configuration drift
❌ No change tracking

### After (Declarative + Backup)

✅ Full system reproducibility
✅ Version controlled in git
✅ Automated daily backups
✅ Instant restoration after rebuild
✅ Change tracking via git
✅ Documented integration list
✅ Hybrid declarative approach

## Summary

Your Home Assistant configuration is now **fully reproducible**:

1. **NixOS declares the system** (integrations, packages, settings)
2. **Backups preserve UI configs** (automations, entities, devices)
3. **SOPS encrypts secrets** (credentials, tokens, keys)
4. **Git tracks everything** (version control, change history)
5. **Automated backups ensure currency** (daily + on-change)

**Result**: If your system crashes, you can rebuild everything from scratch by:
1. Cloning your NixOS repo
2. Running `nixos-rebuild switch`
3. Running `restore-home-assistant`

That's it! Your entire Home Assistant setup is restored.

## Need Help?

- **Restoration Guide**: `/etc/nixos/home-assistant-backup/RESTORE-INSTRUCTIONS.md`
- **Strategy Guide**: `/etc/nixos/home-assistant-backup/DECLARATIVE-VS-BACKUP.md`
- **Backup Metadata**: `/etc/nixos/home-assistant-backup/backup-metadata.txt`
- **System Docs**: `/etc/home-assistant-backup/README.md`
- **This Guide**: `/etc/nixos/docs/HOME_ASSISTANT_BACKUP_GUIDE.md`
