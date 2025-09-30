# Configuration for Chainweb Node Exporters
{ config, lib, pkgs, ... }:

{
  # Enable the chainweb exporters service
  services.chainweb-exporters = {
    enable = true;

    # Configure multiple chainweb nodes to monitor
    nodes = {
      mainnet01-production = {
        apiUrl = "https://api.chainweb.com/chainweb/0.0/mainnet01/cut";
        port = 9101;
      };

      mainnet01-local = {
        apiUrl = "https://athena.lan:1848/chainweb/0.0/mainnet01/cut";
        port = 9102;
      };
    };
  };
}
