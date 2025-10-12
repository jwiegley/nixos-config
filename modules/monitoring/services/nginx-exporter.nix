{ config, lib, pkgs, ... }:

{
  # Nginx monitoring with stub_status and prometheus exporter
  # Provides metrics on requests, connections, and server performance

  # Enable nginx stub_status module
  services.nginx = {
    statusPage = true;

    # Add a virtual host for stub_status (localhost only)
    virtualHosts."localhost" = {
      listen = [{
        addr = "127.0.0.1";
        port = 80;
      }];

      locations."/nginx_status" = {
        extraConfig = ''
          stub_status on;
          access_log off;
          allow 127.0.0.1;
          deny all;
        '';
      };
    };
  };

  # Nginx prometheus exporter
  services.prometheus.exporters.nginx = {
    enable = true;
    port = 9113;
    listenAddress = "127.0.0.1";
    scrapeUri = "http://127.0.0.1/nginx_status";
  };

  # Open firewall for nginx exporter (localhost only)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9113 ];

  # Prometheus scrape configuration
  services.prometheus.scrapeConfigs = [
    {
      job_name = "nginx";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.nginx.port}" ];
      }];
      scrape_interval = "30s";
    }
  ];

  # Helper script to check Nginx exporter
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-nginx-exporter" ''
      echo "=== Nginx Exporter Status ==="
      systemctl is-active prometheus-nginx-exporter && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Nginx stub_status Check ==="
      ${pkgs.curl}/bin/curl -s http://127.0.0.1/nginx_status || echo "stub_status not accessible"

      echo ""
      echo "=== Exporter Metrics Sample ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9113/metrics | grep -E "nginx_up|nginx_connections_|nginx_http_requests_total" | head -15

      echo ""
      echo "=== Nginx Connection Statistics ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9113/metrics | grep "nginx_connections"
    '')
  ];
}
