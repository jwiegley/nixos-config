{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "speedtest";  # Used for hostname speedtest.vulcan.lan
      image = "docker.io/openspeedtest/latest:latest";
      port = 3002;
      requiresPostgres = false;

      publishPorts = [ "127.0.0.1:3002:3000/tcp" ];

      # Disable health checks - not supported by quadlet-nix
      healthCheck.enable = false;
      enableWatchdog = false;

      nginxVirtualHost = {
        enable = true;
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

      # Simple service, no restart policy overrides needed
      extraServiceConfig = {};
    })
  ];
}
