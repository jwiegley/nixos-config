{ config, lib, pkgs, ... }:

{
  # Import all container service modules
  imports = [
    ./changedetection-quadlet.nix
    ./litellm-quadlet.nix
    ./metabase-quadlet.nix
    # Python proxy to fix opnsense-exporter gateway collector issue
    ./opnsense-api-transformer.nix
    ./opnsense-exporter-quadlet.nix
    ./openspeedtest-quadlet.nix
    ./silly-tavern-quadlet.nix
    ./teable-quadlet.nix
    ./technitium-dns-exporter-quadlet.nix
    ./vanna-quadlet.nix
    ./wallabag-quadlet.nix
  ];

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

  # Enable auto-escaping for quadlet configurations
  virtualisation.quadlet.autoEscape = true;

  # Note: Podman network is automatically managed by NixOS via
  # virtualisation.podman.defaultNetwork.settings No manual network creation
  # needed - the defaultNetwork.settings above configures the "podman" network

  # Configure firewall to allow container traffic on podman0 interface
  networking.firewall.interfaces.podman0 = {
    # 1433: mssql
    # 3001: teable
    # 3200: metabase
    # 4000: litellm
    # 5000: vanna
    # 5380: Technitium DNS
    # 5432: PostgreSQL
    # 8085: Redis
    # 9182: mssql-exporter
    allowedTCPPorts = [ 1433 3001 3200 4000 5000 5380 5432 8085 9182 ];
    allowedUDPPorts = [ 53 ];
  };

  # Add monitoring tools
  environment.systemPackages = with pkgs; [
    lazydocker
    podman-tui
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
