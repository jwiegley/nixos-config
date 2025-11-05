{ config, lib, pkgs, ... }:

{
  # Copyparty Prometheus metrics monitoring
  # Scrapes metrics from copyparty stats endpoint with basic authentication
  # Metrics exposed at http://localhost:13923/.cpr/metrics (via container port forward)

  # Load copyparty password credential into Prometheus service
  systemd.services.prometheus = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];

    # Use systemd LoadCredential to make password available
    # Password will be available at $CREDENTIALS_DIRECTORY/copyparty-password
    serviceConfig = {
      LoadCredential = "copyparty-password:${config.sops.secrets."copyparty/johnw-password".path}";
    };
  };

  # Prometheus scrape configuration for Copyparty metrics
  # Note: Scraping container IP directly since systemd-nspawn port forwarding is unreliable
  services.prometheus.scrapeConfigs = [
    {
      job_name = "copyparty";
      static_configs = [{
        targets = [ "10.233.1.2:3923" ];  # Container IP:port
        labels = {
          service = "copyparty";
          instance = "vulcan";
        };
      }];
      metrics_path = "/.cpr/metrics";
      scrape_interval = "30s";
      scrape_timeout = "10s";

      # Basic authentication using copyparty credentials
      basic_auth = {
        username = "johnw";
        password_file = "/run/credentials/prometheus.service/copyparty-password";
      };
    }
  ];

  # Documentation
  environment.etc."copyparty/metrics-monitoring.md" = {
    text = ''
      # Copyparty Prometheus Metrics Monitoring

      ## Overview
      Copyparty exposes Prometheus metrics via the stats endpoint at http://localhost:13923/.cpr/metrics

      ## Available Metrics
      The copyparty stats endpoint provides the following metrics:
      - **File server metrics**: Upload/download statistics
      - **Connection metrics**: Active connections and request counts
      - **Performance metrics**: Response times and throughput
      - **Storage metrics**: Disk usage and file counts
      - **User activity**: Access patterns and authentication attempts

      ## Checking Metrics
      ```bash
      # Check copyparty metrics endpoint (requires authentication)
      curl -u johnw:password http://localhost:13923/.cpr/metrics

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="copyparty")'
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Use the pre-configured Copyparty dashboard
      3. Example queries:
         - `copyparty_connections` - Active connections
         - `rate(copyparty_requests_total[5m])` - Request rate
         - `copyparty_storage_bytes` - Storage usage

      ## Accessing Copyparty
      - **Web UI**: https://home.newartisans.com
      - **Metrics**: http://localhost:13923/.cpr/metrics (requires auth)
      - **Container**: secure-nginx (10.233.1.2:3923 → host:13923)

      ## Troubleshooting
      - **Metrics not showing**: Check copyparty service is running in container:
        ```bash
        sudo machinectl shell secure-nginx /run/current-system/sw/bin/systemctl status copyparty
        ```
      - **Scrape failures**: Check Prometheus targets page for error messages
      - **Authentication errors**: Verify SOPS secret is loaded:
        ```bash
        sudo systemctl status prometheus
        ls -la /run/credentials/prometheus.service/copyparty-password
        ```
      - **Port forward issues**: Check container is forwarding port 3923→13923:
        ```bash
        sudo systemctl status container@secure-nginx
        netstat -tuln | grep 13923
        ```

      ## Related Files
      - Module: /etc/nixos/modules/monitoring/services/copyparty-exporter.nix
      - Service config: /etc/nixos/modules/services/copyparty.nix
      - Container config: /etc/nixos/modules/containers/secure-nginx.nix
      - Prometheus config: /etc/nixos/modules/monitoring/services/prometheus-server.nix
      - Dashboard: /etc/nixos/modules/monitoring/dashboards/copyparty.json

      ## Service Management
      ```bash
      # Check service status (in container)
      sudo machinectl shell secure-nginx /run/current-system/sw/bin/systemctl status copyparty

      # Restart service (in container)
      sudo machinectl shell secure-nginx /run/current-system/sw/bin/systemctl restart copyparty

      # View logs (in container)
      sudo machinectl shell secure-nginx /run/current-system/sw/bin/journalctl -u copyparty -f

      # Check Prometheus scraping
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="copyparty")'
      ```
    '';
    mode = "0644";
  };
}
