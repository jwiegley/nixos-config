{
  config,
  lib,
  pkgs,
  ...
}:

# AIDE (Advanced Intrusion Detection Environment)
# File integrity monitoring for critical system files and backups
#
# This module configures AIDE to monitor:
# - System binaries and libraries
# - Critical backup directories (/tank/Backups/Images, /tank/Backups/Messages)
# - SSH keys and configuration files
# - SOPS secrets configuration

{
  # Install AIDE package
  environment.systemPackages = with pkgs; [
    aide
  ];

  # AIDE configuration file
  environment.etc."aide.conf".text = ''
    # AIDE Configuration
    # Database paths
    database_in=file:/var/lib/aide/aide.db
    database_out=file:/var/lib/aide/aide.db.new
    database_new=file:/var/lib/aide/aide.db.new

    # Report configuration
    report_url=stdout

    # Logging level (error, warning, notice, info, debug)
    log_level=notice

    # Report detail level
    report_level=changed_attributes
    report_detailed_init=yes
    report_base16=no
    report_quiet=no
    report_append=no
    report_summarize_changes=yes

    # Custom rule definitions
    # R = Read-only files (permissions + inode + size + checksums)
    # L = Log files (growing, permissions may change)
    # E = Empty directories
    # > = Growing log files
    # N = Ignore everything (for exclusions)

    # Comprehensive monitoring for critical files
    # Using modern hash algorithms (sha256+sha512) - removed deprecated md5, rmd160, tiger
    CRITICAL = p+i+n+u+g+s+b+m+c+sha256+sha512

    # Read-only files (no changes expected)
    READONLY = p+i+n+u+g+s+b+m+c+sha256

    # Configuration files (may change, but we want to know)
    CONFIG = p+i+n+u+g+s+b+m+c+sha256

    # Immutable backups (should NEVER change)
    # Note: For multi-TB directories, we only monitor metadata, not file contents
    # Use ZFS snapshots for content integrity verification
    IMMUTABLE = p+i+n+u+g+s+b+m+c+sha256+sha512

    # Log files (can grow, but structure shouldn't change)
    LOGS = p+i+n+u+g+S

    # Directories only
    DIRONLY = p+i+n+u+g

    # ===== CRITICAL SYSTEM FILES =====

    # System binaries (should be read-only)
    /bin READONLY
    /sbin READONLY
    /usr/bin READONLY
    /usr/sbin READONLY

    # System libraries
    /lib READONLY
    /lib64 READONLY
    /usr/lib READONLY
    /usr/lib64 READONLY

    # NixOS-specific
    /run/current-system READONLY
    /nix/var/nix/profiles/system READONLY

    # Boot files
    /boot CRITICAL

    # ===== SSH AND SECURITY =====

    # SSH keys and configuration
    /etc/ssh CRITICAL
    /root/.ssh CRITICAL

    # SOPS configuration
    /etc/nixos/secrets.yaml CONFIG
    # Exclude private age keys (should never be committed)
    !/etc/nixos/.*.age$

    # ===== CRITICAL BACKUPS (IMMUTABLE) =====

    # Images backup directory (2.1TB) - Monitor directory metadata only
    # File content integrity verified via ZFS scrub and snapshots
    !/tank/Backups/Images

    # Messages backup directory (109GB) - Monitor directory metadata only
    # File content integrity verified via ZFS scrub and snapshots
    !/tank/Backups/Messages

    # PostgreSQL backups - Excluded to avoid daily alerts from automated backups
    # Backup integrity verified via daily backup service monitoring
    !/tank/Backups/PostgreSQL

    # ===== CONFIGURATION FILES =====

    # NixOS configuration
    /etc/nixos CONFIG
    # Exclude .git directory
    !/etc/nixos/\.git
    # Exclude build results
    !/etc/nixos/result
    # Exclude build lock file
    !/etc/nixos/\.nixos-build

    # System configuration
    /etc/systemd CONFIG
    /etc/security CONFIG

    # ===== CROWN-JEWEL MUTABLE CONFIG =====
    # Home Assistant hand-edited YAML + Node-RED flows.json are high-value
    # config artifacts that change OUTSIDE a nixos-rebuild (HA UI / NR deploy).
    # AIDE gives the broad daily heads-up here; the per-file deploy-window
    # sharpshooter is config-drift-exporter.nix (config_file_drift). We watch
    # ONLY the human-authored YAML and the flows file — NEVER the churning,
    # token-bearing .storage/ tree or runtime state.
    /var/lib/hass/configuration.yaml CONFIG
    /var/lib/hass/automations.yaml CONFIG
    /var/lib/hass/scripts.yaml CONFIG
    /var/lib/hass/scenes.yaml CONFIG
    /var/lib/node-red/flows.json CONFIG

    # Exclude everything else under these dirs (constantly-churning runtime
    # state, OAuth/refresh tokens in .storage, logs, deps). The explicit file
    # rules above still apply; these negations cover the siblings.
    !/var/lib/hass/\.storage
    !/var/lib/hass/home-assistant_v2\.db
    !/var/lib/hass/home-assistant\.log
    !/var/lib/hass/deps
    !/var/lib/hass/tts
    !/var/lib/node-red/\.flows\.json\.backup
    !/var/lib/node-red/node_modules
    !/var/lib/node-red/\.config
    !/var/lib/node-red/lib

    # ===== EXCLUSIONS =====

    # Temporary files
    !/tmp
    !/var/tmp
    !/run

    # Log directories (monitored separately)
    !/var/log

    # Proc and sys
    !/proc
    !/sys
    !/dev

    # Nix store changes frequently during updates
    !/nix/store

    # Cache and transient data
    !/var/cache
    !/home/.*/\.cache
    !/root/\.cache

    # Browser and application caches
    !/\.mozilla
    !/\.config/google-chrome

    # ZFS snapshots
    !/tank/\.zfs
  '';

  # Create necessary directories
  systemd.tmpfiles.rules = [
    "d /var/lib/aide 0700 root root -"
    "d /var/log/aide 0755 root root -"
  ];

  # AIDE initialization service (run once to create initial database)
  systemd.services.aide-init = {
    description = "Initialize AIDE database";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.aide}/bin/aide --init";
      ExecStartPost = "${pkgs.coreutils}/bin/mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db";
      RemainAfterExit = true;
    };
  };

  # AIDE check service (manual or timer-triggered)
  systemd.services.aide-check = {
    description = "AIDE file integrity check";
    after = [ "aide-init.service" ];
    requires = [ "aide-init.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.aide}/bin/aide --check";
      # AIDE exit codes: 0=no changes, 1-7=changes detected (all informational)
      # Treat changes as success so systemd doesn't enter "failed" state and trigger
      # SystemdServiceFailed alerts. Changes are tracked via aide_check_status Prometheus metric.
      SuccessExitStatus = [
        0
        1
        2
        3
        4
        5
        6
        7
      ];
      # Additive result-emission (does NOT conflict with aide-metrics.nix's
      # ExecStartPost full-walk nor aide-nagios-check's check_aide). ExecStopPost
      # runs after the primary `aide --check` ExecStart and reads $EXIT_STATUS
      # (the REAL numeric exit code, before SuccessExitStatus masks it to 0) to
      # emit two metrics into a SEPARATE textfile (aide_result.prom), so the
      # change-detection signal is driven by the authoritative exit code, not by
      # aide-metrics.nix's brittle count parse:
      #   aide_changes_detected         1 if exit 1-7 (changes), 0 if exit 0
      #   aide_last_check_timestamp_seconds  wall-clock of this check
      # COUNTS/BOOLEANS/TIMESTAMPS ONLY — never AIDE report lines / paths.
      ExecStopPost = "${pkgs.writeShellScript "aide-result-emit" ''
        set -u
        DIR=/var/lib/prometheus-node-exporter-textfiles
        OUT="$DIR/aide_result.prom"
        TMP="$OUT.$$"
        # $EXIT_STATUS is the real exit code (numeric for an exited service).
        # Treat non-numeric / missing as unknown -> changes=0 but timestamp still
        # advances so AideResultStale catches a dead check.
        EC="''${EXIT_STATUS:-}"
        case "$EC" in
          1|2|3|4|5|6|7) CHANGES=1 ;;
          *)             CHANGES=0 ;;
        esac
        [ -d "$DIR" ] || ${pkgs.coreutils}/bin/mkdir -p "$DIR"
        {
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_changes_detected 1 if the last aide --check reported changes (exit 1-7), 0 if clean'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_changes_detected gauge'
          ${pkgs.coreutils}/bin/printf 'aide_changes_detected %s\n' "$CHANGES"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_last_check_timestamp_seconds Unix time the last aide --check completed'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_last_check_timestamp_seconds gauge'
          ${pkgs.coreutils}/bin/printf 'aide_last_check_timestamp_seconds %s\n' "$(${pkgs.coreutils}/bin/date +%s)"
        } > "$TMP"
        ${pkgs.coreutils}/bin/chmod 0644 "$TMP"
        ${pkgs.coreutils}/bin/mv -f "$TMP" "$OUT"
      ''}";
    };
  };

  # AIDE update service (updates database with approved changes)
  systemd.services.aide-update = {
    description = "Update AIDE database with current state";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.aide}/bin/aide --update";
      ExecStartPost = "${pkgs.coreutils}/bin/mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db";
      # AIDE exit codes: 0=no changes, 1-7=changes detected (all valid for update)
      # 1=new, 2=removed, 3=changed, 4=new+removed, 5=new+changed, 6=removed+changed, 7=all
      SuccessExitStatus = [
        0
        1
        2
        3
        4
        5
        6
        7
      ];
    };
  };

  # Automated daily AIDE check timer
  systemd.timers.aide-check = {
    description = "Daily AIDE integrity check";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30min"; # Prevent all systems from checking at once
    };
  };

  # Auto-update AIDE database after nixos-rebuild
  # Since all system changes are applied via Nix, the rebuild itself is the
  # approval of changes. This prevents false-positive integrity alerts from
  # expected NixOS store path changes after each rebuild.
  #
  # We delay the update by 60s because some system changes (e.g. /usr/bin/env
  # symlink recreation) happen after activation scripts complete. Without the
  # delay, aide-update can finish before all changes land, causing the next
  # aide-check to report false positives.
  system.activationScripts.aide-post-rebuild = lib.stringAfter [ "etc" ] ''
    if [ -f /var/lib/aide/aide.db ]; then
      ${pkgs.systemd}/bin/systemd-run --on-active=60 \
        --timer-property=AccuracySec=1 \
        --description="Post-rebuild AIDE database update" \
        ${pkgs.systemd}/bin/systemctl start aide-update.service 2>/dev/null || true
    fi
  '';

  # ===========================================================================
  # SOPS runtime-secret permission drift monitor
  # ---------------------------------------------------------------------------
  # /run/secrets/* are decrypted at runtime and MUST stay owner-only (0400/0600,
  # owned by the consuming service). A world-readable or group-writable secret
  # is a real exposure. node-exporter has no metric for this, so this tiny root
  # oneshot counts (COUNTS ONLY — never names, never contents; the values are
  # forbidden) the runtime secret files that are other-readable or group-writable
  # and emits a single gauge via the textfile-collector pattern (atomic tmp+mv,
  # 0644, /var/lib/prometheus-node-exporter-textfiles/, picked up by job=node).
  # Alert SecretsWorldReadable (security.yaml) fires on count > 0.
  # ===========================================================================
  systemd.services.secrets-perms-exporter = {
    description = "Export count of world-readable/group-writable /run/secrets files";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "secrets-perms-exporter" ''
        set -euo pipefail
        DIR=/var/lib/prometheus-node-exporter-textfiles
        OUT="$DIR/secrets-perms.prom"
        TMP="$OUT.$$"

        # Count regular files under /run/secrets that are readable by "other"
        # (-perm -o+r) OR writable by "group" (-perm -g+w). -L follows the
        # symlinks that SOPS lays down. Emit ONLY the integer count.
        if [ -d /run/secrets ]; then
          COUNT=$(${pkgs.findutils}/bin/find -L /run/secrets -type f \
            \( -perm -o+r -o -perm -g+w \) 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
        else
          COUNT=0
        fi

        # Write the exposition file with printf so no heredoc indentation leaks
        # into the .prom (Prometheus text format requires metric lines to start
        # at column 0).
        {
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP secrets_world_readable_count Number of /run/secrets files that are other-readable or group-writable'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE secrets_world_readable_count gauge'
          ${pkgs.coreutils}/bin/printf 'secrets_world_readable_count %s\n' "$COUNT"
        } > "$TMP"
        ${pkgs.coreutils}/bin/chmod 0644 "$TMP"
        ${pkgs.coreutils}/bin/mv -f "$TMP" "$OUT"
      '';
    };
  };

  systemd.timers.secrets-perms-exporter = {
    description = "Hourly /run/secrets permission-drift check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      RandomizedDelaySec = "2min";
    };
  };
}
