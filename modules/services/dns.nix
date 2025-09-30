{ config, lib, pkgs, ... }:

{
  systemd.services.technitium-dns-server.serviceConfig = {
    WorkingDirectory = lib.mkForce null;
    BindPaths = lib.mkForce null;
  };

  services.technitium-dns-server = {
    enable = true;
    openFirewall = false;
  };

  networking.firewall.allowedTCPPorts =
    lib.mkIf config.services.technitium-dns-server.enable [ 853 ];
}
