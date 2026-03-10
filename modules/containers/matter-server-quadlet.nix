# Matter Server - System Quadlet Container
#
# python-matter-server: standalone Matter/CHIP SDK server for Home Assistant
# WebSocket API: ws://localhost:5580/ws (consumed by Home Assistant Matter integration)
# Network: host mode (required for mDNS multicast + Matter operational UDP 5540)
#
# Home Assistant connects to this server via the Matter integration config flow.
# After connecting, commission the Aqara M3 Hub via Settings > Devices > Matter > Add Device.

{
  config,
  lib,
  pkgs,
  ...
}:

{
  virtualisation.quadlet.containers.matter-server = {
    autoStart = true;

    containerConfig = {
      # Pin to "stable" tag which tracks the version compatible with the current
      # Home Assistant release. If HA reports a version mismatch, update this tag.
      image = "ghcr.io/home-assistant-libs/python-matter-server:stable";

      # Host network mode is required for:
      # - CHIP SDK mDNS multicast (device discovery + operational discovery, UDP 5353)
      # - Matter operational messaging to/from IoT devices (UDP 5540)
      # - WebSocket API accessible at localhost:5580 without port mapping
      networks = [ "host" ];

      # Persistent storage for Matter fabric credentials, node state, and certificates
      # IMPORTANT: This directory must persist across rebuilds - uses 'd' directive (not 'D')
      volumes = [
        "/var/lib/matter-server:/data:rw"
      ];

      # NET_ADMIN capability required for multicast group membership (mDNS)
      podmanArgs = [
        "--cap-add=NET_ADMIN"
      ];
    };

    unitConfig = {
      Description = "python-matter-server Matter/CHIP SDK controller";
      After = [
        "network-online.target"
        "podman.service"
      ];
      Wants = [
        "network-online.target"
        "podman.service"
      ];
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "15s";
      TimeoutStartSec = "120";
      # Container exit on SIGTERM is success (not a failure requiring restart)
      SuccessExitStatus = "143";
    };
  };

  # Persistent data directory for Matter fabric credentials
  # Uses 'd' (not 'D') directive to PRESERVE contents on rebuild
  systemd.tmpfiles.rules = [
    "d /var/lib/matter-server 0700 root root -"
  ];

  # Matter operational messaging from IoT devices to this server
  # UDP 5353 (mDNS) is already open in home-assistant.nix
  networking.firewall.allowedUDPPorts = [
    5540 # Matter operational messaging (CASE sessions, cluster communication)
  ];

  # Allow Home Assistant (on localhost) to connect to matter-server WebSocket API
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    5580 # python-matter-server WebSocket API
  ];
}
