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

    # Validate config syntax at build time without checking file existence
    # (token files referenced in scrape configs may not exist during build)
    checkConfig = "syntax-only";

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
      # Number of daily snapshots to retain
      RETENTION_COUNT=2

      # Create snapshot via admin API
      echo "Creating TSDB snapshot..."
      RESPONSE=$(curl -sf -X POST "http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot")
      SNAPSHOT_NAME=$(echo "$RESPONSE" | jq -r '.data.name')

      if [ -z "$SNAPSHOT_NAME" ] || [ "$SNAPSHOT_NAME" = "null" ]; then
        echo "ERROR: Failed to create snapshot. Response: $RESPONSE"
        exit 1
      fi

      echo "Snapshot created: $SNAPSHOT_NAME"

      # Hard-link the snapshot into the disaster-recovery directory.
      # Prometheus TSDB blocks are immutable once written, so hard links
      # across DR snapshots are safe and share the underlying chunks,
      # reducing disk usage from N*TSDB_size to ~TSDB_size + deltas.
      mkdir -p "$SNAPSHOT_DIR"
      DEST="$SNAPSHOT_DIR/snapshot-$(date +%Y%m%d-%H%M%S)"
      cp -al "$TSDB_DIR/snapshots/$SNAPSHOT_NAME" "$DEST"
      echo "Hard-linked to: $DEST"

      # Clean up the in-TSDB snapshot (we retain the DR copy)
      rm -rf "$TSDB_DIR/snapshots/$SNAPSHOT_NAME"

      # Keep only the $RETENTION_COUNT newest snapshots (deterministic,
      # avoids off-by-one pitfalls of `find -mtime`).
      echo "Retaining $RETENTION_COUNT newest snapshots..."
      # shellcheck disable=SC2012
      ls -1dt "$SNAPSHOT_DIR"/snapshot-* 2>/dev/null \
        | tail -n +$((RETENTION_COUNT + 1)) \
        | xargs -r rm -rf

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
