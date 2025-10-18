{ config, lib, pkgs, ... }:

{
  # Configure Prometheus to scrape MS SQL Server metrics from the mssql-exporter container
  services.prometheus.scrapeConfigs = [
    {
      job_name = "mssql";
      scrape_interval = "30s";
      static_configs = [{
        targets = [ "127.0.0.1:9182" ];
        labels = {
          instance = "vulcan";
          service = "mssql";
        };
      }];
    }
  ];
}
