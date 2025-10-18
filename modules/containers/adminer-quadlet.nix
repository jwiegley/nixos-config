{ config, lib, pkgs, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "adminer";
      image = "adminer:latest";
      port = 8080;

      # Publish on localhost for nginx proxy
      publishPorts = [
        "127.0.0.1:8086:8080/tcp"
      ];

      environments = {
        ADMINER_DEFAULT_SERVER = "10.88.0.1";  # SQL Server on podman gateway
        ADMINER_DESIGN = "nette";  # Nice theme
      };

      # Enable nginx virtual host with SSL
      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:8086/";
        extraConfig = ''
          # Adminer specific settings
          client_max_body_size 50M;
          proxy_read_timeout 300s;
        '';
      };

      createStateDir = false;
    })
  ];
}
