{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Redis exporter for multiple Redis instances.
  # Primary -redis.addr target (job="redis"): rspamd (127.0.0.1:6381).
  # Multi-target /scrape probes (job="redis-multi"): openproject(6383),
  # shlink(6385), searxng(6386), rspamd(6381), speedtest-tracker(6387), plus the
  # two UNIX-socket instances gitea + immich (via unix:// targets — see below).
  # The systemd-unit-state alert for the socket pair is kept as a backstop.

  services.prometheus.exporters.redis = {
    enable = true;
    port = 9121;
    # Listen only on localhost
    listenAddress = "127.0.0.1";

    # Export metrics for all Redis instances
    # Format: redis://host:port or unix:///path/to/socket
    extraFlags = [
      # Repointed 2026-08-01: this used to be the LLM proxy's Redis on
      # 127.0.0.1:8085, removed with that proxy. The exporter always
      # probes its -redis.addr, and dropping the flag would silently fall back
      # to the upstream default localhost:6379 -- nothing listens there, so
      # redis_up would read 0 and redis_exporter_last_scrape_error 1 forever.
      # rspamd's instance is the right successor: it is always-on, RDB-persisted
      # and noeviction. Every instance including this one is ALSO probed under
      # job="redis-multi", so this target is about keeping job="redis" valid
      # rather than about coverage.
      "-redis.addr=redis://127.0.0.1:6381" # rspamd
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

  # Grant the exporter access to the gitea/immich UNIX-socket Redis instances.
  # Those sockets live in 0750 dirs owned by their own service users, with the
  # socket itself srw-rw---- group-owned by the matching group. Joining both
  # groups gives the exporter directory traversal (dir g+rx) AND socket read
  # (socket g+rw), so it can probe redis://...unix:///run/redis-<n>/redis.sock.
  # SupplementaryGroups is honored even though the unit runs DynamicUser=yes
  # (systemd applies supplementary groups to the transient dynamic user). The
  # group names are verified to exist (redis-gitea gid 947, redis-immich gid
  # 922) and own the 0750 socket dirs. POST-DEPLOY VERIFY (done — confirmed
  # 2026-07-27): the exporter does accept /scrape?target=unix:///..., and both
  # redis_up{instance="unix:///run/redis-{gitea,immich}/redis.sock"} report 1 in
  # Prometheus. The RedisSocketInstanceDown systemd-state backstop is kept
  # anyway, so a regression here is still covered.
  systemd.services.prometheus-redis-exporter.serviceConfig.SupplementaryGroups = [
    "redis-gitea"
    "redis-immich"
  ];

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
    # covered by the primary -redis.addr, so without this their
    # redis_up never existed -> OpenProjectRedisDown / ShlinkRedisDown were dead.
    # This relabel job points each target at the exporter and stamps instance with
    # the redis URL, yielding redis_up{instance="redis://127.0.0.1:6383"} etc.
    #
    # All five TCP-listening instances are reachable on 127.0.0.1 (verified live;
    # openproject/shlink bind 0.0.0.0 but answer on loopback too). The two
    # remaining instances, redis-gitea and redis-immich, use UNIX SOCKETS in
    # 0750 dirs owned by their own service users (redis-gitea / redis-immich).
    # The exporter is now in both groups (SupplementaryGroups above) so it can
    # reach those sockets; they are probed here as unix:// targets. The
    # node_systemd_unit_state alert in alerts/redis.yaml is kept as a backstop.
    {
      job_name = "redis-multi";
      scrape_interval = "30s";
      metrics_path = "/scrape";
      static_configs = [
        {
          targets = [
            "redis://127.0.0.1:6383" # openproject (allkeys-lru, maxmemory 256mb)
            "redis://127.0.0.1:6386" # searxng (allkeys-lru, maxmemory 64mb)
            "redis://127.0.0.1:6381" # rspamd (noeviction; Bayes/fuzzy backend, RDB-persisted)
            "redis://127.0.0.1:6387" # speedtest-tracker (allkeys-lru, maxmemory 64mb)
            "unix:///run/redis-gitea/redis.sock" # gitea sessions/cache (socket; needs redis-gitea group)
            "unix:///run/redis-immich/redis.sock" # immich queue/session store (socket; needs redis-immich group)
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
