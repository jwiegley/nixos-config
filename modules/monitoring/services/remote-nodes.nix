{
  config,
  lib,
  pkgs,
  hostRegistry,
  ...
}:

let
  hera = hostRegistry.hosts.hera;
  platform = lib.systems.elaborate hera.system;
in
{
  # Prometheus scrape configurations for remote node_exporter instances
  services.prometheus.scrapeConfigs = [
    {
      job_name = "darwin-hera";
      static_configs = [
        {
          targets = [ "${hera.dnsName}:9100" ];
          labels = {
            instance = "hera";
            os = platform.parsed.kernel.name;
            arch = platform.uname.processor;
          };
        }
      ];
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];
}
