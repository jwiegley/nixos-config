{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Vane internal port (host network mode, bound to localhost)
  vanePort = 3007;
in
{
  # Persistent data directory for Vane
  systemd.tmpfiles.rules = [
    "d /var/lib/vane 0750 vane vane -"
    "d /var/lib/vane/data 0750 vane vane -"
    "d /var/lib/vane/uploads 0750 vane vane -"
  ];

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."vane.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/vane.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/vane.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString vanePort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        proxy_read_timeout 1800s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 1800s;
        client_max_body_size 50M;
      '';
    };
  };

  # Allow nginx to access Vane on loopback
  networking.firewall.interfaces."lo".allowedTCPPorts = [ vanePort ];
}
