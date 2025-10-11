{ config, lib, pkgs, ... }:

{
  # Elasticsearch 7 is not used - RAGFlow requires ES 8+
  # See modules/containers/elasticsearch-quadlet.nix for ES 8 container
  services.elasticsearch.enable = false;
}
