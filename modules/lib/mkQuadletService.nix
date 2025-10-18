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
    createStateDir ? true,  # Whether to create default /var/lib/${name} directory
  }:
  let
    hostname = "${name}.vulcan.lan";

    # Build environment files list
    allEnvironmentFiles = environmentFiles ++
      (lib.optionals (secrets != {})
        (map (secretName: config.sops.secrets."${secretName}".path) (lib.attrValues secrets)));
  in
  {
    # VALIDATION: Prevent DNS configuration in extraContainerConfig
    # This assertion will fail the build if someone tries to set DNS, catching
    # the recurring bug at build time instead of runtime.
    assertions = [
      {
        assertion = !(extraContainerConfig ? dns);
        message = ''
          ❌ CRITICAL ERROR: DNS configuration detected in mkQuadletService for ${name}!

          You tried to set 'dns' in extraContainerConfig, which will break .lan domain resolution.
          This is a RECURRING BUG that has occurred 5+ times.

          REMOVE THIS:
            extraContainerConfig = {
              dns = [ ... ];  # ← DELETE THIS LINE
            };

          WHY THIS BREAKS:
          - Setting explicit dns = [...] disables Podman's automatic DNS forwarding
          - Containers can't resolve .lan domains (hera.lan, athena.lan, etc.)
          - Results in "Temporary failure in name resolution" errors

          WHAT TO DO:
          - Remove the dns setting from extraContainerConfig
          - Podman's defaults will automatically forward to host DNS
          - See modules/lib/mkQuadletService.nix:82-119 for detailed explanation

          If you absolutely need custom DNS (you probably don't):
          1. Read the full documentation in mkQuadletService.nix first
          2. Test with: podman exec ${name} nslookup hera.lan
          3. Document WHY you're overriding the default

          This assertion exists to prevent this bug from recurring.
        '';
      }
    ];

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

          # ═══════════════════════════════════════════════════════════════════════
          # ⚠️  CRITICAL: DO NOT SET dns = [...] IN THIS CONFIGURATION!  ⚠️
          # ═══════════════════════════════════════════════════════════════════════
          #
          # This bug has occurred 5+ times. Read carefully before making ANY changes:
          #
          # ❌ WRONG (BREAKS .lan DOMAIN RESOLUTION):
          #    dns = [ "10.88.0.1" ];  # ← PostgreSQL server, NOT a DNS server!
          #    dns = [ common.postgresDefaults.host ];  # ← Same thing, still wrong!
          #
          # ✅ CORRECT (CURRENT CONFIGURATION):
          #    (no dns setting at all - uses Podman defaults)
          #
          # WHY THIS KEEPS BREAKING:
          # - Podman's default DNS automatically forwards to host DNS (/etc/resolv.conf)
          # - Host DNS resolves .lan domains (192.168.1.2, 192.168.1.1)
          # - Setting explicit dns = [...] DISABLES automatic forwarding
          # - Containers then can't resolve hera.lan, athena.lan, etc.
          #
          # SYMPTOMS WHEN BROKEN:
          # - "socket.gaierror: [Errno -3] Temporary failure in name resolution"
          # - "ClientConnectorDNSError: Cannot connect to host *.lan"
          # - litellm can't load models from hera.lan/athena.lan
          #
          # HOW PODMAN DEFAULT DNS WORKS:
          # - Copies host's /etc/resolv.conf nameservers to container
          # - May add 169.254.1.1 (aardvark-dns) for advanced features
          # - Automatically adapts when host DNS changes
          # - Perfect for .lan domain resolution
          #
          # IF YOU THINK YOU NEED TO SET DNS:
          # 1. You probably don't - Podman's defaults work for 99% of cases
          # 2. If you really need custom DNS, use extraContainerConfig in the
          #    individual service file, NOT here in mkQuadletService
          # 3. Test thoroughly with: podman exec <container> nslookup hera.lan
          # 4. Document WHY you're overriding the default
          #
          # ═══════════════════════════════════════════════════════════════════════
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

    # Note: Quadlet automatically manages the systemd service lifecycle.
    # We don't need to directly configure systemd.services.${name} here because:
    # 1. Quadlet generates the service unit from the .container file
    # 2. autoStart = true in containerConfig ensures it starts on boot
    # 3. Direct systemd.services configuration conflicts with quadlet-nix's overrideStrategy
    # 4. restartTriggers would require mkForce to override the strategy, but that's fragile

    # SOPS secrets configuration
    sops.secrets = lib.mkMerge [
      (lib.mapAttrs' (secretName: sopsKey:
        lib.nameValuePair sopsKey {
          sopsFile = common.secretsPath;
          owner = "root";
          group = "root";
          mode = "0400";
          restartUnits = lib.optional secretsRestartUnits "${name}.service";
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
    systemd.tmpfiles.rules =
      (lib.optional createStateDir "d /var/lib/${name} 0755 root root -")
      ++ tmpfilesRules;
  };
}
