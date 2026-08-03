{
  config,
  lib,
  pkgs,
  ...
}:

let
  resticLib = import ../lib/resticOperations.nix { inherit config lib pkgs; };
  inherit (resticLib) resticOperations;

  resticSnapshots = pkgs.writeShellApplication {
    name = "restic-snapshots";
    text = ''
      ${lib.getExe (resticOperations config.services.restic.backups)} snapshots
    '';
  };

  zfsSnapshotScript = pkgs.writeShellApplication {
    name = "logwatch-zfs-snapshot";
    text = ''
      for fs in $(${pkgs.zfs}/bin/zfs list -H -o name -t filesystem -r); do
        ${pkgs.zfs}/bin/zfs list -H -o name -t snapshot -S creation -d 1 "$fs" | ${pkgs.coreutils}/bin/head -1
      done
    '';
  };

  databaseSizesScript = pkgs.writeShellApplication {
    name = "logwatch-database-sizes";
    runtimeInputs = [
      config.services.postgresql.package
      pkgs.coreutils
      pkgs.gawk
      pkgs.sudo
    ];
    text = ''
      echo "PostgreSQL Databases"
      echo "--------------------"
      sudo -u postgres psql -t -A -F '|' -c \
        "SELECT datname, pg_database_size(datname) as raw_size,
                pg_size_pretty(pg_database_size(datname)) as size
         FROM pg_database
         WHERE datistemplate = false
         ORDER BY pg_database_size(datname) DESC;" 2>/dev/null | \
      while IFS='|' read -r name _raw_size pretty_size; do
        printf "  %-20s %10s\n" "$name" "$pretty_size"
      done
      echo ""
      total=$(sudo -u postgres psql -t -A -c \
        "SELECT pg_size_pretty(sum(pg_database_size(datname)))
         FROM pg_database WHERE datistemplate = false;" 2>/dev/null)
      printf "  %-20s %10s\n" "TOTAL" "$total"
      echo ""

      echo "Time-Series Databases"
      echo "---------------------"
      prom_size=$(du -sh /var/lib/prometheus2/data/ 2>/dev/null | awk '{print $1}')
      prom_dr_size=$(du -sh /var/lib/prometheus2/disaster-recovery/ 2>/dev/null | awk '{print $1}')
      vm_size=$(du -sh /var/lib/private/victoriametrics/ 2>/dev/null | awk '{print $1}')
      printf "  %-20s %10s\n" "Prometheus TSDB" "''${prom_size:-N/A}"
      printf "  %-20s %10s\n" "Prometheus DR" "''${prom_dr_size:-N/A}"
      printf "  %-20s %10s\n" "VictoriaMetrics" "''${vm_size:-N/A}"
    '';
  };

  zpoolScript = pkgs.writeShellApplication {
    name = "logwatch-zpool";
    text = "${pkgs.zfs}/bin/zpool status";
  };

  systemctlFailedScript = pkgs.writeShellApplication {
    name = "logwatch-systemctl-failed";
    text = "${pkgs.systemd}/bin/systemctl --failed";
  };

  certificateValidationScript = pkgs.writeShellApplication {
    name = "logwatch-certificate-validation";
    runtimeInputs = with pkgs; [
      bash
      openssl
      coreutils
      gawk
      gnugrep
    ];
    text = ''
      /etc/nixos/certs/validate-certificates-concise.sh || true
    '';
  };

  # AI log analysis script (used by both logwatch and command-line)
  analyzeLogsScript = pkgs.writeShellApplication {
    name = "analyze-logs";
    runtimeInputs = with pkgs; [
      python3
      systemd
    ];
    text = ''
      # No API key is exported here on purpose. The host LLM gateway on
      # 127.0.0.1:4000 injects the upstream Authorization header itself (see
      # modules/services/hera-llm-proxy.nix), so a client-side key would be
      # overwritten anyway. log-summarizer.py only sets the header when
      # LLM_API_KEY is non-empty, so leaving it unset is the correct config.

      # Pass all arguments to the log summarizer
      exec ${pkgs.python3}/bin/python3 /etc/nixos/scripts/log-summarizer.py "$@"
    '';
  };

  # Wrapper for logwatch (quiet mode, suppress errors)
  logwatchAiScript = pkgs.writeShellApplication {
    name = "logwatch-ai-summary";
    runtimeInputs = [ analyzeLogsScript ];
    text = ''
      analyze-logs --quiet 2>/dev/null || true
    '';
  };
in
{
  # Bound the daily logwatch run. The upstream module (nixos-logwatch flake input) ships
  # TimeoutStartUSec=infinity, and logwatch's ai-log-summary custom service calls an LLM
  # through the host gateway with its OWN 2-hour budget (scripts/log-summarizer.py:308,
  # `self.timeout = 7200  # 2 hours (local LLM can be slow)`). Unbounded unit + 2h request
  # means a dead model backend hangs this job for two hours, daily, with nothing stopping it.
  #
  # Not hypothetical: during the hera outage on 2026-08-01 logwatch sat in activating/start
  # for 38+ minutes and was still climbing when ServiceStuckActivating caught it.
  #
  # 30 min is ~3.8x the worst observed real run (7m56s on 2026-07-31; 4m00s and 3m58s the two
  # days before), so a genuinely slow summarisation still completes. Deliberately generous:
  # TimeoutStartSec is ENFORCED, and setting a previously-ignored cap too tight has broken a
  # working unit on this host before -- see the RuntimeMaxSec regression.
  #
  # This bounds the UNIT regardless of what the script does. The 7200s request timeout in
  # log-summarizer.py is separately excessive and worth lowering, but that is a script change
  # and this is the general safety net.
  # Raised 30min -> 45min on 2026-08-03 at the operator's request, after the cap
  # was actually hit twice in four days (timed out 04:30 on Aug 1 and Aug 3;
  # completed in 3m45s on Aug 2 and 7m56s on Jul 31). The comment above still
  # holds -- 30 min WAS ~3.8x the worst observed run -- but the worst observed
  # run has since grown past it, because logwatch digests `range = "since 24
  # hours ago"` and journal volume is now ~800k entries/day.
  #
  # This is the safety net, not the fix. The volume itself is dominated by
  # container-user session churn (systemd + systemd-logind + sd-pam + o-bridge
  # ~= 17.3k entries/hour, 56% of the journal), created by
  # container-health-exporter.timer running systemd-run per rootless container
  # user every 120s. Lowering that cadence is the actual lever; see the note in
  # modules/monitoring/services/container-health-exporter.nix.
  systemd.services.logwatch.serviceConfig.TimeoutStartSec = "45min";

  services = {
    logwatch = {
      enable = true;
      range = "since 24 hours ago for those hours";
      mailto = "johnw@vulcan.lan";
      mailfrom = "logwatch@vulcan.lan";
      customServices = [
        {
          name = "ai-log-summary";
          title = "AI-Powered System Log Analysis";
          script = lib.getExe logwatchAiScript;
        }
        {
          name = "systemctl-failed";
          title = "Failed systemctl services";
          script = lib.getExe systemctlFailedScript;
        }
        { name = "sshd"; }
        { name = "sudo"; }
        # { name = "fail2ban"; }
        { name = "kernel"; }
        # { name = "audit"; }
        {
          name = "certificate-validation";
          title = "Certificate Validation Report";
          script = lib.getExe certificateValidationScript;
        }
        {
          name = "database-sizes";
          title = "Database Storage Sizes";
          script = lib.getExe databaseSizesScript;
        }
        {
          name = "zpool";
          title = "ZFS Pool Status";
          script = lib.getExe zpoolScript;
        }
        {
          name = "zfs-snapshot";
          title = "ZFS Snapshots";
          script = lib.getExe zfsSnapshotScript;
        }
        {
          name = "restic";
          title = "Restic Snapshots";
          script = lib.getExe resticSnapshots;
        }
      ];
    };
  };

  # Create history directory for AI analysis deduplication (d = create only, never empties)
  systemd.tmpfiles.rules = [
    "d /var/log/logwatch-ai 0755 root root -"
  ];

  # Make analyze-logs available in PATH
  environment.systemPackages = [ analyzeLogsScript ];
}
