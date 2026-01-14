{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Script to monitor Home Assistant backups and export metrics
  backupMonitorScript = pkgs.writeShellScriptBin "home-assistant-backup-monitor" ''
    set -euo pipefail

    BACKUP_DIR="/var/lib/hass/backups"
    METRICS_DIR="/var/lib/prometheus-node-exporter-textfiles"
    METRICS_FILE="''${METRICS_DIR}/home_assistant_backup.prom"
    TEMP_FILE="''${METRICS_FILE}.$$"

    # Ensure metrics directory exists
    mkdir -p "''${METRICS_DIR}"

    # Initialize metrics
    echo "# HELP home_assistant_backup_count Total number of Home Assistant backup files" > "''${TEMP_FILE}"
    echo "# TYPE home_assistant_backup_count gauge" >> "''${TEMP_FILE}"

    echo "# HELP home_assistant_backup_size_bytes Size of Home Assistant backup file in bytes" >> "''${TEMP_FILE}"
    echo "# TYPE home_assistant_backup_size_bytes gauge" >> "''${TEMP_FILE}"

    echo "# HELP home_assistant_backup_age_seconds Age of Home Assistant backup file in seconds" >> "''${TEMP_FILE}"
    echo "# TYPE home_assistant_backup_age_seconds gauge" >> "''${TEMP_FILE}"

    echo "# HELP home_assistant_backup_latest_timestamp Unix timestamp of the most recent backup" >> "''${TEMP_FILE}"
    echo "# TYPE home_assistant_backup_latest_timestamp gauge" >> "''${TEMP_FILE}"

    echo "# HELP home_assistant_backup_total_size_bytes Total size of all backup files in bytes" >> "''${TEMP_FILE}"
    echo "# TYPE home_assistant_backup_total_size_bytes gauge" >> "''${TEMP_FILE}"

    # Check if backup directory exists
    if [ ! -d "''${BACKUP_DIR}" ]; then
      echo "home_assistant_backup_count 0" >> "''${TEMP_FILE}"
      echo "home_assistant_backup_total_size_bytes 0" >> "''${TEMP_FILE}"
      echo "home_assistant_backup_latest_timestamp 0" >> "''${TEMP_FILE}"
      mv "''${TEMP_FILE}" "''${METRICS_FILE}"
      exit 0
    fi

    # Count backup files
    backup_count=$(find "''${BACKUP_DIR}" -name "*.tar" -type f 2>/dev/null | wc -l)
    echo "home_assistant_backup_count ''${backup_count}" >> "''${TEMP_FILE}"

    # Calculate total size
    total_size=0
    latest_timestamp=0
    current_time=$(date +%s)

    # Process each backup file
    while IFS= read -r -d "" backup_file; do
      filename=$(basename "''${backup_file}")
      size=$(stat -c %s "''${backup_file}" 2>/dev/null || echo 0)
      mtime=$(stat -c %Y "''${backup_file}" 2>/dev/null || echo 0)
      age=$((current_time - mtime))

      # Update latest timestamp
      if [ "''${mtime}" -gt "''${latest_timestamp}" ]; then
        latest_timestamp=''${mtime}
      fi

      # Add to total size
      total_size=$((total_size + size))

      # Export per-file metrics
      echo "home_assistant_backup_size_bytes{backup=\"''${filename}\"} ''${size}" >> "''${TEMP_FILE}"
      echo "home_assistant_backup_age_seconds{backup=\"''${filename}\"} ''${age}" >> "''${TEMP_FILE}"
    done < <(find "''${BACKUP_DIR}" -name "*.tar" -type f -print0 2>/dev/null)

    # Export aggregate metrics
    echo "home_assistant_backup_total_size_bytes ''${total_size}" >> "''${TEMP_FILE}"
    echo "home_assistant_backup_latest_timestamp ''${latest_timestamp}" >> "''${TEMP_FILE}"

    # Atomically update metrics file
    mv "''${TEMP_FILE}" "''${METRICS_FILE}"

    # Set proper permissions
    chown node-exporter:node-exporter "''${METRICS_FILE}"
    chmod 644 "''${METRICS_FILE}"
  '';
in
{
  # Systemd service to monitor Home Assistant backups
  systemd.services.home-assistant-backup-monitor = {
    description = "Home Assistant Backup Metrics Exporter";
    after = [ "network.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${backupMonitorScript}/bin/home-assistant-backup-monitor";
      User = "root";
      Group = "root";

      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
      ReadOnlyPaths = [ "/var/lib/hass/backups" ];
    };
  };

  # Timer to run the monitor every 5 minutes
  systemd.timers.home-assistant-backup-monitor = {
    description = "Timer for Home Assistant Backup Metrics Exporter";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "1min";
      OnCalendar = "*:0/5"; # Every 5 minutes on the clock
      Persistent = true;
    };
  };

  # Ensure node_exporter textfile collector directory exists
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus-node-exporter-textfiles 0755 node-exporter node-exporter -"
  ];

  # Documentation
  environment.etc."prometheus/home-assistant-backup-exporter-README.md" = {
    text = ''
      # Home Assistant Backup Metrics Exporter

      ## Overview
      This module monitors Home Assistant backup files and exports metrics to Prometheus
      via the node_exporter textfile collector.

      ## Metrics Exported

      ### Per-Backup Metrics
      - `home_assistant_backup_size_bytes{backup="filename.tar"}` - Size of individual backup file
      - `home_assistant_backup_age_seconds{backup="filename.tar"}` - Age of backup file in seconds

      ### Aggregate Metrics
      - `home_assistant_backup_count` - Total number of backup files
      - `home_assistant_backup_total_size_bytes` - Total size of all backups
      - `home_assistant_backup_latest_timestamp` - Unix timestamp of most recent backup

      ## Configuration
      - **Backup Directory**: `/var/lib/hass/backups`
      - **Metrics File**: `/var/lib/prometheus-node-exporter-textfiles/home_assistant_backup.prom`
      - **Update Interval**: Every 5 minutes

      ## Monitoring

      The metrics are collected via:
      1. Systemd timer runs every 5 minutes
      2. Script scans backup directory
      3. Exports metrics to textfile collector
      4. Node exporter includes metrics in its endpoint
      5. Prometheus scrapes from node_exporter

      ## Manual Operations

      ### Trigger Manual Update
      ```bash
      sudo systemctl start home-assistant-backup-monitor.service
      ```

      ### Check Service Status
      ```bash
      sudo systemctl status home-assistant-backup-monitor.service
      sudo systemctl status home-assistant-backup-monitor.timer
      ```

      ### View Current Metrics
      ```bash
      cat /var/lib/prometheus-node-exporter-textfiles/home_assistant_backup.prom
      ```

      ### View in Prometheus
      Access Prometheus: https://prometheus.vulcan.lan

      Example queries:
      ```promql
      # Total number of backups
      home_assistant_backup_count

      # Age of most recent backup (in hours)
      (time() - home_assistant_backup_latest_timestamp) / 3600

      # Total backup storage used
      home_assistant_backup_total_size_bytes / 1024 / 1024

      # Largest backup file
      max(home_assistant_backup_size_bytes)

      # List all backups with their ages
      home_assistant_backup_age_seconds
      ```

      ## Alert Rules
      See `/etc/nixos/modules/monitoring/alerts/home-assistant-backup.yaml`

      Alerts monitor for:
      - Backup not running (no new backup in 25 hours)
      - Backup size anomaly (too small or too large)
      - No backups present
      - Backup age exceeding threshold

      ## Troubleshooting

      ### Check logs
      ```bash
      sudo journalctl -u home-assistant-backup-monitor.service -f
      ```

      ### Verify backup directory
      ```bash
      ls -lh /var/lib/hass/backups/
      ```

      ### Test metric collection
      ```bash
      sudo systemctl start home-assistant-backup-monitor.service
      cat /var/lib/prometheus-node-exporter-textfiles/home_assistant_backup.prom
      ```
    '';
    mode = "0644";
  };
}
