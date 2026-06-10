{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Syncthing Prometheus metrics monitoring.
  #
  # Syncthing 2.x ships a native Prometheus endpoint at /metrics on the GUI
  # listener (127.0.0.1:8384), authenticated with the API key — verified
  # 2026-06-10 that the key is accepted as a Bearer token, which is what
  # Prometheus's `authorization` block sends. The credential is the sops
  # secret declared in modules/services/syncthing.nix (group johnw, 0440 —
  # the prometheus user is a johnw-group member). The key is PATCH-pinned by
  # syncthing-gui-pin, so it is stable across restarts and rebuilds.
  #
  # Exposes syncthing_connections_active, syncthing_db_*, syncthing_fs_*,
  # syncthing_events_total plus go_*/process_* — alerting rules live in
  # modules/monitoring/alerts/syncthing.yaml (auto-discovered).

  services.prometheus.scrapeConfigs = [
    {
      job_name = "syncthing";
      static_configs = [
        {
          targets = [ "localhost:8384" ];
          labels = {
            service = "syncthing";
            instance = "vulcan";
          };
        }
      ];
      metrics_path = "/metrics";
      scheme = "http";
      authorization = {
        # type defaults to Bearer
        credentials_file = config.sops.secrets."syncthing/api-key".path;
      };
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];
}
