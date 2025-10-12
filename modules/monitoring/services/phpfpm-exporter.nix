{ config, lib, pkgs, ... }:

{
  # PHP-FPM exporter for monitoring Nextcloud PHP-FPM performance
  # Monitors process counts, queue length, request latency

  services.prometheus.exporters.php-fpm = {
    enable = true;
    port = 9253;
    # Listen only on localhost
    listenAddress = "127.0.0.1";

    # Telemetry path
    telemetryPath = "/metrics";
  };

  # Configure the exporter to scrape Nextcloud PHP-FPM
  systemd.services.prometheus-php-fpm-exporter = {
    serviceConfig = {
      # Add environment variables for PHP-FPM scraping
      Environment = [
        "PHP_FPM_SCRAPE_URI=unix://${config.services.phpfpm.pools.nextcloud.socket};/status"
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
          pool = "nextcloud";
        };
      }];
      scrape_interval = "15s";
    }
  ];

  # Helper script to check PHP-FPM exporter
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-phpfpm-exporter" ''
      echo "=== PHP-FPM Exporter Status ==="
      systemctl is-active prometheus-php-fpm-exporter && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Nextcloud PHP-FPM Pool Status ==="
      echo "Socket: ${config.services.phpfpm.pools.nextcloud.socket}"

      echo ""
      echo "=== Direct PHP-FPM Status Check ==="
      ${pkgs.curl}/bin/curl -s --unix-socket ${config.services.phpfpm.pools.nextcloud.socket} \
        http://localhost/status | ${pkgs.jq}/bin/jq . 2>/dev/null || \
        echo "Unable to query PHP-FPM directly"

      echo ""
      echo "=== Exporter Metrics Sample ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9253/metrics | grep -E "phpfpm_up|phpfpm_active_processes|phpfpm_accepted_connections" | head -15

      echo ""
      echo "=== Pool Statistics ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9253/metrics | grep -E "phpfpm_.*_processes"
    '')
  ];
}
