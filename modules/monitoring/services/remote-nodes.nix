{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Prometheus scrape configurations for remote node_exporter instances
  services.prometheus.scrapeConfigs = [
    {
      job_name = "darwin-hera";
      static_configs = [
        {
          targets = [ "hera.lan:9100" ];
          labels = {
            instance = "hera";
            os = "darwin";
            arch = "arm64";
          };
        }
      ];
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];
}
