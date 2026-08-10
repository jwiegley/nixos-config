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
      #
      # WARNING: /var/lib/matter-server IS the Matter fabric identity (credentials/,
      # chip_factory.ini, <fabric-id>.json). Lose it and every paired device must be
      # physically re-paired -- HA cannot re-adopt them, a Matter device only trusts the
      # fabric CA that commissioned it. Before re-commissioning, recreating the container,
      # or changing this volume: stop the unit and `cp -a /var/lib/matter-server <backup>`.
      volumes = [
        "/var/lib/matter-server:/data:rw"
      ];

      # NET_ADMIN capability required for multicast group membership (mDNS)
      podmanArgs = [
        "--cap-add=NET_ADMIN"
      ];

      # Quiet the INFO chatter. python-matter-server logs device_controller and
      # vendor_info INFO lines to STDERR, which journald then tags priority=err
      # -- so ~110 lines/hour of routine operation showed up in every
      # `journalctl -p err` review and in logwatch's digest as if they were
      # faults. warning+ keeps anything actionable.
      #
      # Does NOT silence the `CHIP_ERROR ... Subscription Liveness timeout`
      # lines (~23/hour, chronic): those come from the CHIP SDK's own native
      # logger at ERROR level and are a real, if benign, signal about Thread
      # device subscriptions. Deliberately left visible.
      # THE STORAGE FLAGS ARE LOAD-BEARING AND MUST STAY HERE. Podman args after
      # the image name REPLACE the image's CMD (ENTRYPOINT is kept), and this
      # image declares
      #   Cmd = ["--storage-path" "/data" "--paa-root-cert-dir" "/data/credentials"]
      # so an `exec` of just "--log-level warning" silently DELETED both.
      #
      # That is what happened from 2026-08-03 12:25:23 (generation 2390; 2389 was
      # the last clean one) until 2026-08-10. With --storage-path gone the Python
      # layer fell back to $HOME/.matter_server inside the container's --rm
      # writable layer, minted a SUBSTITUTE CA and fabric, and served that to
      # Home Assistant. All 6 commissioned devices -- 26 entities -- were
      # unavailable for seven days while the unit reported active and the real
      # node DB in /var/lib/matter-server sat untouched.
      #
      # It stayed silent because the split is PARTIAL: the native CHIP layer has
      # compiled-in Home Assistant add-on defaults, so chip_factory.ini,
      # chip_config.ini and chip_counters.ini kept resolving to /data and kept
      # being written. Only the Python-level chip.json followed the missing flag.
      # So the mount looked live in every `ls` while the fabric was not, and the
      # nightly update-containers restart re-ran the broken start eight times.
      #
      # If you need to change the log level again, APPEND. Do not replace.
      exec = "--storage-path /data --paa-root-cert-dir /data/credentials --log-level warning";
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
  # WARNING: 'D' here would empty the fabric identity on every rebuild and force a
  # physical re-pairing of EVERY Matter device. Back it up with
  # `cp -a /var/lib/matter-server <backup>` (unit stopped) before editing this rule.
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
