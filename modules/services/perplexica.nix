{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Perplexica internal port (host network mode, bound to localhost)
  perplexicaPort = 3007;
in
{
  # Persistent data directory for Perplexica
  systemd.tmpfiles.rules = [
    "d /var/lib/perplexica 0750 perplexica perplexica -"
    "d /var/lib/perplexica/data 0750 perplexica perplexica -"
    "d /var/lib/perplexica/uploads 0750 perplexica perplexica -"
  ];

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."perplexica.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/perplexica.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/perplexica.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString perplexicaPort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        client_max_body_size 50M;
      '';
    };
  };

  # Allow nginx to access Perplexica on loopback
  networking.firewall.interfaces."lo".allowedTCPPorts = [ perplexicaPort ];
}
