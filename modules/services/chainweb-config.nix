# Configuration for Chainweb Node Exporters
{ config, lib, pkgs, ... }:

{
  # Enable the chainweb exporters service
  services.chainweb-exporters = {
    enable = true;

    # Configure multiple chainweb nodes to monitor
    nodes = {
      mainnet01 = {
        apiUrl = "https://api.chainweb.com/chainweb/0.0/mainnet01/cut";
        port = 9101;
      };

      mainnet01-athena = {
        apiUrl = "http://athena.lan:1848/chainweb/0.0/mainnet01/cut";
        port = 9102;
      };

      testnet04 = {
        apiUrl = "https://api.testnet.chainweb.com/chainweb/0.0/testnet04/cut";
        port = 9103;
      };

      evm-testnet = {
        apiUrl = "https://evm-testnet.chainweb.com/chainweb/0.0/evm-testnet/cut";
        port = 9104;
      };
    };
  };
}
