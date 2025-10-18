{ config, lib, pkgs, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "mssql";
      image = "mcr.microsoft.com/mssql/server:2022-latest";
      port = 1433;

      # Publish on both localhost and podman gateway for container access
      # External network access is allowed via firewall on port 1433
      publishPorts = [
        "0.0.0.0:1433:1433/tcp"  # Allow connections from anywhere
      ];

      environments = {
        ACCEPT_EULA = "Y";
        MSSQL_PID = "Developer";  # Free developer edition
        MSSQL_DATA_DIR = "/var/opt/mssql/data";
        MSSQL_LOG_DIR = "/var/opt/mssql/log";
        MSSQL_BACKUP_DIR = "/var/opt/mssql/backups";
      };

      # Use environment file for secrets
      environmentFiles = [ config.sops.templates."mssql-env".path ];

      volumes = [
        "/tank/SQLServer/data:/var/opt/mssql/data:rw"
        "/tank/SQLServer/log:/var/opt/mssql/log:rw"
        "/tank/SQLServer/secrets:/var/opt/mssql/secrets:rw"
        "/tank/SQLServer/backups:/var/opt/mssql/backups:rw"
      ];

      # SQL Server doesn't have a web UI, so no nginx virtual host
      nginxVirtualHost = null;

      createStateDir = false;  # Using ZFS dataset instead
    })
  ];

  # SOPS secret for SA password
  sops.secrets."mssql/sa-password" = {
    sopsFile = ../../secrets.yaml;
  };

  # Create environment file template from SOPS secret
  sops.templates."mssql-env" = {
    content = ''
      MSSQL_SA_PASSWORD=${config.sops.placeholder."mssql/sa-password"}
    '';
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # Open SQL Server port on firewall
  networking.firewall = {
    allowedTCPPorts = [ 1433 ];
    interfaces.podman0.allowedTCPPorts = [ 1433 ];
  };
}
