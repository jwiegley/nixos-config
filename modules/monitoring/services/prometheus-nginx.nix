{ config, lib, pkgs, ... }:

{
  # Nginx reverse proxy configuration for Prometheus UI
  services.nginx.virtualHosts."prometheus.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/prometheus.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/prometheus.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
      recommendedProxySettings = true;
    };
  };
}
