{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Redis exporter for multiple Redis instances.
  # Primary -redis.addr target (job="redis"): redis-litellm (127.0.0.1:8085).
  # Multi-target /scrape probes (job="redis-multi"): openproject(6383),
  # shlink(6385), searxng(6386), rspamd(6381), speedtest-tracker(6387).
  # Socket-only instances (redis-gitea, redis-immich) are unreachable by the
  # DynamicUser exporter and are alerted via systemd unit state instead.

  services.prometheus.exporters.redis = {
    enable = true;
    port = 9121;
    # Listen only on localhost
    listenAddress = "127.0.0.1";

    # Export metrics for all Redis instances
    # Format: redis://host:port or unix:///path/to/socket
    extraFlags = [
      # litellm Redis binds 127.0.0.1:8085 (verified live: 127.0.0.1 PONGs,
      # 10.88.0.1 refuses). The old 10.88.0.1 addr made redis_up=0 +
      # redis_exporter_last_scrape_error=1 permanently with no alert.
      "-redis.addr=redis://127.0.0.1:8085" # litellm
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
    # instances via /scrape?target=. The per-app Redis servers below are not
    # covered by the primary -redis.addr (litellm), so without this their
    # redis_up never existed -> OpenProjectRedisDown / ShlinkRedisDown were dead.
    # This relabel job points each target at the exporter and stamps instance with
    # the redis URL, yielding redis_up{instance="redis://127.0.0.1:6383"} etc.
    #
    # All six TCP-listening instances are reachable on 127.0.0.1 (verified live;
    # openproject/shlink bind 0.0.0.0 but answer on loopback too). The two
    # remaining instances, redis-gitea and redis-immich, use UNIX SOCKETS in
    # 0750 dirs owned by their own service users (redis-gitea / redis-immich);
    # the DynamicUser redis-exporter cannot reach those sockets, so they are
    # covered by node_systemd_unit_state alerts in alerts/redis.yaml instead.
    {
      job_name = "redis-multi";
      scrape_interval = "30s";
      metrics_path = "/scrape";
      static_configs = [
        {
          targets = [
            "redis://127.0.0.1:6383" # openproject (allkeys-lru, maxmemory 256mb)
            "redis://127.0.0.1:6385" # shlink (allkeys-lru, maxmemory 128mb)
            "redis://127.0.0.1:6386" # searxng (allkeys-lru, maxmemory 64mb)
            "redis://127.0.0.1:6381" # rspamd (noeviction; Bayes/fuzzy backend, RDB-persisted)
            "redis://127.0.0.1:6387" # speedtest-tracker (allkeys-lru, maxmemory 64mb)
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
