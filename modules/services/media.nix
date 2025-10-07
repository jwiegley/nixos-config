{ config, lib, pkgs, ... }:

{
  services = {
    jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      user = "johnw";
      openFirewall = false;
    };
  };

  services.nginx.virtualHosts."jellyfin.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/jellyfin.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/jellyfin.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8096/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Forwarded-Protocol $scheme;
        proxy_set_header X-Forwarded-Host $http_host;

        # Disable buffering when the nginx proxy gets very resource heavy upon
        # streaming
        proxy_buffering off;
      '';
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts =
    lib.mkIf config.services.jellyfin.enable [ 8096 ];
}
