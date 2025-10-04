{ config, lib, pkgs, ... }:

{
  # Systemd exporter for service status
  services.prometheus.exporters.systemd = {
    enable = true;
    port = 9558;
  };

  # Prometheus scrape configuration for systemd exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "systemd";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.systemd.port}" ];
      }];
    }
  ];

  # Service hardening and reliability
  systemd.services."prometheus-systemd-exporter" = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Firewall configuration
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.exporters.systemd.port
  ];
}
