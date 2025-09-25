{ config, lib, pkgs, ... }:

{
  # Add sops secret for Gmail password
  sops.secrets."carmichael-imap-gmail-com" = {
    owner = "assembly";
    group = "assembly";
    mode = "0400";
  };

  # Create mbsync configuration directory for assembly
  systemd.tmpfiles.rules = [
    "d /var/lib/mbsync-assembly 0755 assembly assembly -"
    "d /var/log/mbsync-assembly 0755 assembly assembly -"
  ];

  # mbsync configuration file for assembly user
  environment.etc."mbsync/mbsyncrc-assembly".text = ''
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
    SyncState /var/lib/mbsync-assembly/

    # Group definition
    Group assembly
    Channel assembly-sync
  '';

  # mbsync service for assembly user
  systemd.services.mbsync-assembly = {
    # Prevent service from running during nixos-rebuild switch
    restartIfChanged = false;
    stopIfChanged = false;
    description = "Mail synchronization for assembly user (Gmail to Dovecot)";
    after = [ "network-online.target" "dovecot2.service" ];
    wants = [ "network-online.target" ];
    requires = [ "dovecot2.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "assembly";
      Group = "assembly";

      # Run mbsync with proper configuration
      ExecStart = let
        mbsyncScript = pkgs.writeShellScript "mbsync-assembly-run" ''
          set -euo pipefail

          # Export environment for logging
          export MBSYNC_LOG="/var/log/mbsync-assembly/sync.log"
          export MBSYNC_STATE="/var/lib/mbsync-assembly"
          export USER="assembly"
          export HOME="/home/assembly"

          # Log start time
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting mbsync synchronization for assembly..." >> "$MBSYNC_LOG"

          # Create state directory if it doesn't exist
          mkdir -p "$MBSYNC_STATE"

          # Run mbsync (without verbose flag) and capture output
          MBSYNC_OUTPUT=$(${pkgs.isync}/bin/mbsync -c /etc/mbsync/mbsyncrc-assembly assembly 2>&1)
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
            echo "mbsync_assembly_last_success_timestamp $(date +%s)" > /var/lib/mbsync-assembly/metrics
            echo "mbsync_assembly_sync_status 1" >> /var/lib/mbsync-assembly/metrics

            # Count synced messages
            INBOX_COUNT=$(${pkgs.dovecot}/bin/doveadm mailbox status -u assembly messages INBOX 2>/dev/null | awk '{print $2}' || echo 0)
            echo "mbsync_assembly_inbox_messages $INBOX_COUNT" >> /var/lib/mbsync-assembly/metrics

            exit 0
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Synchronization failed with exit code $MBSYNC_EXIT" >> "$MBSYNC_LOG"

            # Update failure metrics
            echo "mbsync_assembly_last_failure_timestamp $(date +%s)" > /var/lib/mbsync-assembly/metrics
            echo "mbsync_assembly_sync_status 0" >> /var/lib/mbsync-assembly/metrics

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
        "/var/lib/mbsync-assembly"
        "/var/log/mbsync-assembly"
        "/tank/Maildir/assembly"
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
  systemd.timers.mbsync-assembly = {
    description = "Daily mail synchronization for assembly user";
    # wantedBy = [ "timers.target" ];  # Manually enable after testing

    timerConfig = {
      OnCalendar = "daily";  # Run once per day at midnight
      RandomizedDelaySec = "1h";  # Add some randomization to prevent thundering herd
      Persistent = true;  # Catch up on missed runs
      Unit = "mbsync-assembly.service";
    };
  };

  # Health check service for assembly mbsync
  systemd.services.mbsync-assembly-health-check = {
    description = "Check mbsync health for assembly user";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "assembly";
      ExecStart = pkgs.writeShellScript "mbsync-assembly-health-check" ''
        set -euo pipefail

        METRICS_FILE="/var/lib/mbsync-assembly/metrics"
        MAX_AGE_SECONDS=172800  # Alert if last sync was more than 48 hours ago (daily sync)

        # Check if metrics file exists
        if [ ! -f "$METRICS_FILE" ]; then
          echo "ERROR: No mbsync metrics found for assembly. Service may never have run." | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-assembly-health
          exit 1
        fi

        # Check last successful sync time
        LAST_SUCCESS=$(grep "mbsync_assembly_last_success_timestamp" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        CURRENT_TIME=$(date +%s)
        AGE=$((CURRENT_TIME - LAST_SUCCESS))

        if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
          echo "ERROR: Last successful sync was $((AGE / 3600)) hours ago" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-assembly-health

          # Check if service is running
          if ! ${pkgs.systemd}/bin/systemctl is-active --quiet mbsync-assembly.service; then
            echo "mbsync-assembly service is not running" | ${pkgs.systemd}/bin/systemd-cat -p warning -t mbsync-assembly-health
          fi

          # Check last failure
          LAST_FAILURE=$(grep "mbsync_assembly_last_failure_timestamp" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
          if [ "$LAST_FAILURE" -gt "$LAST_SUCCESS" ]; then
            echo "Recent sync failure detected at $(date -d @$LAST_FAILURE)" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-assembly-health

            # Show recent errors from log
            if [ -f /var/log/mbsync-assembly/sync.log ]; then
              echo "Recent errors:" | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-assembly-health
              tail -20 /var/log/mbsync-assembly/sync.log | grep -i error | ${pkgs.systemd}/bin/systemd-cat -p err -t mbsync-assembly-health
            fi
          fi

          exit 1
        fi

        # Check sync status
        SYNC_STATUS=$(grep "mbsync_assembly_sync_status" "$METRICS_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        if [ "$SYNC_STATUS" -eq 0 ]; then
          echo "WARNING: Last sync failed" | ${pkgs.systemd}/bin/systemd-cat -p warning -t mbsync-assembly-health
        else
          echo "mbsync health check passed. Last sync: $((AGE / 3600)) hours ago" | ${pkgs.systemd}/bin/systemd-cat -t mbsync-assembly-health
        fi
      '';
    };

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.systemd ];
  };

  # Timer for health checks (every 12 hours)
  systemd.timers.mbsync-assembly-health-check = {
    description = "Regular mbsync health checks for assembly";
    # wantedBy = [ "timers.target" ];  # Manually enable after testing

    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "12h";
      Unit = "mbsync-assembly-health-check.service";
    };
  };

  # Log rotation for mbsync assembly logs
  services.logrotate.settings.mbsync-assembly = {
    files = "/var/log/mbsync-assembly/*.log";
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

  # Install isync package
  environment.systemPackages = [ pkgs.isync ];
}
