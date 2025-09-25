{ config, lib, pkgs, ... }:

{
  # Add sops secret for Gmail password
    sops.secrets."carmichael-imap-gmail-com" = {
      owner = "assembly";
      group = "assembly";
      mode = "0400";
    };

  # Create mbsync configuration directory
  systemd.tmpfiles.rules = [
    "d /var/lib/mbsync 0755 assembly assembly -"
    "d /var/log/mbsync 0755 assembly assembly -"
  ];

  # mbsync configuration file
  environment.etc."mbsync/mbsyncrc".text = ''
    # Gmail IMAP Account
    IMAPAccount gmail-account
    Host imap.gmail.com
    User carmichaellsa@gmail.com
    PassCmd "cat /run/secrets/carmichael-imap-gmail-com"
    Port 993
    TLSType IMAPS
    CertificateFile /etc/ssl/certs/ca-certificates.crt

    IMAPStore gmail-remote
    Account gmail-account

    # Local Dovecot Account via tunnel - no network connection needed
    IMAPAccount dovecot-assembly
    Tunnel "${pkgs.dovecot}/libexec/dovecot/imap -c /etc/dovecot/dovecot.conf"

    IMAPStore dovecot-local
    Account dovecot-assembly

    # Sync Channel
    Channel assembly-sync
    Far :gmail-remote:
    Near :dovecot-local:
    Patterns * !"[Gmail]/All Mail" !"[Gmail]/Important" !"[Gmail]/Starred" !"[Gmail]/Bin" !"[Gmail]/Spam"
    Create Near
    Remove None
    Expunge None
    CopyArrivalDate yes
    Sync Pull
    SyncState /var/lib/mbsync/

    # Group definition
    Group assembly
    Channel assembly-sync
  '';

  # mbsync service
  systemd.services.mbsync-assembly = {
    description = "Mail synchronization for assembly user (Gmail to Dovecot)";
    after = [ "network-online.target" "dovecot2.service" ];
    wants = [ "network-online.target" ];
    requires = [ "dovecot2.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "assembly";
      Group = "assembly";

      # Run mbsync with proper configuration
      ExecStart = let
        mbsyncScript = pkgs.writeShellScript "mbsync-run" ''
          set -euo pipefail

          # Export environment for logging
          export MBSYNC_LOG="/var/log/mbsync/sync.log"
          export MBSYNC_STATE="/var/lib/mbsync"
          export USER="assembly"
          export HOME="/home/assembly"

          # Log start time
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting mbsync synchronization..." >> "$MBSYNC_LOG"

          # Create state directory if it doesn't exist
          mkdir -p "$MBSYNC_STATE"

          # Run mbsync (without verbose flag) and capture output
          MBSYNC_OUTPUT=$(${pkgs.isync}/bin/mbsync -c /etc/mbsync/mbsyncrc assembly 2>&1)
          MBSYNC_EXIT=$?

          # Extract summary line (Channels/Boxes/Far/Near)
          SUMMARY=$(echo "$MBSYNC_OUTPUT" | grep "^Channels:" || echo "")

          # Check for errors and warnings
          ERRORS=$(echo "$MBSYNC_OUTPUT" | grep -i "error" || true)
          WARNINGS=$(echo "$MBSYNC_OUTPUT" | grep -i "warning" || true)

          # Log summary and any errors/warnings
          if [ -n "$SUMMARY" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync summary: $SUMMARY" >> "$MBSYNC_LOG"
          fi

          if [ -n "$ERRORS" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Errors detected:" >> "$MBSYNC_LOG"
            echo "$ERRORS" >> "$MBSYNC_LOG"
          fi

          if [ -n "$WARNINGS" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warnings detected:" >> "$MBSYNC_LOG"
            echo "$WARNINGS" >> "$MBSYNC_LOG"
          fi

          if [ $MBSYNC_EXIT -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Synchronization completed successfully" >> "$MBSYNC_LOG"

            # Update success metrics
            echo "mbsync_last_success_timestamp $(date +%s)" > /var/lib/mbsync/metrics
            echo "mbsync_sync_status 1" >> /var/lib/mbsync/metrics

            # Count synced messages
            INBOX_COUNT=$(${pkgs.dovecot}/bin/doveadm mailbox status -u assembly messages INBOX 2>/dev/null | awk '{print $2}' || echo 0)
            echo "mbsync_inbox_messages $INBOX_COUNT" >> /var/lib/mbsync/metrics

            exit 0
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Synchronization failed with exit code $MBSYNC_EXIT" >> "$MBSYNC_LOG"

            # Update failure metrics
            echo "mbsync_last_failure_timestamp $(date +%s)" > /var/lib/mbsync/metrics
            echo "mbsync_sync_status 0" >> /var/lib/mbsync/metrics

            exit 1
          fi
        '';
      in toString mbsyncScript;

      # Restart policy
      Restart = "on-failure";
      RestartSec = "5min";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "/var/lib/mbsync" "/var/log/mbsync" "/home/assembly/mdbox" ];
      NoNewPrivileges = true;

      # Resource limits
      TimeoutStartSec = "30min";  # Allow up to 30 minutes for sync
      CPUQuota = "50%";  # Limit CPU usage
    };

    # Set up path to sops secrets
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.dovecot ];
  };

  # Timer for hourly runs
  systemd.timers.mbsync-assembly = {
    description = "Hourly mail synchronization for assembly user";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "10min";  # Run 10 minutes after boot
      OnUnitActiveSec = "1h";  # Run every hour
      RandomizedDelaySec = "5min";  # Add some randomization to prevent thundering herd
      Persistent = true;  # Catch up on missed runs
      Unit = "mbsync-assembly.service";
    };
  };

  # Health check service
  systemd.services.mbsync-health-check = {
    description = "Check mbsync health and alert on failures";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "assembly";
      ExecStart = pkgs.writeShellScript "mbsync-health-check" ''
        set -euo pipefail

        METRICS_FILE="/var/lib/mbsync/metrics"
        MAX_AGE_SECONDS=7200  # Alert if last sync was more than 2 hours ago

        # Check if metrics file exists
        if [ ! -f "$METRICS_FILE" ]; then
          echo "ERROR: No mbsync metrics found. Service may never have run." | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-health
          exit 1
        fi

        # Check last successful sync time
        LAST_SUCCESS=$(grep "mbsync_last_success_timestamp" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        CURRENT_TIME=$(date +%s)
        AGE=$((CURRENT_TIME - LAST_SUCCESS))

        if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
          echo "ERROR: Last successful sync was $((AGE / 3600)) hours ago" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-health

          # Check if service is running
          if ! ${pkgs.systemd}/bin/systemctl is-active --quiet mbsync-assembly.service; then
            echo "mbsync-assembly service is not running" | ${pkgs.systemd}/bin/systemd-cat -p warning -t mbsync-health
          fi

          # Check last failure
          LAST_FAILURE=$(grep "mbsync_last_failure_timestamp" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
          if [ "$LAST_FAILURE" -gt "$LAST_SUCCESS" ]; then
            echo "Recent sync failure detected at $(date -d @$LAST_FAILURE)" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-health

            # Show recent errors from log
            if [ -f /var/log/mbsync/sync.log ]; then
              echo "Recent errors:" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-health
              tail -20 /var/log/mbsync/sync.log | grep -i error | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-health
            fi
          fi

          exit 1
        fi

        # Check sync status
        SYNC_STATUS=$(grep "mbsync_sync_status" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        if [ "$SYNC_STATUS" -eq 0 ]; then
          echo "WARNING: Last sync failed" | ${pkgs.systemd}/bin/systemd-cat -p warning -t mbsync-health
        else
          echo "mbsync health check passed. Last sync: $((AGE / 60)) minutes ago" | ${pkgs.systemd}/bin/systemd-cat -t mbsync-health
        fi
      '';
    };

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.systemd ];
  };

  # Timer for health checks (every 30 minutes)
  systemd.timers.mbsync-health-check = {
    description = "Regular mbsync health checks";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "30min";
      Unit = "mbsync-health-check.service";
    };
  };

  # Prometheus exporter for mbsync metrics
  systemd.services.mbsync-metrics-exporter = {
    description = "Export mbsync metrics for Prometheus";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "assembly";
      Group = "assembly";
      Restart = "always";
      RestartSec = "10s";

      ExecStart = pkgs.writeShellScript "mbsync-metrics-server" ''
        #!/usr/bin/env bash
        set -euo pipefail

        PORT=9280
        METRICS_FILE="/var/lib/mbsync/metrics"

        # Simple HTTP server using netcat
        while true; do
          {
            # Read metrics or provide defaults
            if [ -f "$METRICS_FILE" ]; then
              METRICS=$(cat "$METRICS_FILE")
            else
              METRICS="mbsync_sync_status 0"
            fi

            # Add help text and type information
            RESPONSE="# HELP mbsync_sync_status Whether the last sync was successful (1) or failed (0)
# TYPE mbsync_sync_status gauge
# HELP mbsync_last_success_timestamp Unix timestamp of last successful sync
# TYPE mbsync_last_success_timestamp gauge
# HELP mbsync_last_failure_timestamp Unix timestamp of last failed sync
# TYPE mbsync_last_failure_timestamp gauge
# HELP mbsync_inbox_messages Number of messages in INBOX
# TYPE mbsync_inbox_messages gauge
$METRICS"

            # Send HTTP response
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$RESPONSE"
          } | ${pkgs.netcat}/bin/nc -l -p "$PORT" -q 1
        done
      '';

      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = [ "/var/lib/mbsync/metrics" ];
    };

    path = [ pkgs.coreutils pkgs.netcat ];
  };

  # Add mbsync monitoring to Prometheus
  services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
    {
      job_name = "mbsync";
      static_configs = [{
        targets = [ "localhost:9280" ];
        labels = {
          service = "mbsync";
          user = "assembly";
        };
      }];
      scrape_interval = "60s";
    }
  ];

  # Log rotation for mbsync logs
  services.logrotate.settings.mbsync = {
    files = "/var/log/mbsync/*.log";
    su = "assembly assembly";
    frequency = "weekly";
    rotate = 4;
    compress = true;
    delaycompress = true;
    missingok = true;
    notifempty = true;
    create = "0644 assembly assembly";
    postrotate = ''
      ${pkgs.systemd}/bin/systemctl reload rsyslog 2>/dev/null || true
    '';
  };

  # Open firewall port for metrics exporter (internal only)
  networking.firewall.interfaces.lo.allowedTCPPorts = [ 9280 ];

  # Install isync package
  environment.systemPackages = [ pkgs.isync ];
}
