{ config, lib, pkgs, ... }:

{
  services = {
    jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      user = "johnw";
    };
  };

  services.nginx.virtualHosts."jellyfin.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/jellyfin.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/jellyfin.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8096/";
      proxyWebsockets = true;
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts =
    lib.mkIf config.services.jellyfin.enable [ 8096 ];
}
