{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Redis exporter for multiple Redis instances
  # Monitors: redis-litellm

  services.prometheus.exporters.redis = {
    enable = true;
    port = 9121;
    # Listen only on localhost
    listenAddress = "127.0.0.1";

    # Export metrics for all Redis instances
    # Format: redis://host:port or unix:///path/to/socket
    extraFlags = [
      "-redis.addr=redis://10.88.0.1:8085" # litellm
    ];
  };

  # Open firewall for redis exporter (localhost only)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9121 ];

  # Ensure redis-exporter user has permission to access Unix sockets
  users.users.redis-exporter = {
    isSystemUser = true;
    group = "redis-exporter";
  };

  users.groups.redis-exporter = { };

  # Filter out info-level logs from redis exporter to reduce log volume
  # Saves ~2,880 lines/day by only logging warnings and above
  systemd.services.prometheus-redis-exporter.serviceConfig.LogLevelMax = "warning";

  # Prometheus scrape configuration
  services.prometheus.scrapeConfigs = [
    {
      job_name = "redis";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.exporters.redis.port}" ];
        }
      ];
      scrape_interval = "30s";
    }
    # Multi-target: the single redis_exporter at :9121 can probe additional Redis
    # instances via /scrape?target=. The per-app Redis servers (openproject:6383,
    # shlink:6385) are not covered by the primary -redis.addr (litellm), so their
    # redis_up never existed -> OpenProjectRedisDown / ShlinkRedisDown were dead.
    # This relabel job points each target at the exporter and stamps instance with
    # the redis URL, yielding redis_up{instance="redis://127.0.0.1:6383"} etc.
    {
      job_name = "redis-multi";
      scrape_interval = "30s";
      metrics_path = "/scrape";
      static_configs = [
        {
          targets = [
            "redis://127.0.0.1:6383" # openproject
            "redis://127.0.0.1:6385" # shlink
          ];
        }
      ];
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "instance";
        }
        {
          target_label = "__address__";
          replacement = "localhost:${toString config.services.prometheus.exporters.redis.port}";
        }
      ];
    }
  ];

}
