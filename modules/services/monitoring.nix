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
      # Read LiteLLM API key from SOPS secret
      if [ -f "/run/secrets/litellm-vulcan-lan-logwatch" ]; then
        LITELLM_API_KEY=$(cat "/run/secrets/litellm-vulcan-lan-logwatch")
        export LITELLM_API_KEY
      else
        echo "Warning: LiteLLM API key not found. AI analysis may fail." >&2
      fi

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
  # SOPS secret for LiteLLM API key (accessible by logwatch service which runs as root)
  sops.secrets."litellm-vulcan-lan-logwatch" = {
    key = "litellm-vulcan-lan"; # Same key in secrets.yaml
    owner = "root";
    mode = "0400";
  };

  # Bound the daily logwatch run. The upstream module (nixos-logwatch flake input) ships
  # TimeoutStartUSec=infinity, and logwatch's ai-log-summary custom service calls an LLM
  # through LiteLLM with its OWN 2-hour budget (scripts/log-summarizer.py:308,
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
  systemd.services.logwatch.serviceConfig.TimeoutStartSec = "30min";

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
