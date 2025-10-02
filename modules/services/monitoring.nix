{ config, lib, pkgs, ... }:

let
  attrNameList = attrs:
    builtins.concatStringsSep " " (builtins.attrNames attrs);

  resticOperations = backups: pkgs.writeShellApplication {
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
    runtimeInputs = with pkgs; [ bash openssl coreutils gawk gnugrep ];
    text = ''
      /etc/nixos/certs/validate-certificates-concise.sh || true
    '';
  };
in
{
  services = {
    logwatch = {
      enable = true;
      range = "since 24 hours ago for those hours";
      mailto = "johnw@newartisans.com";
      mailfrom = "johnw@newartisans.com";
      customServices = [
        {
          name = "systemctl-failed";
          title = "Failed systemctl services";
          script = lib.getExe systemctlFailedScript;
        }
        { name = "sshd"; }
        { name = "sudo"; }
        # { name = "fail2ban"; }
        { name = "kernel"; }
        { name = "audit"; }
        {
          name = "zpool";
          title = "ZFS Pool Status";
          script = lib.getExe zpoolScript;
        }
        {
          name = "restic";
          title = "Restic Snapshots";
          script = lib.getExe resticSnapshots;
        }
        {
          name = "zfs-snapshot";
          title = "ZFS Snapshots";
          script = lib.getExe zfsSnapshotScript;
        }
        {
          name = "certificate-validation";
          title = "Certificate Validation Report";
          script = lib.getExe certificateValidationScript;
        }
      ];
    };
  };
}
