{
  config,
  lib,
  pkgs,
  ...
}:

let
  attrNameList = attrs: builtins.concatStringsSep " " (builtins.attrNames attrs);

  resticOperations =
    backups:
    pkgs.writeShellApplication {
      name = "restic-operations";
      text = ''
        operation="''${1:-check}"
        shift || true

        for fileset in ${attrNameList backups} ; do
          echo "=== $fileset ==="
          case "$operation" in
            check)
              /run/current-system/sw/bin/restic-$fileset \
                --retry-lock=1h check
              /run/current-system/sw/bin/restic-$fileset \
                --retry-lock=1h prune
              /run/current-system/sw/bin/restic-$fileset \
                --retry-lock=1h repair snapshots
              ;;
            snapshots)
              /run/current-system/sw/bin/restic-$fileset snapshots --json | \
                ${pkgs.jq}/bin/jq -r \
                  'sort_by(.time) | reverse | .[:4][] | .time'
              ;;
            *)
              echo "Unknown operation: $operation"
              exit 1
              ;;
          esac
        done
      '';
    };

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

  # Make analyze-logs available in PATH
  environment.systemPackages = [ analyzeLogsScript ];
}
