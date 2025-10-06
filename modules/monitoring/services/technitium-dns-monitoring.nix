{ config, lib, pkgs, ... }:

{
  # Prometheus scrape configuration for Technitium DNS metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "technitium_dns";
      static_configs = [{
        targets = [ "localhost:9274" ];
        labels = {
          alias = "vulcan-dns";
          role = "dns-server";
          service = "technitium";
        };
      }];
      # DNS queries happen frequently, so scrape every 15 seconds
      scrape_interval = "15s";
      scrape_timeout = "10s";
    }
  ];
}
