{ config, lib, pkgs, ... }:

{
  # Prometheus scrape configurations for OPNsense router monitoring
  services.prometheus.scrapeConfigs = [
    {
      job_name = "node_opnsense";
      static_configs = [{
        targets = [ "192.168.1.1:9100" ];
        labels = {
          alias = "opnsense-router";
          role = "gateway";
          device_type = "router";
        };
      }];
      scrape_interval = "30s";
    }
    {
      job_name = "opnsense";
      static_configs = [{
        targets = [ "localhost:9273" ];
        labels = {
          alias = "opnsense-router";
          role = "gateway";
          device_type = "router";
        };
      }];
      scrape_interval = "30s";
    }
  ];
}
