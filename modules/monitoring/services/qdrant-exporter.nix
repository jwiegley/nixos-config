{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Prometheus scrape configuration for Qdrant
  # Metrics exposed at http://localhost:6333/metrics
  # Requires Bearer token authentication (same API key used by clients)
  services.prometheus.scrapeConfigs = [
    {
      job_name = "qdrant";
      metrics_path = "/metrics";
      scrape_interval = "15s";
      scrape_timeout = "10s";

      # Qdrant accepts both "api-key" header and "Authorization: Bearer" header
      authorization = {
        type = "Bearer";
        credentials_file = config.sops.secrets."qdrant/api-key".path;
      };

      static_configs = [
        {
          targets = [ "localhost:6333" ];
          labels = {
            service = "qdrant";
            instance = "vulcan";
          };
        }
      ];
    }
  ];
}
