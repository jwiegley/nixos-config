{ config, lib, pkgs, ... }:

{
  # OpenSpeedTest container configuration
  virtualisation.quadlet.containers.openspeedtest = {
    containerConfig = {
      image = "docker.io/openspeedtest/latest:latest";
      publishPorts = [ "127.0.0.1:3002:3000/tcp" ];
      networks = [ "podman" ];
    };
    unitConfig = {
      After = [ "podman.service" ];
    };
  };

  # Nginx virtual host for OpenSpeedTest
  services.nginx.virtualHosts."speedtest.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/speedtest.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/speedtest.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:3002/";
      extraConfig = ''
        # OpenSpeedTest requires these settings for accurate speed measurements
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;

        # Client body size for upload tests (35MB as per OpenSpeedTest requirements)
        client_max_body_size 35M;
      '';
    };
  };
}
