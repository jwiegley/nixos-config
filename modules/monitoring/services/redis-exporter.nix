{ config, lib, pkgs, ... }:

{
  # Redis exporter for multiple Redis instances
  # Monitors: redis-litellm, redis-nextcloud

  services.prometheus.exporters.redis = {
    enable = true;
    port = 9121;
    # Listen only on localhost
    listenAddress = "127.0.0.1";

    # Export metrics for all Redis instances
    # Format: redis://host:port or unix:///path/to/socket
    extraFlags = [
      "-redis.addr=redis://10.88.0.1:8085"  # litellm
      "-redis.addr=unix:///run/redis-nextcloud/redis.sock"  # nextcloud
    ];
  };

  # Open firewall for redis exporter (localhost only)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9121 ];

  # Ensure redis-exporter user has permission to access Unix sockets
  users.users.redis-exporter = {
    isSystemUser = true;
    group = "redis-exporter";
    extraGroups = [ "redis-nextcloud" ];
  };

  users.groups.redis-exporter = {};

  # Prometheus scrape configuration
  services.prometheus.scrapeConfigs = [
    {
      job_name = "redis";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.redis.port}" ];
      }];
      scrape_interval = "30s";
    }
  ];

}
