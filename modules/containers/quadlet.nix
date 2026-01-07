{ config, lib, pkgs, ... }:

{
  # Import all container service modules
  imports = [
    ./budgetboard-quadlet.nix
    ./changedetection-quadlet.nix
    ./letta-quadlet.nix
    ./litellm-quadlet.nix
    ./mailarchiver-quadlet.nix
    ./nocobase-quadlet.nix
    # Python proxy to fix opnsense-exporter gateway collector issue
    ./opnsense-api-transformer.nix
    ./opnsense-exporter-quadlet.nix
    ./openspeedtest-quadlet.nix
    ./shlink-quadlet.nix
    ./silly-tavern-quadlet.nix
    ./teable-quadlet.nix
    ./technitium-dns-exporter-quadlet.nix
    ./wallabag-quadlet.nix
  ];

  # Enable container runtime support (required for rootless containers)
  virtualisation.containers.enable = true;

  # Configure container storage for rootless support
  virtualisation.containers.storage.settings = {
    storage = {
      driver = "overlay";  # Using overlay for compatibility with ext4/zfs
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

  # Configure systemd user environment for rootless containers
  # Required for rootless podman to access newuidmap and other tools
  systemd.user.extraConfig = ''
    DefaultEnvironment="PATH=/run/current-system/sw/bin:/run/wrappers/bin"
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
    # 13000: nocobase
    allowedTCPPorts = [ 1433 3001 4000 5380 5432 6253 8085 9182 13000 ];
    allowedUDPPorts = [ 53 ];
  };

  # Add monitoring tools and rootless container dependencies
  environment.systemPackages = with pkgs; [
    lazydocker
    podman-tui
    slirp4netns  # Required for rootless networking
  ];

  # Ensure podman service starts early and creates network properly
  systemd.services.podman = {
    wantedBy = [ "multi-user.target" "network-online.target" ];
    after = [ "network.target" ];
    before = [ "redis-litellm.service" "litellm.service" ];

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
