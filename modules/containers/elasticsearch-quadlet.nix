{ config, lib, pkgs, ... }:

{
  # Elasticsearch 8 container (RAGFlow requires ES 8+, NixOS only has ES 7)
  virtualisation.quadlet.containers.elasticsearch = {
    containerConfig = {
      image = "docker.io/elasticsearch:8.17.0";

      # Bind to both localhost and podman gateway
      publishPorts = [
        "127.0.0.1:9200:9200/tcp"
        "10.88.0.1:9200:9200/tcp"
      ];

      # Single-node configuration via environment file
      environmentFiles = [ "/etc/elasticsearch/env" ];

      volumes = [
        "/var/lib/elasticsearch:/usr/share/elasticsearch/data"
      ];

      networks = [ "podman" ];
    };

    unitConfig = {
      After = [ "podman.service" ];
      Wants = [ "podman.service" ];
    };

    serviceConfig = {
      Restart = "always";
      TimeoutStartSec = "300";
    };
  };

  # State directory for Elasticsearch data
  systemd.tmpfiles.rules = [
    "d /var/lib/elasticsearch 0750 1000 1000 -"  # ES runs as UID 1000 in container
    "d /etc/elasticsearch 0755 root root -"
  ];

  # Create Elasticsearch environment file
  environment.etc."elasticsearch/env" = {
    text = ''
      discovery.type=single-node
      cluster.name=ragflow-cluster
      node.name=vulcan
      xpack.security.enabled=false
      ES_JAVA_OPTS=-Xms2g -Xmx2g
    '';
    mode = "0644";
  };

  # Firewall rules for podman network
  networking.firewall.interfaces.podman0.allowedTCPPorts =
    lib.mkIf true [ 9200 ];
}
