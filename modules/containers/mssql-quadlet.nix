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
        "/var/lib/mssql/data:/var/opt/mssql/data:rw"
        "/var/lib/mssql/log:/var/opt/mssql/log:rw"
        "/var/lib/mssql/secrets:/var/opt/mssql/secrets:rw"
        "/var/lib/mssql/backups:/var/opt/mssql/backups:rw"
      ];

      # Use QEMU emulation to run AMD64 container on ARM64
      # MSSQL Server is only available for AMD64, requires emulation on ARM64
      extraContainerConfig = {
        podmanArgs = [ "--platform=linux/amd64" ];
      };

      # SQL Server doesn't have a web UI, so no nginx virtual host
      nginxVirtualHost = null;
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
