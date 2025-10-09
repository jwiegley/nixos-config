{ config, lib, pkgs, ... }:

{
  # Automated Home Assistant configuration backup
  # Backs up all UI-configured settings to /etc/nixos/home-assistant-backup

  # Backup service
  systemd.services.home-assistant-backup = {
    description = "Backup Home Assistant Configuration";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/scripts/backup-home-assistant.sh";
      User = "root";
    };

    # Ensure Home Assistant is running before backup
    after = [ "home-assistant.service" ];
    requires = [ "home-assistant.service" ];
  };

  # Daily backup timer
  systemd.timers.home-assistant-backup = {
    description = "Daily Home Assistant Configuration Backup";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Run daily at 3 AM
      OnCalendar = "*-*-* 03:00:00";

      # If system was off at 3 AM, run backup when it starts
      Persistent = true;

      # Randomize start time by up to 15 minutes
      RandomizedDelaySec = "15min";
    };
  };

  # Backup on configuration changes
  # This path unit watches for changes to key files
  systemd.paths.home-assistant-config-watch = {
    description = "Watch Home Assistant Configuration Files";
    wantedBy = [ "multi-user.target" ];

    pathConfig = {
      # Watch for changes to configuration files
      PathChanged = [
        "/var/lib/hass/automations.yaml"
        "/var/lib/hass/scripts.yaml"
        "/var/lib/hass/scenes.yaml"
      ];

      # Trigger backup service on changes
      Unit = "home-assistant-backup.service";
    };
  };

  # Create a command for manual backup
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "backup-home-assistant" ''
      sudo systemctl start home-assistant-backup.service
      echo "Backup initiated. Check status with: systemctl status home-assistant-backup"
    '')

    (writeShellScriptBin "restore-home-assistant" ''
      BACKUP_DIR="/etc/nixos/home-assistant-backup"

      if [ ! -d "$BACKUP_DIR" ]; then
        echo "Error: Backup directory not found at $BACKUP_DIR"
        exit 1
      fi

      echo "This will restore Home Assistant configuration from backup."
      echo "WARNING: This will overwrite your current configuration!"
      echo ""
      read -p "Are you sure you want to continue? (yes/no): " confirm

      if [ "$confirm" != "yes" ]; then
        echo "Restoration cancelled."
        exit 0
      fi

      echo "Stopping Home Assistant..."
      sudo systemctl stop home-assistant

      echo "Restoring configuration files..."
      sudo cp "$BACKUP_DIR/automations.yaml" /var/lib/hass/
      sudo cp "$BACKUP_DIR/scripts.yaml" /var/lib/hass/
      sudo cp "$BACKUP_DIR/scenes.yaml" /var/lib/hass/

      echo "Restoring .storage directory..."
      sudo cp -r "$BACKUP_DIR/.storage/"* /var/lib/hass/.storage/

      if [ -d "$BACKUP_DIR/custom_components" ]; then
        echo "Restoring custom components..."
        sudo mkdir -p /var/lib/hass/custom_components
        sudo cp -r "$BACKUP_DIR/custom_components/"* /var/lib/hass/custom_components/
      fi

      if [ -d "$BACKUP_DIR/blueprints" ]; then
        echo "Restoring blueprints..."
        sudo mkdir -p /var/lib/hass/blueprints
        sudo cp -r "$BACKUP_DIR/blueprints/"* /var/lib/hass/blueprints/
      fi

      echo "Fixing ownership..."
      sudo chown -R hass:hass /var/lib/hass

      echo "Starting Home Assistant..."
      sudo systemctl start home-assistant

      echo ""
      echo "Restoration complete!"
      echo "Check Home Assistant logs: sudo journalctl -u home-assistant -f"
    '')
  ];

  # Add documentation to /etc
  environment.etc."home-assistant-backup/README.md" = {
    text = ''
      # Home Assistant Automated Backup System

      ## Overview

      This system automatically backs up your Home Assistant configuration to
      `/etc/nixos/home-assistant-backup` making it version-controllable and reproducible.

      ## What Gets Backed Up

      - `automations.yaml` - All automation rules
      - `scripts.yaml` - All custom scripts
      - `scenes.yaml` - All defined scenes
      - `configuration.yaml` - Runtime configuration
      - `.storage/` - All UI configurations (integrations, entities, devices, areas)
      - `custom_components/` - HACS and custom integrations
      - `blueprints/` - Automation blueprints

      ## Backup Schedule

      - **Automatic**: Daily at 3:00 AM (via systemd timer)
      - **On Change**: When automations.yaml, scripts.yaml, or scenes.yaml changes
      - **Manual**: Run `backup-home-assistant` command

      ## Commands

      ### Manual Backup
      ```bash
      backup-home-assistant
      ```

      ### Check Backup Status
      ```bash
      systemctl status home-assistant-backup
      ```

      ### View Backup Timer Status
      ```bash
      systemctl status home-assistant-backup.timer
      ```

      ### View Recent Backups
      ```bash
      ls -lh /etc/nixos/home-assistant-backup_*
      ```

      ### Restore from Backup
      ```bash
      restore-home-assistant
      ```

      ## Version Control Integration

      To version control your Home Assistant configuration:

      ```bash
      cd /etc/nixos
      git add home-assistant-backup
      git commit -m "Backup Home Assistant configuration"
      git push
      ```

      ## Restoration After System Rebuild

      1. Rebuild NixOS system:
         ```bash
         sudo nixos-rebuild switch --flake '.#vulcan'
         ```

      2. Restore configuration:
         ```bash
         restore-home-assistant
         ```

      3. Wait for Home Assistant to start and verify:
         ```bash
         sudo journalctl -u home-assistant -f
         ```

      ## Files and Locations

      - **Backup Script**: `/etc/nixos/scripts/backup-home-assistant.sh`
      - **Current Backup**: `/etc/nixos/home-assistant-backup/`
      - **Archived Backups**: `/etc/nixos/home-assistant-backup_YYYYMMDD_HHMMSS.tar.gz`
      - **Restoration Guide**: `/etc/nixos/home-assistant-backup/RESTORE-INSTRUCTIONS.md`
      - **Declarative Guide**: `/etc/nixos/home-assistant-backup/DECLARATIVE-VS-BACKUP.md`

      ## Systemd Units

      - **Service**: `home-assistant-backup.service`
      - **Timer**: `home-assistant-backup.timer`
      - **Path Watch**: `home-assistant-config-watch.path`

      ## Troubleshooting

      ### Check Last Backup
      ```bash
      sudo journalctl -u home-assistant-backup -n 50
      ```

      ### Manually Trigger Backup
      ```bash
      sudo systemctl start home-assistant-backup
      ```

      ### Check What Changed
      ```bash
      cd /etc/nixos
      git status home-assistant-backup/
      git diff home-assistant-backup/
      ```

      ## What Cannot Be Fully Declarative

      Some Home Assistant configurations require UI setup and cannot be fully
      declared in NixOS:

      - **OAuth Integrations**: Google Nest, BMW ConnectedDrive, Google Assistant SDK
      - **Device Pairing**: August locks, Ring devices, Bluetooth devices
      - **API Tokens**: Generated during initial setup
      - **Entity Customizations**: Friendly names, icons, areas

      These are backed up in the `.storage/` directory and can be restored.

      ## Best Practices

      1. **Commit Regularly**: Add backup to git after making changes
      2. **Test Restoration**: Periodically test restoration process
      3. **Keep Archives**: Don't delete timestamped backup archives
      4. **Document Changes**: Use git commit messages to describe changes
      5. **Backup Secrets**: Ensure SOPS secrets are backed up separately

      ## Integration with NixOS

      This backup system integrates with your declarative NixOS configuration.
      The systemd units are defined in:
      `/etc/nixos/modules/services/home-assistant-backup.nix`

      Your NixOS configuration declares the system, and this backup preserves
      the user-level configuration from the Home Assistant UI.
    '';
    mode = "0644";
  };
}
