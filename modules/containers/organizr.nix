{ config, lib, pkgs, ... }:

let
  containerUser = {
    PUID = "1010";
    PGID = "1010";
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/organizr 0755 container-data container-data -"
  ];

  virtualisation.oci-containers.containers.organizr = {
    autoStart = true;
    image = "ghcr.io/organizr/organizr:latest";
    ports = [ "127.0.0.1:8080:80/tcp" ];
    environment = containerUser;
    volumes = [ "/var/lib/organizr:/config" ];
  };

  services.nginx.virtualHosts."organizr.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/organizr.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/organizr.vulcan.lan.key";
    locations."/".proxyPass = "http://127.0.0.1:8080/";
  };
}
