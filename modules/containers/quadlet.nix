{ config, lib, pkgs, ... }:

{
  # Import all container service modules
  imports = [
    ./elasticsearch-quadlet.nix
    ./litellm-quadlet.nix
    ./opnsense-api-transformer.nix  # Python proxy to fix opnsense-exporter gateway collector issue
    ./opnsense-exporter-quadlet.nix
    ./openspeedtest-quadlet.nix
    ./paperless-ai-quadlet.nix
    ./ragflow-quadlet.nix
    ./silly-tavern-quadlet.nix
    ./technitium-dns-exporter-quadlet.nix
    ./wallabag-quadlet.nix
  ];

  # Enable Podman with dockerCompat and ensure network is configured
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings = {
      dns_enabled = false;  # Disabled: conflicts with Technitium DNS on 0.0.0.0:53 (aardvark-dns can't bind to 10.88.0.1:53)
      # Containers will use host's /etc/resolv.conf (192.168.1.2, 192.168.1.1) for DNS resolution
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

  # Note: Podman network is automatically managed by NixOS via virtualisation.podman.defaultNetwork.settings
  # No manual network creation needed - the defaultNetwork.settings above configures the "podman" network

  # Configure firewall to allow container traffic on podman0 interface
  networking.firewall.interfaces.podman0 = {
    allowedTCPPorts = [ 4000 5380 5432 8085 28981 ];  # 4000: litellm, 5380: Technitium DNS, 5432: PostgreSQL, 8085: Redis, 28981: paperless-ngx
    allowedUDPPorts = [ 53 ];
  };

  # Add monitoring tools
  environment.systemPackages = with pkgs; [
    lazydocker
    podman-tui
  ];
}
