{
  config,
  lib,
  pkgs,
  ...
}:

{
  mkMbsyncService =
    {
      name,
      user,
      group ? "users",
      secretName,
      remoteConfig,
      trash ? "Trash",
      localConfig ? {
        account = "dovecot";
        tunnel = "${pkgs.dovecot}/libexec/dovecot/imap -c /etc/dovecot/dovecot.conf";
        pathDelimiter = "/";
        inherit trash;
      },
      channels,
      timerInterval ? "15min",
      # Health-check staleness thresholds (seconds). Defaults suit a 15min
      # timer; accounts with slower cadence MUST scale these (2026-07-03
      # audit: assembly syncs 1x/day but inherited 1h/4h and sat CRITICAL
      # ~20h of every day). These feed only the mbsync-<name>-health-check
      # unit's journal verdict — its 0/1/2 exit is covered by
      # SuccessExitStatus, so it never fails the unit. The rule that actually
      # alerts is MbsyncStale in modules/monitoring/alerts/health-checks.yaml,
      # which carries its own thresholds; scale both together.
      healthWarningAge ? 3600,
      healthCriticalAge ? 14400,
      logLevel ? "info",
      extraServiceConfig ? { },
    }:
    {
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
        wants = [
          "network-online.target"
          "dovecot.service"
        ];
        after = [
          "network-online.target"
          "dovecot.service"
        ];
        # Don't auto-start during rebuild - only timer should trigger this
        wantedBy = lib.mkForce [ ];
        # Don't restart on config changes
        restartIfChanged = false;

        serviceConfig = lib.mkMerge [
          {
            Type = "oneshot";
            User = user;
            Group = group;
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/mail/${name}";
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

              # Retry transient failures IN-PROCESS rather than letting the unit
              # enter `failed`. Gmail closes IMAP sockets under load and rbcca is
              # the account that trips it -- 435M maildir vs bia's 3.0M -- with
              # "Socket error on imap.gmail.com: timeout".
              #
              # WHY HERE and not systemd Restart=: `Restart = "no"` a few lines
              # below is deliberate and load-bearing (its comment: restarting
              # would block nixos-rebuild), and the two alternatives both dead-end
              # -- `Restart` in extraServiceConfig fails Nix evaluation while the
              # base setting is a plain assignment rather than lib.mkDefault, and
              # StartLimitBurst/StartLimitIntervalSec are [Unit] options that
              # extraServiceConfig cannot carry at all. Retrying inside the script
              # sidesteps all of that and changes nothing about how systemd sees
              # the unit until the retries are exhausted.
              #
              # WHY IT MATTERS: the pages were never coming from the Mbsync* rules
              # -- all three have fired zero times in 14 days. They came from the
              # generic SystemdServiceFailed rule seeing the unit sit in `failed`
              # between 15-minute ticks: 254 critical firing samples for
              # mbsync-rbcca and 109 for mbsync-bia over 14 days. A transient that
              # self-heals on the next tick therefore paged as critical.
              #
              # Bounded deliberately: 3 attempts, 60s apart, so the worst case adds
              # ~2 minutes against a 30min TimeoutStartSec and a 15min timer. If a
              # retry run overruns the next tick, the lock file at the top of this
              # script makes that tick exit 0 rather than pile up. A PERSISTENT
              # failure still exhausts the attempts and fails the unit, so the
              # alert keeps its meaning -- this removes the false pages, not the
              # detector.
              SYNC_RC=0
              for attempt in 1 2 3; do
                SYNC_RC=0
                ${pkgs.isync}/bin/mbsync -c "$CONFIG_FILE" -a 2>&1 | tee -a "$LOG_FILE" || SYNC_RC=$?
                if [ "$SYNC_RC" -eq 0 ]; then
                  break
                fi
                if [ "$attempt" -lt 3 ]; then
                  echo "[$(date)] attempt $attempt/3 failed (rc=$SYNC_RC), retrying in 60s" \
                    | tee -a "$LOG_FILE"
                  sleep 60
                fi
              done

              if [ "$SYNC_RC" -eq 0 ]; then
                echo "[$(date)] Synchronization completed successfully" | tee -a "$LOG_FILE"

                # Update metrics for Prometheus textfile collector
                METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/mbsync_${name}.prom"
                echo "# HELP mbsync_last_sync_timestamp_seconds Timestamp of last successful sync" > "$METRICS_FILE.tmp"
                echo "# TYPE mbsync_last_sync_timestamp_seconds gauge" >> "$METRICS_FILE.tmp"
                echo "mbsync_last_sync_timestamp_seconds{account=\"${name}\"} $(date +%s)" >> "$METRICS_FILE.tmp"
                echo "# HELP mbsync_last_sync_status Status of last sync (1 = success, 0 = failure)" >> "$METRICS_FILE.tmp"
                echo "# TYPE mbsync_last_sync_status gauge" >> "$METRICS_FILE.tmp"
                echo "mbsync_last_sync_status{account=\"${name}\"} 1" >> "$METRICS_FILE.tmp"
                mv "$METRICS_FILE.tmp" "$METRICS_FILE"
                chmod 644 "$METRICS_FILE"

                # Clean up old logs (keep last 10)
                ls -t /var/log/mbsync-${name}/mbsync-*.log | tail -n +11 | xargs -r rm
              else
                # $SYNC_RC, not $?: the retry loop above is the last thing that
                # ran, so $? would be the `[` test's status, not mbsync's.
                EXIT_CODE=$SYNC_RC
                echo "[$(date)] Synchronization failed after 3 attempts with exit code $EXIT_CODE" \
                  | tee -a "$LOG_FILE"

                # Update failure metrics for Prometheus textfile collector
                METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/mbsync_${name}.prom"
                echo "# HELP mbsync_last_sync_timestamp_seconds Timestamp of last sync attempt" > "$METRICS_FILE.tmp"
                echo "# TYPE mbsync_last_sync_timestamp_seconds gauge" >> "$METRICS_FILE.tmp"
                echo "mbsync_last_sync_timestamp_seconds{account=\"${name}\"} $(date +%s)" >> "$METRICS_FILE.tmp"
                echo "# HELP mbsync_last_sync_status Status of last sync (1 = success, 0 = failure)" >> "$METRICS_FILE.tmp"
                echo "# TYPE mbsync_last_sync_status gauge" >> "$METRICS_FILE.tmp"
                echo "mbsync_last_sync_status{account=\"${name}\"} 0" >> "$METRICS_FILE.tmp"
                echo "# HELP mbsync_last_error_code Exit code of last failed sync" >> "$METRICS_FILE.tmp"
                echo "# TYPE mbsync_last_error_code gauge" >> "$METRICS_FILE.tmp"
                echo "mbsync_last_error_code{account=\"${name}\"} $EXIT_CODE" >> "$METRICS_FILE.tmp"
                mv "$METRICS_FILE.tmp" "$METRICS_FILE"
                chmod 644 "$METRICS_FILE"

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
              "/var/mail/${name}"
              "/var/lib/prometheus-node-exporter-textfiles"
              "/var/lib/dovecot" # Allow Dovecot IMAP tunnel to compile Sieve scripts
              "/home/${user}" # Allow Dovecot IMAP tunnel to create autoexpunge lock files
            ];
            NoNewPrivileges = true;

            # Resource limits
            TimeoutStartSec = "30min";
            CPUQuota = "50%";
          }
          extraServiceConfig
        ];

        path = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gawk
        ];
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
        wants = [ "network-online.target" ];
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

            METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/mbsync_${name}.prom"
            LAST_SYNC_TIMESTAMP=""

            if [ -f "$METRICS_FILE" ]; then
              LAST_SYNC_TIMESTAMP=$(grep "^mbsync_last_sync_timestamp_seconds" "$METRICS_FILE" | awk '{print $2}')
            fi

            if [ -z "$LAST_SYNC_TIMESTAMP" ]; then
              echo "WARNING: No sync metrics found for ${name}"
              exit 1  # Exit code 1 for warnings
            fi

            CURRENT_TIME=$(date +%s)
            SYNC_AGE=$((CURRENT_TIME - LAST_SYNC_TIMESTAMP))
            WARNING_AGE=${toString healthWarningAge}
            CRITICAL_AGE=${toString healthCriticalAge}

            if [ "$SYNC_AGE" -gt "$CRITICAL_AGE" ]; then
              echo "CRITICAL: Last successful sync was $((SYNC_AGE / 60)) minutes ago (over $((CRITICAL_AGE / 60)) minutes)"
              exit 2  # Exit code 2 for critical issues
            elif [ "$SYNC_AGE" -gt "$WARNING_AGE" ]; then
              echo "WARNING: Last successful sync was $((SYNC_AGE / 60)) minutes ago (over $((WARNING_AGE / 60)) minutes)"
              exit 1  # Exit code 1 for warnings
            else
              echo "OK: Last sync was $((SYNC_AGE / 60)) minutes ago"
              exit 0  # Exit code 0 for healthy state
            fi
          '';
        };

        # Add required utilities to PATH
        path = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gawk
        ];
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
}
