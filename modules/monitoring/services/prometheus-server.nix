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

    # Effectively "keep everything". MOVED HERE 2026-08-05 from
    # modules/options/default.nix, which was a 368-line options framework with
    # zero consumers -- and was nonetheless the SOLE definer of this value,
    # because its config block was gated only on an option defaulting to true.
    # That made the framework a trap rather than dead code: deleting it as the
    # obvious cleanup would have silently reverted retention to the 15-day
    # upstream default and destroyed the history, with no build error. Everything
    # else that framework set (prometheus.enable, scrape_interval,
    # podman.enable/dockerCompat) was already defined in the module that owns it,
    # verified by evaluating each before and after the deletion.
    retentionTime = "100y";
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

    # Alert rules are loaded by monitoring/services/alerting.nix (auto-discovers from alerts/)
    #
    # Alertmanager registration REMOVED here 2026-07-28: it was declared in BOTH this file
    # and modules/services/alertmanager.nix, so Prometheus held two entries for the same
    # Alertmanager. The one in alertmanager.nix is the better survivor -- it sets
    # `scheme = "http"` explicitly and derives the port from
    # config.services.prometheus.alertmanager.port rather than hardcoding 9093, so it
    # cannot drift if that port is ever changed. Keeping the registration next to the
    # Alertmanager service definition is also where a reader would look for it.
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

      # Wait for Prometheus to actually be READY before snapshotting.
      #
      # Added 2026-07-29 after this unit failed with status=7/NOTRUNNING: the timer fired
      # while Prometheus was restarting during a nixos-rebuild switch, curl could not
      # connect, and `set -euo pipefail` aborted the whole job. Requires=prometheus.service
      # is NOT sufficient -- systemd considers the unit started as soon as the process
      # execs, but Prometheus needs to replay its WAL before the admin API answers, and on
      # this host that window is long enough for the timer to land inside it.
      #
      # This is the same readiness-vs-liveness distinction already fixed elsewhere in this
      # config (cloudflared waiting on technitium, immich gated on its mount): "the unit is
      # active" and "the service can serve a request" are different claims.
      echo "Waiting for the Prometheus admin API to become ready..."
      READY=0
      for _ in $(seq 1 30); do
        if curl -sf -o /dev/null "http://127.0.0.1:9090/-/ready"; then
          READY=1
          break
        fi
        sleep 10
      done
      if [ "$READY" -ne 1 ]; then
        echo "ERROR: Prometheus admin API not ready after 5 minutes; skipping this run."
        echo "This is a genuine failure (the snapshot did NOT happen), not a transient."
        exit 1
      fi

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
      - custom.yaml: Custom site-specific alerts (optional)

      NOTE: Home Assistant safety/security/energy alerting is NOT in Prometheus.
      HA telemetry is pushed to VictoriaMetrics (InfluxDB protocol), never scraped
      into Prometheus, so homeassistant_* rules here could never fire. That alerting
      lives in Node-RED (event-driven, can also remediate). See docs/HOME_ASSISTANT_ALERTING.md.

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
      Audio, Backups, Databases, Documents, Home, Photos, Public, Video, doc, src

      Metrics are updated every 6 hours via systemd timer.
      To manually refresh: systemctl start restic-metrics.service
    '';
    mode = "0644";
  };
}
