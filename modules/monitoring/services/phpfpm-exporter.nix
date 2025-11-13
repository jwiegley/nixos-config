{ config, lib, pkgs, ... }:

{
  # PHP-FPM exporter for monitoring Roundcube PHP-FPM performance
  # Monitors process counts, queue length, request latency

  services.prometheus.exporters.php-fpm = {
    enable = true;
    port = 9253;
    # Listen only on localhost
    listenAddress = "127.0.0.1";

    # Telemetry path
    telemetryPath = "/metrics";
  };

  # Configure the exporter to scrape Roundcube PHP-FPM
  systemd.services.prometheus-php-fpm-exporter = {
    # Ensure exporter starts after PHP-FPM is ready
    after = [ "phpfpm-roundcube.service" ];
    wants = [ "phpfpm-roundcube.service" ];

    serviceConfig = {
      # Add environment variables for PHP-FPM scraping
      Environment = [
        "PHP_FPM_SCRAPE_URI=unix://${config.services.phpfpm.pools.roundcube.socket};/status"
        "PHP_FPM_FIX_PROCESS_COUNT=true"
      ];
      # Allow Unix socket connections
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };

  # Open firewall for PHP-FPM exporter (localhost only)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9253 ];

  # Ensure php-fpm-exporter user has permission to access Unix socket
  users.users.php-fpm-exporter = {
    isSystemUser = true;
    group = "php-fpm-exporter";
    extraGroups = [ "nginx" ];
  };

  users.groups.php-fpm-exporter = {};

  # Prometheus scrape configuration
  services.prometheus.scrapeConfigs = [
    {
      job_name = "php-fpm";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.php-fpm.port}" ];
        labels = {
          pool = "roundcube";
        };
      }];
      scrape_interval = "15s";
    }
  ];

}
