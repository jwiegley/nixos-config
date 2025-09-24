{ config, lib, pkgs, ... }:

{
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      443    # nginx (HTTPS)
      587    # postfix (submission - STARTTLS)
      853    # technitium-dns-server (DNS-over-TLS)
      2022   # eternal-terminal
      5432   # postgres
    ];
    allowedUDPPorts = [
    ];
    interfaces.podman0 = {
      allowedTCPPorts = [
        4000 # litellm
      ];
      allowedUDPPorts = [
      ];
    };
    trustedInterfaces = lib.mkForce [ "lo" ];

    logRefusedConnections = true;
    logRefusedPackets = true;
    logRefusedUnicastsOnly = true;
    logReversePathDrops = true;
  };
}
