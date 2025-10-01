{ config, lib, pkgs, ... }:

let
  # Helper function to create an mbsync service configuration
  mkMbsyncService = {
    name,
    user,
    group ? "users",
    secretName,
    remoteConfig,
    localConfig ? {
      account = "dovecot";
      tunnel = "${pkgs.dovecot}/libexec/dovecot/imap -c /etc/dovecot/dovecot.conf";
      pathDelimiter = "/";
      trash = "Trash";
    },
    channels,
    timerInterval ? "15min",
    logLevel ? "info",
    extraServiceConfig ? {}
  }: {
    # SOPS secret configuration
    sops.secrets."${secretName}" = {
      owner = user;
      inherit group;
      mode = "0400";
    };

    # Create necessary directories
    systemd.tmpfiles.rules = [
      "d /var/lib/mbsync-${name} 0755 ${user} ${group} -"
      "d /var/log/mbsync-${name} 0755 ${user} ${group} -"
    ];

    # mbsync configuration file
    environment.etc."mbsync/mbsyncrc-${name}".text = ''
      # Remote IMAP Account
      IMAPAccount ${name}-remote
      ${remoteConfig}

      IMAPStore ${name}-remote
      Account ${name}-remote

      # Local Dovecot Account
      IMAPAccount ${localConfig.account}
      Tunnel "${localConfig.tunnel}"

      IMAPStore ${localConfig.account}-local
      Account ${localConfig.account}
      PathDelimiter ${localConfig.pathDelimiter}
      Trash ${localConfig.trash}

      ${channels}
    '';

    # Main mbsync service
    systemd.services."mbsync-${name}" = {
      description = "mbsync synchronization for ${name}";
      wants = [ "network-online.target" "dovecot.service" ];
      after = [ "network-online.target" "dovecot.service" ];
      # Don't block nixos-rebuild if the service fails
      unitConfig.X-StopOnReconfiguration = false;

      serviceConfig = lib.mkMerge [
        {
          Type = "oneshot";
          User = user;
          Group = group;
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /tank/Maildir/${name}";
          ExecStart = pkgs.writeShellScript "mbsync-${name}" ''
            set -euo pipefail

            LOG_FILE="/var/log/mbsync-${name}/mbsync-$(date +%Y%m%d-%H%M%S).log"
            STATE_FILE="/var/lib/mbsync-${name}/.mbsyncstate"
            LOCK_FILE="/var/lib/mbsync-${name}/.lock"
            CONFIG_FILE="/etc/mbsync/mbsyncrc-${name}"

            # Check for lock file to prevent concurrent runs
            if [ -f "$LOCK_FILE" ]; then
              PID=$(cat "$LOCK_FILE")
              if kill -0 "$PID" 2>/dev/null; then
                echo "mbsync is already running with PID $PID" | tee -a "$LOG_FILE"
                exit 0
              else
                echo "Removing stale lock file" | tee -a "$LOG_FILE"
                rm -f "$LOCK_FILE"
              fi
            fi

            # Create lock file
            echo $$ > "$LOCK_FILE"
            trap 'rm -f "$LOCK_FILE"' EXIT

            # Run mbsync with proper error handling
            echo "[$(date)] Starting mbsync synchronization" | tee -a "$LOG_FILE"

            if ${pkgs.isync}/bin/mbsync -c "$CONFIG_FILE" -a -V 2>&1 | tee -a "$LOG_FILE"; then
              echo "[$(date)] Synchronization completed successfully" | tee -a "$LOG_FILE"

              # Update metrics
              echo "mbsync_${name}_last_sync_timestamp $(date +%s)" > /var/lib/mbsync-${name}/metrics.prom.tmp
              echo "mbsync_${name}_last_sync_status 1" >> /var/lib/mbsync-${name}/metrics.prom.tmp
              mv /var/lib/mbsync-${name}/metrics.prom.tmp /var/lib/mbsync-${name}/metrics.prom

              # Clean up old logs (keep last 10)
              ls -t /var/log/mbsync-${name}/mbsync-*.log | tail -n +11 | xargs -r rm
            else
              EXIT_CODE=$?
              echo "[$(date)] Synchronization failed with exit code $EXIT_CODE" | tee -a "$LOG_FILE"

              # Update failure metrics
              echo "mbsync_${name}_last_sync_timestamp $(date +%s)" > /var/lib/mbsync-${name}/metrics.prom.tmp
              echo "mbsync_${name}_last_sync_status 0" >> /var/lib/mbsync-${name}/metrics.prom.tmp
              echo "mbsync_${name}_last_error_code $EXIT_CODE" >> /var/lib/mbsync-${name}/metrics.prom.tmp
              mv /var/lib/mbsync-${name}/metrics.prom.tmp /var/lib/mbsync-${name}/metrics.prom

              exit $EXIT_CODE
            fi
          '';

          # Restart policy - don't restart on-failure to prevent blocking nixos-rebuild
          # The timer will handle regular runs instead
          Restart = "no";

          # Security hardening
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ReadWritePaths = [
            "/var/lib/mbsync-${name}"
            "/var/log/mbsync-${name}"
            "/tank/Maildir/${name}"
          ];
          NoNewPrivileges = true;

          # Resource limits
          TimeoutStartSec = "30min";
          CPUQuota = "50%";
        }
        extraServiceConfig
      ];

      path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk ];
    };

    # Timer for regular syncs
    systemd.timers."mbsync-${name}" = {
      description = "Timer for mbsync-${name} synchronization";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = timerInterval;
        Persistent = true;
        RandomizedDelaySec = "1min";
      };
    };

    # Health check service
    systemd.services."mbsync-${name}-health-check" = {
      description = "Health check for mbsync-${name}";
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = group;
        # Accept exit codes 0, 1, 2 as success since they represent health states (OK, WARNING, CRITICAL)
        # Only actual script failures (exit codes > 2) will show as "failed" in systemd
        SuccessExitStatus = "0 1 2";
        ExecStart = pkgs.writeShellScript "mbsync-${name}-health-check" ''
          set -euo pipefail

          METRICS_FILE="/var/lib/mbsync-${name}/metrics.prom"
          LAST_SYNC_TIMESTAMP=""

          if [ -f "$METRICS_FILE" ]; then
            LAST_SYNC_TIMESTAMP=$(grep "last_sync_timestamp" "$METRICS_FILE" | awk '{print $2}')
          fi

          if [ -z "$LAST_SYNC_TIMESTAMP" ]; then
            echo "WARNING: No sync metrics found for ${name}"
            exit 1  # Exit code 1 for warnings
          fi

          CURRENT_TIME=$(date +%s)
          SYNC_AGE=$((CURRENT_TIME - LAST_SYNC_TIMESTAMP))
          WARNING_AGE=$((60 * 60))      # 1 hour in seconds
          CRITICAL_AGE=$((4 * 60 * 60)) # 4 hours in seconds

          if [ "$SYNC_AGE" -gt "$CRITICAL_AGE" ]; then
            echo "CRITICAL: Last successful sync was $((SYNC_AGE / 60)) minutes ago (over 4 hours)"
            exit 2  # Exit code 2 for critical issues
          elif [ "$SYNC_AGE" -gt "$WARNING_AGE" ]; then
            echo "WARNING: Last successful sync was $((SYNC_AGE / 60)) minutes ago (over 1 hour)"
            exit 1  # Exit code 1 for warnings
          else
            echo "OK: Last sync was $((SYNC_AGE / 60)) minutes ago"
            exit 0  # Exit code 0 for healthy state
          fi
        '';
      };

      # Add required utilities to PATH
      path = [ pkgs.coreutils pkgs.gnugrep pkgs.gawk ];
    };

    # Health check timer
    systemd.timers."mbsync-${name}-health-check" = {
      description = "Timer for mbsync-${name} health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "30min";
        Persistent = true;
      };
    };

    # Log level configuration
    environment.etc."mbsync/logging-${name}.conf" = {
      text = ''
        # Logging configuration for mbsync-${name}
        LOG_LEVEL=${logLevel}
        LOG_DIR=/var/log/mbsync-${name}
        MAX_LOG_FILES=10
      '';
      mode = "0644";
    };
  };
in
{
  inherit mkMbsyncService;
}
