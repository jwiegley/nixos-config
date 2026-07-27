{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Install hd-idle package system-wide
  environment.systemPackages = with pkgs; [
    hd-idle
  ];

  # Configure hd-idle systemd service for disk power management
  #
  # DISK TOPOLOGY (re-verified 2026-07-27; /dev/sdX letters reflect enumeration
  # order — the pool itself is assembled from stable wwn-* ids):
  # - nvme0n1: 1.8TB Apple SSD — system disk (root is nvme0n1p5, ext4)
  # - sda-sdd: 4x 14.6TB ST16000NM000J in the external OWC enclosure
  #   (tank pool, two mirrors striped)
  #   - mirror-0: sdd + sdb
  #   - mirror-1: sda + sdc
  # - There is no sde and no sdf on this host. The 115.7G "Ultra T C" boot drive
  #   and the 7.3TB WDC WD80EFZX standalone disk this comment used to list are
  #   both gone.
  #
  # CONFIGURATION SYNTAX:
  # hd-idle uses the following syntax:
  #   -i <seconds>         Set DEFAULT idle timeout for ALL disks (0 = disabled)
  #   -a <device> -i <sec> Set specific timeout for one device (device name without /dev/)
  #
  # EXAMPLES:
  # - Spin down all disks after 10 minutes:
  #     hd-idle -i 600
  #
  # - Spin down ONLY sdf after 10 minutes (disable all others):
  #     hd-idle -i 0 -a sdf -i 600
  #
  # - Spin down all disks with different timeouts:
  #     hd-idle -i 600 -a sdb -i 900 -a sdc -i 900
  #     (default 10min, but sdb/sdc get 15min)
  #
  # - Disable specific disks while spinning down others:
  #     hd-idle -i 600 -a sda -i 0
  #     (all disks get 10min except sda which is disabled)
  #
  # CURRENT CONFIGURATION:
  # `-i 0 -a sdf -i 600` = global default disabled, spin down only sdf after
  # 10 minutes of inactivity (600 seconds).
  # STALE as of 2026-07-27: /dev/sdf no longer exists, so this ExecStart manages
  # no disk at all — every attached disk simply inherits the disabled default.
  # Left as-is here because changing it is a behaviour change, not a doc fix.
  #
  # WARNING: Prometheus scrapes node_exporter and zfs-exporter every 15 seconds!
  # This will likely prevent drives from spinning down. See system activity report
  # in the commit message or run: journalctl -u hd-idle -f
  #
  systemd.services.hd-idle = {
    description = "hd-idle - Spin down idle hard disks";
    documentation = [ "https://github.com/adelolmo/hd-idle" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.hd-idle}/bin/hd-idle -i 0 -a sdf -i 600";
      Restart = "on-failure";
      RestartSec = "10s";

      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;

      # hd-idle needs root access to manage disk power
      User = "root";
    };
  };
}
