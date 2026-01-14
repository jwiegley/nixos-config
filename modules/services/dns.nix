{
  config,
  lib,
  pkgs,
  ...
}:

{
  systemd.services.technitium-dns-server.serviceConfig = {
    WorkingDirectory = lib.mkForce null;
    BindPaths = lib.mkForce null;
  };

  services.technitium-dns-server = {
    enable = true;
    openFirewall = false;
  };

  services.nginx.virtualHosts."dns.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/dns.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/dns.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5380/";
      proxyWebsockets = true;
    };
  };

  networking.firewall = {
    allowedTCPPorts = lib.mkIf config.services.technitium-dns-server.enable [
      53
      853
    ];
    allowedUDPPorts = lib.mkIf config.services.technitium-dns-server.enable [ 53 ];
  };
}
