{ config, lib, pkgs, ... }:

{
  # ZFS exporter
  services.prometheus.exporters.zfs = {
    enable = true;
    port = 9134;
    # Monitor all pools (default behavior when pools is not specified)
  };

  # Prometheus scrape configuration for ZFS exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "zfs";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.zfs.port}" ];
      }];
    }
  ];

  # Service hardening and reliability
  systemd.services."prometheus-zfs-exporter" = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "zfs.target" ];
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Firewall configuration
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.exporters.zfs.port
  ];
}
