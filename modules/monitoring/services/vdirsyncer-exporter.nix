{
  config,
  lib,
  pkgs,
  ...
}:

{
  # vdirsyncer Prometheus metrics monitoring
  # Scrapes metrics from the vdirsyncer status dashboard
  # Metrics exposed at http://localhost:8089/metrics

  # Prometheus scrape configuration for vdirsyncer metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "vdirsyncer";
      static_configs = [
        {
          targets = [ "localhost:8089" ];
          labels = {
            service = "vdirsyncer";
            instance = "vulcan";
          };
        }
      ];
      metrics_path = "/metrics";
      scrape_interval = "60s"; # Scrape every minute
      scrape_timeout = "10s";
    }
  ];

  # Documentation
  environment.etc."vdirsyncer/metrics-monitoring.md" = {
    text = ''
      # vdirsyncer Prometheus Metrics Monitoring

      ## Overview
      vdirsyncer exposes Prometheus metrics via the status dashboard at http://localhost:8089/metrics

      ## Available Metrics
      The exporter provides the following metrics:
      - **vdirsyncer_last_sync_timestamp**: Unix timestamp of last successful sync
      - **vdirsyncer_sync_healthy**: Whether the sync is healthy (1) or has issues (0)
      - **vdirsyncer_collections_total**: Total number of collections being synced
      - **vdirsyncer_sync_pairs_total**: Total number of sync pairs configured
      - **vdirsyncer_last_sync_duration_seconds**: Duration of last sync in seconds

      ## Checking Metrics
      ```bash
      # Check vdirsyncer metrics endpoint
      curl http://localhost:8089/metrics

      # Check specific metrics
      curl -s http://localhost:8089/metrics | grep vdirsyncer

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="vdirsyncer")'

      # Check sync status via API
      curl http://localhost:8089/api/status | jq
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Create a new dashboard or use the vdirsyncer dashboard
      3. Add panels with PromQL queries
      4. Example queries:
         - `vdirsyncer_sync_healthy` - Sync health status (0 or 1)
         - `time() - vdirsyncer_last_sync_timestamp` - Time since last sync
         - `vdirsyncer_collections_total` - Number of synced collections
         - `vdirsyncer_last_sync_duration_seconds` - Last sync duration

      ## Accessing vdirsyncer
      - **Status Dashboard**: https://vdirsyncer.vulcan.lan
      - **Metrics Endpoint**: http://localhost:8089/metrics
      - **API Endpoint**: http://localhost:8089/api/status
      - **Local Radicale**: https://radicale.vulcan.lan
      - **Remote Fastmail**: https://carddav.fastmail.com

      ## Troubleshooting
      - **Metrics not showing**: Check status service is running:
        ```bash
        sudo systemctl status vdirsyncer-status.service
        sudo journalctl -u vdirsyncer-status.service -f
        ```
      - **Sync failures**: Check vdirsyncer service logs:
        ```bash
        sudo systemctl status vdirsyncer.service
        sudo journalctl -u vdirsyncer.service -f
        ```
      - **Scrape failures**: Check Prometheus targets page for error messages
      - **Missing collections**: Run discovery manually:
        ```bash
        sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config discover
        sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config sync
        ```
      - **Authentication issues**: Verify SOPS secrets are properly configured:
        ```bash
        sudo systemctl restart vdirsyncer.service
        ls -la /run/secrets/vdirsyncer/
        ```

      ## Related Files
      - Module: /etc/nixos/modules/services/vdirsyncer.nix
      - Monitoring module: /etc/nixos/modules/monitoring/services/vdirsyncer-exporter.nix
      - Configuration: /etc/vdirsyncer/config
      - State directory: /var/lib/vdirsyncer/
      - Status database: /var/lib/vdirsyncer/status/

      ## Service Management
      ```bash
      # Check service status
      sudo systemctl status vdirsyncer.service
      sudo systemctl status vdirsyncer.timer
      sudo systemctl status vdirsyncer-status.service

      # Manual sync
      sudo systemctl start vdirsyncer.service

      # View logs
      sudo journalctl -u vdirsyncer.service -f
      sudo journalctl -u vdirsyncer-status.service -f

      # Check timer status
      sudo systemctl list-timers | grep vdirsyncer

      # Restart services
      sudo systemctl restart vdirsyncer-status.service
      ```

      ## Sync Configuration
      - **Sync interval**: Every 15 minutes (configurable via timer)
      - **Sync pairs**: Contacts between Radicale and Fastmail
      - **Conflict resolution**: Radicale wins (local changes take precedence)
      - **Collections**: Auto-discovered from both endpoints

      ## Security
      - Credentials stored in SOPS encrypted secrets
      - Service runs as dedicated vdirsyncer user
      - Hardened systemd service with restricted permissions
      - No network-exposed ports (status dashboard on localhost only)
      - Nginx reverse proxy with SSL for web access

      ## Performance
      - Lightweight Python-based sync tool
      - Efficient incremental sync using sync-tokens
      - Minimal resource usage (CPU/memory)
      - Status dashboard uses minimal resources
      - Metrics cached and updated on each sync
    '';
    mode = "0644";
  };
}
