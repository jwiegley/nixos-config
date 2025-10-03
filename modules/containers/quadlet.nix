{ config, lib, pkgs, ... }:

{
  # Import all container service modules
  imports = [
    ./litellm-quadlet.nix
    ./opnsense-exporter-quadlet.nix
    ./silly-tavern-quadlet.nix
    ./wallabag-quadlet.nix
  ];

  # Enable Podman with dockerCompat and ensure network is configured
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings = {
      dns_enabled = false;  # Disable DNS to avoid conflict with Technitium DNS Server
      # Ensure the default podman network is configured
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

  # Create a systemd service to ensure podman network exists
  systemd.services.ensure-podman-network = {
    description = "Ensure Podman network exists";
    after = [ "network.target" ];
    before = [ "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.podman}/bin/podman network exists podman || ${pkgs.podman}/bin/podman network create --disable-dns --subnet 10.88.0.0/16 --gateway 10.88.0.1 podman'";
    };
  };

  # Configure firewall to allow container traffic on podman0 interface
  networking.firewall.interfaces.podman0 = {
    allowedTCPPorts = [ 4000 5432 8085 ];
    allowedUDPPorts = [ 53 ];
  };

  # Add monitoring tools
  environment.systemPackages = with pkgs; [
    lazydocker
    podman-tui
  ];
}
