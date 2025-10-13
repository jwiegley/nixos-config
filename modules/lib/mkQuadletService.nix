{ config, lib, pkgs, ... }:

let
  common = import ./common.nix { };
in
{
  # Creates a Podman quadlet container with common configuration patterns
  #
  # Usage:
  #   mkQuadletService {
  #     name = "myapp";
  #     image = "docker.io/myapp:latest";
  #     port = 8080;
  #     requiresPostgres = true;
  #     secrets = { appPassword = "myapp-secrets"; };
  #     nginxVirtualHost = {
  #       enable = true;
  #       proxyPass = "http://127.0.0.1:8080/";
  #     };
  #     environments = {
  #       DATABASE_HOST = "10.88.0.1";
  #     };
  #   }
  #
  # This generates:
  # - Quadlet container configuration
  # - SOPS secrets
  # - Nginx virtual host (optional)
  # - PostgreSQL dependency checks (optional)
  # - Standard restart policies

  mkQuadletService = {
    # Required parameters
    name,              # Service name (e.g., "litellm")
    image,             # Container image (e.g., "ghcr.io/berriai/litellm:latest")
    port,              # Internal container port to expose

    # Optional parameters
    publishPorts ? [
      "127.0.0.1:${toString port}:${toString port}/tcp"
    ],                 # Port mappings (default: localhost only)
    requiresPostgres ? false,  # Add PostgreSQL dependency and pg_isready check
    secrets ? {},      # SOPS secrets: { secretName = "sops-key-path"; }
    secretsRestartUnits ? true,  # Whether secrets should restart the service
    environments ? {}, # Environment variables
    environmentFiles ? [],  # Environment files to load
    volumes ? [],      # Volume mounts
    exec ? null,       # Container exec command

    nginxVirtualHost ? null,  # { enable = true; proxyPass = "..."; extraConfig = "..."; }

    extraUnitConfig ? {},      # Additional systemd unit config
    extraServiceConfig ? {},   # Additional systemd service config
    extraContainerConfig ? {}, # Additional quadlet container config

    tmpfilesRules ? [],  # Additional tmpfiles.d rules
  }:
  let
    serviceName = "${name}.service";
    hostname = "${name}.vulcan.lan";

    # Build environment files list
    allEnvironmentFiles = environmentFiles ++
      (lib.optionals (secrets != {})
        (map (secretName: config.sops.secrets."${secretName}".path) (lib.attrValues secrets)));
  in
  {
    # Quadlet container configuration
    virtualisation.quadlet.containers.${name} = {
      # Explicitly enable autoStart to ensure service starts on boot and after rebuild
      autoStart = true;

      containerConfig = lib.mkMerge [
        {
          inherit image;
          publishPorts = publishPorts;
          environments = environments;
          environmentFiles = allEnvironmentFiles;
          volumes = volumes;
          networks = [ "podman" ];
          # Use host DNS via Podman gateway for .lan domain resolution
          dns = [ common.postgresDefaults.host ];
        }
        (lib.optionalAttrs (exec != null) { inherit exec; })
        extraContainerConfig
      ];

      unitConfig = lib.mkMerge [
        {
          After = [ "sops-nix.service" "podman.service" ]
            ++ lib.optional requiresPostgres "postgresql.service";
          Wants = [ "sops-nix.service" ]
            ++ lib.optional requiresPostgres "postgresql.service";
          Requires = lib.optional requiresPostgres "postgresql.service";
        }
        # Add restart rate limiting to [Unit] section
        common.restartPolicies.always.unit
        extraUnitConfig
      ];

      serviceConfig = lib.mkMerge [
        (lib.optionalAttrs requiresPostgres {
          # Wait for PostgreSQL to be ready to accept connections
          ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h ${common.postgresDefaults.host} -p ${toString common.postgresDefaults.port} -t 30";
        })
        # Add restart behavior to [Service] section
        common.restartPolicies.always.service
        extraServiceConfig
      ];
    };

    # Ensure systemd restarts the service on configuration changes
    systemd.services.${serviceName} = {
      restartIfChanged = true;
      restartTriggers = [
        # Trigger restart when container config changes
        config.virtualisation.quadlet.containers.${name}._configText
      ];
    };

    # SOPS secrets configuration
    sops.secrets = lib.mkMerge [
      (lib.mapAttrs' (secretName: sopsKey:
        lib.nameValuePair sopsKey {
          sopsFile = common.secretsPath;
          owner = "root";
          group = "root";
          mode = "0400";
          restartUnits = lib.optional secretsRestartUnits serviceName;
        }
      ) secrets)
    ];

    # Nginx virtual host (optional)
    services.nginx.virtualHosts = lib.mkIf (nginxVirtualHost != null && nginxVirtualHost.enable or false) {
      ${hostname} = lib.mkMerge [
        {
          forceSSL = true;
        }
        (common.nginxSSLPaths name)
        {
          locations."/" = {
            proxyPass = nginxVirtualHost.proxyPass;
            proxyWebsockets = nginxVirtualHost.proxyWebsockets or false;
            extraConfig = nginxVirtualHost.extraConfig or "";
          };
        }
      ];
    };

    # State directory
    systemd.tmpfiles.rules = [
      "d /var/lib/${name} 0755 root root -"
    ] ++ tmpfilesRules;
  };
}
