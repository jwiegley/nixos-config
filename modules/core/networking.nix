{ config, lib, pkgs, ... }:

{
  networking = {
    hostId = "671bf6f5";
    hostName = "vulcan";
    domain = "lan";

    hosts = {
      "127.0.0.2" = lib.mkForce [];
      "192.168.1.2" = [ "vulcan.lan" "vulcan" ];
    };

    interfaces.enp4s0.useDHCP = true;

    firewall = {
      enable = true;
      allowedTCPPorts = [
        25     # postfix
        80     # nginx
        2022   # eternal-terminal
        5432   # postgres
      ];
      allowedUDPPorts = [];
      interfaces.podman0.allowedUDPPorts = [];
      trustedInterfaces = lib.mkForce [ "lo" ];

      logRefusedConnections = true;
      logRefusedPackets = true;
      logRefusedUnicastsOnly = true;
      logReversePathDrops = true;
    };
  };
}
