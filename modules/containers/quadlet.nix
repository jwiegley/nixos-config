{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Import all container service modules
  imports = [
    ./budgetboard-quadlet.nix
    ./changedetection-quadlet.nix
    ./litellm-quadlet.nix
    ./mailarchiver-quadlet.nix
    ./open-webui-quadlet.nix
    # Python proxy to fix opnsense-exporter gateway collector issue
    ./opnsense-api-transformer.nix
    ./opnsense-exporter-quadlet.nix
    ./openspeedtest-quadlet.nix
    ./shlink-quadlet.nix
    ./speedtest-tracker-quadlet.nix
    ./teable-quadlet.nix
    ./technitium-dns-exporter-quadlet.nix
    ./wallabag-quadlet.nix
  ];

  # Enable container runtime support (required for rootless containers)
  virtualisation.containers.enable = true;

  # Pin host.containers.internal to the podman0 bridge address (2026-07-03
  # post-reboot audit). Without this, rootless quadlets started by lingering
  # user managers race NetworkManager at boot: podman picks the first
  # non-loopback host IP — the microVM bridge 10.99.0.1 — freezes it into the
  # container's /etc/hosts for the container's lifetime, and every DB client
  # then hits pg_hba's reject catch-all in a retry storm (hit speedtest-tracker,
  # memory-vault, shlink, openproject, litellm on the 2026-07-03 boot).
  # 10.88.0.1 is config-static (defaultNetwork below), host-owned regardless of
  # which LAN interface has carrier, PostgreSQL binds it, and pg_hba admits
  # 10.88.0.0/16. Do NOT use a LAN address here — vulcan is multi-homed
  # (end0 + WiFi) and either can be down at boot.
  virtualisation.containers.containersConf.settings.containers = {
    host_containers_internal_ip = "10.88.0.1";
  };

  # Configure container storage for rootless support
  virtualisation.containers.storage.settings = {
    storage = {
      driver = "overlay"; # Using overlay for compatibility with ext4/zfs
      runroot = "/run/containers/storage";
      graphroot = "/var/lib/containers/storage";
      options.overlay.mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs";
    };
  };

  # Enable Podman with dockerCompat and ensure network is configured
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings = {
      # Disabled: conflicts with Technitium DNS on 0.0.0.0:53
      dns_enabled = false;
      # Containers will use host's /etc/resolv.conf (192.168.1.2, 192.168.1.1)
      # for DNS resolution
      subnets = [
        {
          subnet = "10.88.0.0/16";
          gateway = "10.88.0.1";
        }
      ];
    };
    autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
  };

  # Configure systemd user environment for rootless containers.
  # `/run/wrappers/bin` MUST come before `/run/current-system/sw/bin` so that
  # podman's exec.LookPath finds the setuid wrapper for `newuidmap`/`newgidmap`
  # rather than the bare nix-store symlink. With the wrong order, rootless
  # containers fail with: "cannot set up namespace using
  # /run/current-system/sw/bin/newuidmap: should have setuid or have filecaps
  # setuid" (observed 2026-05-21 on shlink/shlink-web-client).
  systemd.user.extraConfig = ''
    DefaultEnvironment="PATH=/run/wrappers/bin:/run/current-system/sw/bin"
  '';

  # Enable quadlet and auto-escaping for quadlet configurations
  virtualisation.quadlet = {
    enable = true;
    autoEscape = true;
  };

  # Note: Podman network is automatically managed by NixOS via
  # virtualisation.podman.defaultNetwork.settings No manual network creation
  # needed - the defaultNetwork.settings above configures the "podman" network

  # Configure firewall to allow container traffic on podman0 interface
  networking.firewall.interfaces.podman0 = {
    # 1433: mssql
    # 3001: teable
    # 4000: litellm
    # 5380: Technitium DNS
    # 5432: PostgreSQL
    # 6253: budgetboard-client
    # 8085: Redis
    # 9182: mssql-exporter
    allowedTCPPorts = [
      1433
      3001
      4000
      5380
      5432
      6253
      8085
      9182
    ];
    allowedUDPPorts = [ 53 ];
  };

  # Add monitoring tools and rootless container dependencies
  environment.systemPackages = with pkgs; [
    lazydocker
    podman-tui
    slirp4netns # Required for rootless networking
  ];

  # Ensure podman service starts early and creates network properly
  systemd.services.podman = {
    wantedBy = [
      "multi-user.target"
      "network-online.target"
    ];
    after = [ "network.target" ];
    before = [
      "redis-litellm.service"
      "litellm.service"
    ];

    # Ensure podman network is created and interface is up
    postStart = ''
      # Check if podman network exists, create if not
      if ! ${pkgs.podman}/bin/podman network exists podman 2>/dev/null; then
        echo "Creating podman network..."
        ${pkgs.podman}/bin/podman network create --subnet 10.88.0.0/16 podman || true
      fi

      # Ensure the bridge interface is up
      if ${pkgs.iproute2}/bin/ip link show podman0 >/dev/null 2>&1; then
        ${pkgs.iproute2}/bin/ip link set podman0 up || true
      fi
    '';
  };
}
