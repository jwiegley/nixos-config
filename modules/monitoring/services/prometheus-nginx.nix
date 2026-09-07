{
  config,
  lib,
  pkgs,
  hostPolicy,
  ...
}:

{
  # Nginx reverse proxy configuration for Prometheus UI
  services.nginx.virtualHosts."prometheus.${hostPolicy.dnsName}" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/prometheus.${hostPolicy.dnsName}.crt";
    sslCertificateKey = "/var/lib/nginx-certs/prometheus.${hostPolicy.dnsName}.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
      recommendedProxySettings = true;
    };
  };
}
