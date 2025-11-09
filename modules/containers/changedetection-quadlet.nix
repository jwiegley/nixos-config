{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "changedetection";
      image = "ghcr.io/dgtlmoon/changedetection.io:latest";
      port = 5000;
      containerUser = "changedetection";  # Run rootless as dedicated changedetection user

      # Health checks disabled - not supported for rootless system users
      # Rootless containers run by system users (not logged-in users) can't
      # create /tmp/storage-run-<uid>/systemd directories for health checks
      healthCheck = {
        enable = false;
      };
      enableWatchdog = false;

      secrets = {
        apiKey = "changedetection/api-key";
      };

      # Override default port publishing to use 5055 instead of 5000
      publishPorts = [ "127.0.0.1:5055:5000/tcp" ];

      environments = {
        PORT = "5000";
        BASE_URL = "https://changes.vulcan.lan";
        FETCH_WORKERS = "10";
        LOGGER_LEVEL = "INFO";
        TZ = "America/Los_Angeles";
      };

      volumes = [
        "/var/lib/changedetection:/datastore:rw"
      ];

      # Nginx virtual host disabled - manually configured below for custom hostname
      nginxVirtualHost = null;
    })
  ];

  # Nginx virtual host using "changes.vulcan.lan" instead of "changedetection.vulcan.lan"
  services.nginx.virtualHosts."changes.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/changes.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/changes.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5055/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
      '';
    };
  };

  # Create changedetection system user for rootless operation
  users.users.changedetection = {
    isSystemUser = true;
    group = "changedetection";
    description = "ChangeDetection.io service user";
    home = "/var/lib/containers/changedetection";
    createHome = true;
  };

  users.groups.changedetection = {};

  # Ensure data directory has correct ownership for container data
  # Home directory (/var/lib/containers/changedetection) is managed by home-manager
  systemd.tmpfiles.rules = [
    "d /var/lib/changedetection 0755 changedetection changedetection -"
  ];
}
