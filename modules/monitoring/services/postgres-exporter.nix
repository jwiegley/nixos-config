{
  config,
  lib,
  pkgs,
  ...
}:

{
  # PostgreSQL exporter
  services.prometheus.exporters.postgres = {
    enable = true;
    port = 9187;
    runAsLocalSuperUser = true;
  };

  # Prometheus scrape configuration for PostgreSQL exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "postgres";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.exporters.postgres.port}" ];
        }
      ];
    }
  ];

  # Service hardening and reliability
  systemd.services."prometheus-postgres-exporter" = {
    wants = [
      "network-online.target"
      "postgresql.service"
    ];
    after = [
      "network-online.target"
      "postgresql.service"
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
    config.services.prometheus.exporters.postgres.port
  ];
}
