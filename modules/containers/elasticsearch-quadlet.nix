{ config, lib, pkgs, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  # Elasticsearch 8 container (RAGFlow requires ES 8+, NixOS only has ES 7)

  imports = [
    (mkQuadletService {
      name = "elasticsearch";
      image = "docker.io/elasticsearch:8.17.0";
      port = 9200;
      requiresPostgres = false;
      createStateDir = false;  # Custom ownership needed for ES container

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

      # No nginx virtual host (direct access)
      nginxVirtualHost = null;

      # Custom tmpfiles with specific UID for Elasticsearch
      tmpfilesRules = [
        "d /var/lib/elasticsearch 0750 1000 1000 -"  # ES runs as UID 1000 in container
        "d /etc/elasticsearch 0755 root root -"
      ];

      # Longer startup timeout for Elasticsearch
      extraServiceConfig = {
        TimeoutStartSec = "300";
      };
    })
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
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    9200
  ];
}
