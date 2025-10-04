{ config, lib, pkgs, ... }:

{
  # Dynamically generate scrape configs for all chainweb nodes
  services.prometheus.scrapeConfigs = lib.mapAttrsToList (name: nodeCfg: {
    job_name = "chainweb_${name}";
    static_configs = [{
      targets = [ "localhost:${toString nodeCfg.port}" ];
      labels = {
        node = name;
        blockchain = "kadena";
        instance = name;
      };
    }];
    scrape_interval = "30s";  # Scrape more frequently for blockchain metrics
  }) (config.services.chainweb-exporters.nodes or {});
}
