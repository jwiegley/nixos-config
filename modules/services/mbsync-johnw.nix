{ config, lib, pkgs, ... }:

{
  # Add sops secret for Fastmail password
  sops.secrets."johnw-fastmail-password" = {
    owner = "johnw";
    group = "users";
    mode = "0400";
  };

  # Create mbsync configuration directory for johnw
  systemd.tmpfiles.rules = [
    "d /var/lib/mbsync-johnw 0755 johnw users -"
    "d /var/log/mbsync-johnw 0755 johnw users -"
  ];

  # mbsync configuration file for johnw user
  environment.etc."mbsync/mbsyncrc-johnw".text = ''
    # Fastmail IMAP Account
    IMAPAccount fastmail
    Host imap.fastmail.com
    User johnw@newartisans.com
    PassCmd "cat /run/secrets/johnw-fastmail-password"
    TLSType IMAPS
    CertificateFile /etc/ssl/certs/ca-certificates.crt
    Port 993
    PipelineDepth 1

    IMAPStore fastmail-remote
    Account fastmail
    PathDelimiter /
    Trash Trash

    # Local Dovecot Account via tunnel
    IMAPAccount dovecot
    Tunnel "${pkgs.dovecot}/libexec/dovecot/imap -c /etc/dovecot/dovecot.conf"

    IMAPStore dovecot-local
    Account dovecot
    PathDelimiter /
    Trash mail.trash

    # Sync all folders from Fastmail (pull only)
    Channel personal-all
    Far :fastmail-remote:
    Near :dovecot-local:
    Patterns *
    Create Near
    Remove None
    Expunge None
    CopyArrivalDate yes
    Sync Pull
    SyncState /var/lib/mbsync-johnw/

    # Group definition
    Group personal
    Channel personal-all
  '';

  # mbsync service for johnw user
  systemd.services.mbsync-johnw = {
    description = "Mail synchronization for johnw user (Fastmail to Dovecot)";
    after = [ "network-online.target" "dovecot.service" ];
    wants = [ "network-online.target" "dovecot.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "johnw";
      Group = "users";

      # Run mbsync with proper configuration
      ExecStart = let
        mbsyncScript = pkgs.writeShellScript "mbsync-johnw-run" ''
          set -euo pipefail

          # Export environment for logging
          export MBSYNC_LOG="/var/log/mbsync-johnw/sync.log"
          export MBSYNC_STATE="/var/lib/mbsync-johnw"
          export USER="johnw"
          export HOME="/home/johnw"

          # Log start time
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting mbsync synchronization for johnw..." >> "$MBSYNC_LOG"

          # Create state directory if it doesn't exist
          mkdir -p "$MBSYNC_STATE"

          # Run mbsync (without verbose flag) and capture output
          MBSYNC_OUTPUT=$(${pkgs.isync}/bin/mbsync -c /etc/mbsync/mbsyncrc-johnw personal 2>&1)
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
            echo "mbsync_johnw_last_success_timestamp $(date +%s)" > /var/lib/mbsync-johnw/metrics
            echo "mbsync_johnw_sync_status 1" >> /var/lib/mbsync-johnw/metrics

            # Count synced messages
            INBOX_COUNT=$(${pkgs.dovecot}/bin/doveadm mailbox status -u johnw messages INBOX 2>/dev/null | awk '{print $2}' || echo 0)
            echo "mbsync_johnw_inbox_messages $INBOX_COUNT" >> /var/lib/mbsync-johnw/metrics

            exit 0
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Synchronization failed with exit code $MBSYNC_EXIT" >> "$MBSYNC_LOG"

            # Update failure metrics
            echo "mbsync_johnw_last_failure_timestamp $(date +%s)" > /var/lib/mbsync-johnw/metrics
            echo "mbsync_johnw_sync_status 0" >> /var/lib/mbsync-johnw/metrics

            exit 1
          fi
        '';
      in toString mbsyncScript;

      # Restart policy
      Restart = "on-failure";
      RestartSec = "30min";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [
        "/var/lib/mbsync-johnw"
        "/var/log/mbsync-johnw"
        "/tank/Maildir/johnw"
      ];
      NoNewPrivileges = true;

      # Resource limits
      TimeoutStartSec = "30min";  # Allow up to 30 minutes for sync
      CPUQuota = "50%";  # Limit CPU usage
    };

    # Set up path to sops secrets
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.dovecot ];
  };

  # Timer for daily runs
  systemd.timers.mbsync-johnw = {
    description = "Daily mail synchronization for johnw user";
    # wantedBy = [ "timers.target" ];  # Manually enable after testing

    timerConfig = {
      OnCalendar = "*-*-* 01:00:00";  # Run at 1 AM daily
      RandomizedDelaySec = "1h";  # Add some randomization
      Persistent = true;  # Catch up on missed runs
      Unit = "mbsync-johnw.service";
    };
  };

  # Health check service for johnw mbsync
  systemd.services.mbsync-johnw-health-check = {
    description = "Check mbsync health for johnw user";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "johnw";
      ExecStart = pkgs.writeShellScript "mbsync-johnw-health-check" ''
        set -euo pipefail

        METRICS_FILE="/var/lib/mbsync-johnw/metrics"
        MAX_AGE_SECONDS=172800  # Alert if last sync was more than 48 hours ago (daily sync)

        # Check if metrics file exists
        if [ ! -f "$METRICS_FILE" ]; then
          echo "ERROR: No mbsync metrics found for johnw. Service may never have run." | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-johnw-health
          exit 1
        fi

        # Check last successful sync time
        LAST_SUCCESS=$(grep "mbsync_johnw_last_success_timestamp" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        CURRENT_TIME=$(date +%s)
        AGE=$((CURRENT_TIME - LAST_SUCCESS))

        if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
          echo "ERROR: Last successful sync was $((AGE / 3600)) hours ago" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-johnw-health

          # Check if service is running
          if ! ${pkgs.systemd}/bin/systemctl is-active --quiet mbsync-johnw.service; then
            echo "mbsync-johnw service is not running" | ${pkgs.systemd}/bin/systemd-cat -p warning -t mbsync-johnw-health
          fi

          # Check last failure
          LAST_FAILURE=$(grep "mbsync_johnw_last_failure_timestamp" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
          if [ "$LAST_FAILURE" -gt "$LAST_SUCCESS" ]; then
            echo "Recent sync failure detected at $(date -d @$LAST_FAILURE)" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-johnw-health

            # Show recent errors from log
            if [ -f /var/log/mbsync-johnw/sync.log ]; then
              echo "Recent errors:" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-johnw-health
              tail -20 /var/log/mbsync-johnw/sync.log | grep -i error | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-johnw-health
            fi
          fi

          exit 1
        fi

        # Check sync status
        SYNC_STATUS=$(grep "mbsync_johnw_sync_status" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        if [ "$SYNC_STATUS" -eq 0 ]; then
          echo "WARNING: Last sync failed" | ${pkgs.systemd}/bin/systemd-cat -p warning -t mbsync-johnw-health
        else
          echo "mbsync health check passed. Last sync: $((AGE / 3600)) hours ago" | ${pkgs.systemd}/bin/systemd-cat -t mbsync-johnw-health
        fi
      '';
    };

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.systemd ];
  };

  # Timer for health checks (every 12 hours)
  systemd.timers.mbsync-johnw-health-check = {
    description = "Regular mbsync health checks for johnw";
    # wantedBy = [ "timers.target" ];  # Manually enable after testing

    timerConfig = {
      OnBootSec = "20min";
      OnUnitActiveSec = "12h";
      Unit = "mbsync-johnw-health-check.service";
    };
  };

  # Log rotation for mbsync johnw logs
  services.logrotate.settings.mbsync-johnw = {
    files = "/var/log/mbsync-johnw/*.log";
    su = "johnw users";
    frequency = "weekly";
    rotate = 4;
    compress = true;
    delaycompress = true;
    missingok = true;
    notifempty = true;
    create = "0644 johnw users";
    postrotate = ''
      ${pkgs.systemd}/bin/systemctl reload rsyslog 2>/dev/null || true
    '';
  };

  # Install isync package
  environment.systemPackages = [ pkgs.isync ];
}
