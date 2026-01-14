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
  # DISK TOPOLOGY:
  # - sda: 115.7G Ultra T C (system boot drive)
  # - sdb-sde: 4x 14.6TB ST16000NM000J (tank pool RAID10)
  #   - mirror-0: sde + sdc
  #   - mirror-1: sdb + sdd
  # - sdf: 7.3TB WDC WD80EFZX (standalone disk)
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
  # Spin down ONLY sdf after 10 minutes of inactivity (600 seconds)
  # All other disks (sda-sde) will NOT spin down (-i 0 sets global default to disabled)
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
