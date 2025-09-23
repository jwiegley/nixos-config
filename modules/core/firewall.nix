{ config, lib, pkgs, ... }:

{
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      25     # postfix
      53     # technitium-dns-server
      80     # nginx (HTTP)
      443    # nginx (HTTPS)
      2022   # eternal-terminal
      5432   # postgres
    ];
    allowedUDPPorts = [
      53     # technitium-dns-server
    ];
    interfaces.podman0.allowedUDPPorts = [
      53     # technitium-dns-server
    ];
    trustedInterfaces = lib.mkForce [ "lo" ];

    logRefusedConnections = true;
    logRefusedPackets = true;
    logRefusedUnicastsOnly = true;
    logReversePathDrops = true;
  };
}
