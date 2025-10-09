#!/usr/bin/env bash
# Home Assistant Configuration Backup Script
# This script backs up all Home Assistant configuration to make it reproducible

set -euo pipefail

# Configuration
HASS_DIR="/var/lib/hass"
BACKUP_DIR="/etc/nixos/home-assistant-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_WITH_TIMESTAMP="${BACKUP_DIR}_${TIMESTAMP}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# Create backup directory
log_info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Backup YAML configuration files
log_info "Backing up YAML configuration files..."
cp -p "$HASS_DIR/automations.yaml" "$BACKUP_DIR/automations.yaml"
cp -p "$HASS_DIR/scripts.yaml" "$BACKUP_DIR/scripts.yaml"
cp -p "$HASS_DIR/scenes.yaml" "$BACKUP_DIR/scenes.yaml"
cp -p "$HASS_DIR/configuration.yaml" "$BACKUP_DIR/configuration.yaml"

# Backup secrets file if it exists
if [ -f "$HASS_DIR/secrets.yaml" ]; then
    log_info "Backing up secrets.yaml..."
    cp -p "$HASS_DIR/secrets.yaml" "$BACKUP_DIR/secrets.yaml"
fi

# Backup .storage directory (contains all UI configurations)
log_info "Backing up .storage directory (UI configurations)..."
mkdir -p "$BACKUP_DIR/.storage"
cp -rp "$HASS_DIR/.storage/"* "$BACKUP_DIR/.storage/" 2>/dev/null || true

# Backup custom components
if [ -d "$HASS_DIR/custom_components" ]; then
    log_info "Backing up custom_components..."
    mkdir -p "$BACKUP_DIR/custom_components"
    cp -rp "$HASS_DIR/custom_components/"* "$BACKUP_DIR/custom_components/" 2>/dev/null || true
fi

# Backup blueprints
if [ -d "$HASS_DIR/blueprints" ]; then
    log_info "Backing up blueprints..."
    mkdir -p "$BACKUP_DIR/blueprints"
    cp -rp "$HASS_DIR/blueprints/"* "$BACKUP_DIR/blueprints/" 2>/dev/null || true
fi

# Create a metadata file with backup information
log_info "Creating backup metadata..."
cat > "$BACKUP_DIR/backup-metadata.txt" <<EOF
Home Assistant Configuration Backup
Created: $(date)
Hostname: $(hostname)
Home Assistant Version: $(cat $HASS_DIR/.HA_VERSION 2>/dev/null || echo "unknown")

Backed up files:
- automations.yaml ($(wc -l < "$HASS_DIR/automations.yaml") lines)
- scripts.yaml ($(wc -l < "$HASS_DIR/scripts.yaml") lines)
- scenes.yaml ($(wc -l < "$HASS_DIR/scenes.yaml") lines)
- configuration.yaml
- .storage/ directory ($(du -sh "$HASS_DIR/.storage" | cut -f1))
- custom_components/ ($(find "$HASS_DIR/custom_components" -type d 2>/dev/null | wc -l) directories)
- blueprints/ ($(find "$HASS_DIR/blueprints" -type f 2>/dev/null | wc -l) files)

Configured Integrations:
EOF

# List all configured integrations
if [ -f "$HASS_DIR/.storage/core.config_entries" ]; then
    jq -r '.data.entries[] | "- \(.domain): \(.title)"' "$HASS_DIR/.storage/core.config_entries" | sort >> "$BACKUP_DIR/backup-metadata.txt"
fi

# Create a timestamped archive backup
log_info "Creating timestamped archive backup..."
cp -r "$BACKUP_DIR" "$BACKUP_WITH_TIMESTAMP"
tar -czf "${BACKUP_WITH_TIMESTAMP}.tar.gz" -C "$(dirname "$BACKUP_WITH_TIMESTAMP")" "$(basename "$BACKUP_WITH_TIMESTAMP")"
rm -rf "$BACKUP_WITH_TIMESTAMP"

# Set proper ownership
log_info "Setting proper ownership..."
chown -R root:root "$BACKUP_DIR"
chmod -R 644 "$BACKUP_DIR"/*
find "$BACKUP_DIR" -type d -exec chmod 755 {} \;

# Create a restoration instructions file
log_info "Creating restoration instructions..."
cat > "$BACKUP_DIR/RESTORE-INSTRUCTIONS.md" <<'EOF'
# Home Assistant Configuration Restoration Guide

This backup contains all Home Assistant configurations created through the web UI,
making your setup reproducible.

## What's Included

- **automations.yaml** - All automation rules
- **scripts.yaml** - All custom scripts (including ADT control)
- **scenes.yaml** - All defined scenes
- **configuration.yaml** - Runtime configuration
- **.storage/** - All UI configurations (integrations, entities, devices, areas)
- **custom_components/** - HACS and other custom integrations
- **blueprints/** - Automation blueprints

## Restoration Steps

### Full System Rebuild (NixOS)

1. **Rebuild NixOS** with Home Assistant enabled:
   ```bash
   sudo nixos-rebuild switch --flake '.#vulcan'
   ```

2. **Stop Home Assistant**:
   ```bash
   sudo systemctl stop home-assistant
   ```

3. **Restore configuration files**:
   ```bash
   sudo cp automations.yaml /var/lib/hass/
   sudo cp scripts.yaml /var/lib/hass/
   sudo cp scenes.yaml /var/lib/hass/
   ```

4. **Restore .storage directory** (contains all integrations and UI configs):
   ```bash
   sudo cp -r .storage/* /var/lib/hass/.storage/
   ```

5. **Restore custom components**:
   ```bash
   sudo cp -r custom_components/* /var/lib/hass/custom_components/
   ```

6. **Restore blueprints**:
   ```bash
   sudo cp -r blueprints/* /var/lib/hass/blueprints/
   ```

7. **Fix ownership**:
   ```bash
   sudo chown -R hass:hass /var/lib/hass
   ```

8. **Start Home Assistant**:
   ```bash
   sudo systemctl start home-assistant
   ```

### Partial Restoration (Specific Components)

#### Restore Only Automations
```bash
sudo systemctl stop home-assistant
sudo cp automations.yaml /var/lib/hass/
sudo chown hass:hass /var/lib/hass/automations.yaml
sudo systemctl start home-assistant
```

#### Restore Only Scripts
```bash
sudo systemctl stop home-assistant
sudo cp scripts.yaml /var/lib/hass/
sudo chown hass:hass /var/lib/hass/scripts.yaml
sudo systemctl start home-assistant
```

## Important Notes

### Secrets Management
- Credentials are stored in SOPS-encrypted `secrets.yaml` in `/etc/nixos/`
- After restoration, integrations will re-authenticate using these credentials
- Some integrations (like Google Nest, BMW) may require re-authorization via OAuth

### Integration-Specific Considerations

**Integrations that restore automatically:**
- August locks (Yale Home)
- Flume water meter
- Enphase Envoy
- Miele
- Pentair IntelliCenter
- Ring
- Traeger
- LG ThinQ
- LG webOS TV
- Withings

**Integrations that may need re-authentication:**
- Google Nest (OAuth token)
- BMW ConnectedDrive (captcha may be required)
- Google Assistant SDK (OAuth token)
- Extended OpenAI Conversation (API key from secrets)

**Integrations that are HACS-based (need HACS first):**
- B-Hyve sprinkler control
- OPNsense (custom component)
- Traeger (if using HACS version)
- Hubspace
- Dreame vacuum

### HACS Restoration

HACS (Home Assistant Community Store) needs to be re-installed:
1. Install HACS: `wget -O - https://get.hacs.xyz | bash -`
2. Restart Home Assistant
3. Add HACS integration via UI
4. Authenticate with GitHub
5. Custom components will be automatically detected from backup

### Entity and Device Registry

The `.storage/` directory contains:
- `core.entity_registry` - All entity customizations and unique IDs
- `core.device_registry` - All device information and areas
- `core.area_registry` - Room/area definitions
- `core.config_entries` - Integration configurations

Restoring `.storage/` preserves all entity IDs, customizations, and relationships.

## Verification After Restoration

1. Check Home Assistant logs:
   ```bash
   sudo journalctl -u home-assistant -f
   ```

2. Access Home Assistant UI: https://hass.vulcan.lan

3. Verify integrations: Settings > Devices & Services

4. Check automations: Settings > Automations & Scenes

5. Test scripts: Developer Tools > Services

## Troubleshooting

### Integration Not Loading
- Check logs for authentication errors
- Re-authenticate via UI if OAuth is required
- Verify credentials in `/etc/nixos/secrets.yaml`

### Entities Missing
- Ensure `.storage/` was restored completely
- Check `core.entity_registry` permissions (should be hass:hass)
- Restart Home Assistant

### Automations Not Working
- Verify automations.yaml syntax: `yaml lint automations.yaml`
- Check automation editor in UI for any errors
- Ensure all referenced entities exist

## Making Future Changes Declarative

### Automations
Edit `/etc/nixos/home-assistant-backup/automations.yaml` and copy to NixOS config:
```nix
services.home-assistant.config = {
  automation = "!include automations.yaml";
};
```

### Scripts
Keep scripts in `/etc/nixos/home-assistant-backup/scripts.yaml` and include:
```nix
services.home-assistant.config = {
  script = "!include scripts.yaml";
};
```

### Integrations
Most integrations cannot be fully declared in Nix. Use this backup approach:
1. Configure integration via UI
2. Run backup script
3. Commit backup to git
4. Restore from backup when rebuilding
EOF

log_info "Creating summary of what can be declarative..."
cat > "$BACKUP_DIR/DECLARATIVE-VS-BACKUP.md" <<'EOF'
# Home Assistant: Declarative vs Backup Strategy

## What CAN Be Fully Declarative in NixOS

These can be defined entirely in `/etc/nixos/modules/services/home-assistant.nix`:

### ✅ System Configuration
```nix
services.home-assistant = {
  enable = true;
  extraComponents = [
    "august"
    "nest"
    "ring"
    # ... all integrations
  ];

  config = {
    homeassistant = {
      name = "Vulcan Home";
      latitude = "!secret latitude";
      longitude = "!secret longitude";
      time_zone = "America/Los_Angeles";
    };

    http = {
      server_host = "127.0.0.1";
      server_port = 8123;
    };

    prometheus = {
      # Metrics export config
    };

    # Template sensors for presence detection
    template = [ /* ... */ ];
  };
};
```

### ✅ Secrets Management
All credentials in SOPS-encrypted `/etc/nixos/secrets.yaml`:
- Yale/August credentials
- OPNsense API keys
- BMW credentials
- LG ThinQ tokens
- API keys

### ✅ Python Dependencies
```nix
extraPackages = ps: [
  ps.psycopg2
  ps.grpcio
  ps.openai
  # ... all required packages
];
```

### ✅ Custom Components (via Nix overlays)
```nix
customComponents = with pkgs.home-assistant-custom-components; [
  hacs
  intellicenter
];
```

## What REQUIRES Backup & Restoration

These configurations are created through the UI and stored in `.storage/`:

### ❌ Integration Instances
- **Why**: Each integration requires OAuth, API tokens, or pairing
- **Example**: Google Nest (OAuth), BMW (captcha), August (account link)
- **Backup**: `.storage/core.config_entries`
- **Restoration**: Restore `.storage/` or re-configure via UI

### ❌ Entity Customizations
- **Why**: Entity IDs, friendly names, icons, areas assigned via UI
- **Backup**: `.storage/core.entity_registry`
- **Restoration**: Restore `.storage/`

### ❌ Device Registry
- **Why**: Devices discovered and paired via UI
- **Backup**: `.storage/core.device_registry`
- **Restoration**: Restore `.storage/` or re-pair devices

### ❌ Areas and Floors
- **Why**: Rooms/areas defined via UI
- **Backup**: `.storage/core.area_registry`, `.storage/core.floor_registry`
- **Restoration**: Restore `.storage/`

### ⚠️ Automations (Hybrid)
- **Declarative Option**: Write YAML manually in Nix config
- **UI Option**: Create via automation editor, saved to `automations.yaml`
- **Recommendation**: Back up `automations.yaml` and version control it

### ⚠️ Scripts (Hybrid)
- **Declarative Option**: Define in Nix config
- **UI Option**: Create via script editor, saved to `scripts.yaml`
- **Recommendation**: Keep `scripts.yaml` in git

### ⚠️ Scenes (Hybrid)
- **Declarative Option**: Define in Nix config
- **UI Option**: Create via scene editor, saved to `scenes.yaml`
- **Recommendation**: Back up `scenes.yaml`

## Recommended Strategy: Hybrid Approach

### Declarative (in NixOS)
1. System configuration
2. Integration list (extraComponents)
3. Secrets (SOPS)
4. Python dependencies
5. Template sensors
6. Prometheus export config

### Backup-Based (version controlled)
1. `.storage/` directory → Git repository
2. `automations.yaml` → Git repository
3. `scripts.yaml` → Git repository
4. `scenes.yaml` → Git repository
5. `custom_components/` → Git repository

### Workflow
1. Configure integrations and automations via UI
2. Run `/etc/nixos/scripts/backup-home-assistant.sh` (automated via systemd timer)
3. Commit backup to git: `cd /etc/nixos && git add home-assistant-backup && git commit`
4. Push to remote repository
5. On system rebuild: restore from backup after initial Home Assistant start

## Why This Hybrid Approach?

**Home Assistant's Design Philosophy:**
- Built for non-technical users
- UI-first configuration
- Dynamic discovery and pairing
- OAuth and interactive authentication

**NixOS's Design Philosophy:**
- Declarative configuration
- Reproducible builds
- Version control
- No runtime mutations

**The Compromise:**
- Use Nix for system-level configuration
- Use backups for user-level configuration
- Version control both
- Automated backup ensures reproducibility

## Automation: Backup on Every Change

Create a systemd path unit to backup on file changes:

```nix
systemd.paths.home-assistant-backup = {
  wantedBy = [ "multi-user.target" ];
  pathConfig = {
    PathChanged = "/var/lib/hass/automations.yaml";
    PathChanged = "/var/lib/hass/scripts.yaml";
    PathChanged = "/var/lib/hass/.storage/core.config_entries";
  };
};

systemd.services.home-assistant-backup = {
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "/etc/nixos/scripts/backup-home-assistant.sh";
  };
};
```

This ensures your configuration is always backed up and can be restored.
EOF

# Calculate backup size
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
ARCHIVE_SIZE=$(du -sh "${BACKUP_WITH_TIMESTAMP}.tar.gz" | cut -f1)

log_info "Backup completed successfully!"
log_info "Backup location: $BACKUP_DIR"
log_info "Backup size: $BACKUP_SIZE"
log_info "Archive created: ${BACKUP_WITH_TIMESTAMP}.tar.gz ($ARCHIVE_SIZE)"
log_info ""
log_info "Next steps:"
log_info "1. Review backup contents: ls -la $BACKUP_DIR"
log_info "2. Read restoration guide: cat $BACKUP_DIR/RESTORE-INSTRUCTIONS.md"
log_info "3. Commit to git: cd /etc/nixos && git add home-assistant-backup"
log_info "4. Set up automated backups: see $BACKUP_DIR/DECLARATIVE-VS-BACKUP.md"

exit 0
