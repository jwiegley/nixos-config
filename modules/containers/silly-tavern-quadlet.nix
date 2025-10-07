{ config, lib, pkgs, ... }:

{
  # SillyTavern container configuration
  virtualisation.quadlet.containers.silly-tavern = {
    containerConfig = {
      image = "ghcr.io/sillytavern/sillytavern:latest";
      publishPorts = [ "127.0.0.1:8083:8000/tcp" ];
      environments = {
        USER_PASSWORD = "";
        AUTO_UPDATE = "false";
      };
      volumes = [
        "/var/lib/silly-tavern/config:/home/node/app/config:Z"
        "/var/lib/silly-tavern/data:/home/node/app/data:Z"
      ];
      networks = [ "podman" ];
    };
    unitConfig = {
      After = [ "podman.service" ];
    };
  };

  # Nginx virtual host for SillyTavern
  services.nginx.virtualHosts."silly-tavern.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/silly-tavern.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/silly-tavern.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8083/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
      '';
    };
  };

  # State directories for SillyTavern
  systemd.tmpfiles.rules = [
    "d /var/lib/silly-tavern/config 0755 1000 100 -"
    "d /var/lib/silly-tavern/data 0755 1000 100 -"
  ];
}