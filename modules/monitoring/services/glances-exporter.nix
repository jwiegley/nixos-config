{ config, lib, pkgs, ... }:

{
  # Glances Prometheus exporter configuration
  # Scrapes metrics from Glances web server /api/prometheus endpoint
  # Provides comprehensive system monitoring metrics

  # Prometheus scrape configuration for Glances
  services.prometheus.scrapeConfigs = [
    {
      job_name = "glances";
      static_configs = [{
        targets = [ "localhost:61208" ];
        labels = {
          instance = "vulcan";
          service = "glances";
        };
      }];
      metrics_path = "/api/prometheus";
      scrape_interval = "15s";
      scrape_timeout = "10s";
    }
  ];
}
