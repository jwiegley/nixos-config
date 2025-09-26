{ config, lib, pkgs, ... }:

{
  # Organizr container configuration
  virtualisation.quadlet.containers.organizr = {
    containerConfig = {
      image = "ghcr.io/organizr/organizr:latest";
      publishPorts = [ "127.0.0.1:8080:80/tcp" ];
      environments = {
        PUID = "1000";
        PGID = "100";
        TZ = config.time.timeZone;
      };
      volumes = [ "/var/lib/organizr:/config:Z" ];
      networks = [ "podman" ];
    };
    unitConfig = {
      After = [ "ensure-podman-network.service" "podman.service" ];
      Wants = [ "ensure-podman-network.service" ];
    };
  };

  # Nginx virtual host for Organizr
  services.nginx.virtualHosts."organizr.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/organizr.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/organizr.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
      '';
    };
  };

  # State directory for Organizr
  systemd.tmpfiles.rules = [
    "d /var/lib/organizr 0755 1000 100 -"
  ];
}