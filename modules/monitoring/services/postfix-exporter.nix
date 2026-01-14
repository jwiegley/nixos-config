{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Postfix exporter
  services.prometheus.exporters.postfix = {
    enable = true;
    port = 9154;
    # Postfix log file path - adjust if different
    logfilePath = "/var/log/postfix.log";
  };

  # Prometheus scrape configuration for Postfix exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "postfix";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.exporters.postfix.port}" ];
        }
      ];
    }
  ];

  # Service hardening and reliability
  systemd.services."prometheus-postfix-exporter" = {
    wants = [
      "network-online.target"
      "postfix.service"
    ];
    after = [
      "network-online.target"
      "postfix.service"
    ];
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Firewall configuration
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.exporters.postfix.port
  ];
}
