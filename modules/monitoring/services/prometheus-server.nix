{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Core Prometheus server configuration
  services.prometheus = {
    enable = true;
    port = 9090;

    # Disable config check since token files may not exist at build time
    checkConfig = false;

    # Only listen on localhost for now
    listenAddress = "127.0.0.1";

    # Enable admin API and data durability features
    extraFlags = [
      "--web.enable-admin-api"
      "--web.external-url=https://prometheus.vulcan.lan"
      # WAL compression reduces size ~50%, directly reducing WAL replay memory
      "--storage.tsdb.wal-compression"
      # Memory snapshot on shutdown: saves in-memory state to disk during graceful
      # shutdown, allowing restart to SKIP WAL replay entirely. This is the key
      # protection against OOM during WAL replay.
      "--enable-feature=memory-snapshot-on-shutdown"
    ];

    # Global configuration
    globalConfig = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
      external_labels = {
        monitor = "vulcan";
        environment = "production";
      };
    };

    # Alert rules are loaded by prometheus-alerting.nix (auto-discovers from alerts/)

    # Alertmanager configuration
    alertmanagers = lib.mkIf config.services.prometheus.alertmanager.enable [
      {
        static_configs = [
          {
            targets = [ "localhost:9093" ];
          }
        ];
      }
    ];
  };

  # OOM protection and service hardening
  systemd.services.prometheus.serviceConfig = {
    # Protect Prometheus from OOM killer (-1000 to 1000, lower = less likely to kill)
    # This makes Prometheus one of the last processes to be killed under memory pressure
    OOMScoreAdjust = -500;
    # Memory limits - set high enough to accommodate WAL replay (2.5-3x steady state)
    # Current steady state is ~500MB, so 2G provides significant headroom
    MemoryMax = "2G";
    MemoryHigh = "1.5G";
    # Ensure graceful shutdown has time to write memory snapshot (default 90s)
    TimeoutStopSec = "120s";
  };

  # Daily TSDB snapshot for disaster recovery
  # If TSDB is corrupted, restore from snapshot to limit data loss to ~1 day
  systemd.services.prometheus-snapshot = {
    description = "Create Prometheus TSDB snapshot for disaster recovery";
    after = [ "prometheus.service" ];
    requires = [ "prometheus.service" ];
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "prometheus";
      Group = "prometheus";
    };

    script = ''
      set -euo pipefail

      SNAPSHOT_DIR="/var/lib/prometheus2/disaster-recovery"
      TSDB_DIR="/var/lib/prometheus2/data"
      RETENTION_DAYS=7

      # Create snapshot via admin API
      echo "Creating TSDB snapshot..."
      RESPONSE=$(curl -sf -X POST "http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot")
      SNAPSHOT_NAME=$(echo "$RESPONSE" | jq -r '.data.name')

      if [ -z "$SNAPSHOT_NAME" ] || [ "$SNAPSHOT_NAME" = "null" ]; then
        echo "ERROR: Failed to create snapshot. Response: $RESPONSE"
        exit 1
      fi

      echo "Snapshot created: $SNAPSHOT_NAME"

      # Copy snapshot to disaster recovery location (separate from main TSDB)
      mkdir -p "$SNAPSHOT_DIR"
      DEST="$SNAPSHOT_DIR/snapshot-$(date +%Y%m%d-%H%M%S)"
      cp -a "$TSDB_DIR/snapshots/$SNAPSHOT_NAME" "$DEST"
      echo "Copied to: $DEST"

      # Clean up the in-TSDB snapshot (we have our copy)
      rm -rf "$TSDB_DIR/snapshots/$SNAPSHOT_NAME"

      # Remove snapshots older than retention period
      echo "Cleaning snapshots older than $RETENTION_DAYS days..."
      find "$SNAPSHOT_DIR" -maxdepth 1 -name "snapshot-*" -type d -mtime +$RETENTION_DAYS -exec rm -rf {} \; || true

      # Report current snapshots
      echo "Current snapshots:"
      ls -la "$SNAPSHOT_DIR"
    '';
  };

  systemd.timers.prometheus-snapshot = {
    description = "Daily Prometheus TSDB snapshot timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Ensure prometheus user can access git-workspace-archive directory
  users.users.prometheus.extraGroups = [ "johnw" ];

  # Firewall configuration for Prometheus server
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.port
  ];

  # Documentation
  environment.etc."prometheus/README.md" = {
    text = ''
      # Prometheus Monitoring Configuration

      ## Alert Rules
      Alert rules are stored in `/etc/nixos/modules/monitoring/alerts/`:
      - system.yaml: System-level alerts (CPU, memory, disk)
      - systemd.yaml: Systemd service health and state alerts
      - database.yaml: Database-specific alerts
      - storage.yaml: Storage and backup alerts
      - certificates.yaml: Certificate expiration alerts
      - home-assistant.yaml: Home Assistant IoT device alerts (security, safety, energy)
      - custom.yaml: Custom site-specific alerts (optional)

      ## Useful Commands
      - `validate-alerts`: Validate alert rule syntax
      - `reload-prometheus`: Reload Prometheus configuration

      ## Adding Custom Alerts
      Create `/etc/nixos/modules/monitoring/alerts/custom.yaml` with your custom rules.
      The file will be automatically loaded if it exists.

      ## Metrics Endpoints
      - Prometheus: http://localhost:9090
      - Node Exporter: http://localhost:9100/metrics
        - Includes textfile collector for custom metrics (restic, etc.)
      - PostgreSQL Exporter: http://localhost:9187/metrics
      - Systemd Exporter: http://localhost:9558/metrics
      - Dovecot Exporter: http://localhost:9166/metrics
      - Postfix Exporter: http://localhost:9154/metrics
      - ZFS Exporter: http://localhost:9134/metrics
      - Blackbox Exporter: http://localhost:9115/metrics

      ## Restic Monitoring
      Restic metrics are collected via textfile collector for all repositories:
      Audio, Backups, Databases, Home, Nasim, Photos, Video, doc, src

      Metrics are updated every 6 hours via systemd timer.
      To manually refresh: systemctl start restic-metrics.service
    '';
    mode = "0644";
  };
}
