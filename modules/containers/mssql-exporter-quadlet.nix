{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "mssql-exporter";
      image = "awaragi/prometheus-mssql-exporter:latest";
      port = 4000;

      # Publish on different external port to avoid conflict with litellm
      publishPorts = [
        "127.0.0.1:9182:4000/tcp"
      ];

      environments = {
        SERVER = "10.88.0.1";  # SQL Server on podman gateway
        PORT = "1433";
        USERNAME = "sa";
        # PASSWORD comes from environment file
        DEBUG = "false";
      };

      # Use the same password as SQL Server
      environmentFiles = [ config.sops.templates."mssql-exporter-env".path ];

      # SQL Server exporter doesn't need nginx (Prometheus scrapes directly)
      nginxVirtualHost = null;

      extraUnitConfig = {
        After = [ "mssql.service" ];
        Wants = [ "mssql.service" ];
      };
    })
  ];

  # SOPS template for exporter environment
  sops.templates."mssql-exporter-env" = {
    content = ''
      PASSWORD=${config.sops.placeholder."mssql/sa-password"}
    '';
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # Open exporter port on podman network (Prometheus needs access)
  networking.firewall.interfaces.podman0.allowedTCPPorts = [ 9182 ];
}
