{ config, lib, pkgs, secrets, ... }:

let
  common = import ./common.nix { inherit secrets; };
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
  #     containerUser = "container-db";  # Optional: enables rootless operation
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
  # - SOPS secrets (deployed to /run/secrets-<user>/ if containerUser is set)
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
    containerUser ? null,  # Container user for rootless operation (e.g., "container-db")
    secrets ? {},      # SOPS secrets: { secretName = "sops-key-path"; }
    secretsRestartUnits ? true,  # Whether secrets should restart the service
    environments ? {}, # Environment variables
    environmentFiles ? [],  # Environment files to load
    volumes ? [],      # Volume mounts
    exec ? null,       # Container exec command

    nginxVirtualHost ? null,  # { enable = true; proxyPass = "..."; extraConfig = "..."; }

    # Health monitoring options
    # NOTE: Health checks are disabled by default because quadlet-nix doesn't support
    # the healthChecks option. If quadlet-nix adds support in the future, we can re-enable.
    healthCheck ? {
      enable = false;          # Disabled - not supported by quadlet-nix
      type = "http";           # "http", "tcp", or "exec"
      interval = "30s";        # How often to run health check
      timeout = "10s";         # Health check timeout
      startPeriod = "60s";     # Grace period for startup
      retries = 3;             # Failures before unhealthy
      httpPath = "/";          # HTTP path to check (for type = "http")
      httpPort = null;         # HTTP port (defaults to 'port' parameter)
      tcpPort = null;          # TCP port (for type = "tcp")
      execCommand = null;      # Custom exec command (for type = "exec")
    },
    enableWatchdog ? false,    # Disabled - depends on health checks

    extraUnitConfig ? {},      # Additional systemd unit config
    extraServiceConfig ? {},   # Additional systemd service config
    extraContainerConfig ? {}, # Additional quadlet container config

    tmpfilesRules ? [],  # Additional tmpfiles.d rules
  }:
  let
    hostname = "${name}.vulcan.lan";

    # Build environment files list
    allEnvironmentFiles = environmentFiles ++
      (lib.optionals (secrets != {})
        (map (secretName: config.sops.secrets."${secretName}".path) (lib.attrValues secrets)));

    # Build health check command based on type
    healthCheckPort =
      if lib.hasAttr "httpPort" healthCheck && healthCheck.httpPort != null then healthCheck.httpPort
      else if lib.hasAttr "tcpPort" healthCheck && healthCheck.tcpPort != null then healthCheck.tcpPort
      else port;

    healthCheckCmd =
      if !healthCheck.enable then null
      else if healthCheck.type == "http" then
        "curl -f http://localhost:${toString healthCheckPort}${healthCheck.httpPath} || exit 1"
      else if healthCheck.type == "tcp" then
        "nc -z localhost ${toString healthCheckPort} || exit 1"
      else if healthCheck.type == "exec" && healthCheck.execCommand != null then
        healthCheck.execCommand
      else null;

    # Systemd watchdog interval (set to 2x health check interval for safety margin)
    watchdogSec = if enableWatchdog && healthCheck.enable then
      let
        # Parse interval string (e.g., "30s" -> 30)
        intervalNum = lib.toInt (lib.removeSuffix "s" healthCheck.interval);
      in
        "${toString (intervalNum * 2)}s"
      else null;
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
          - Containers can't resolve .lan domains (hera.lan, etc.)
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
      {
        assertion = !healthCheck.enable || healthCheckCmd != null;
        message = ''
          ❌ Health check configuration error for ${name}!

          Health check is enabled but no valid health check command could be generated.

          Current configuration:
          - type: ${healthCheck.type}
          - execCommand: ${if healthCheck.execCommand != null then "provided" else "null"}

          For type="exec", you must provide execCommand.
          For type="http" or type="tcp", ensure the port is correctly configured.
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
          # Rootless containers use localhost for database access
          environments = environments // (lib.optionalAttrs (containerUser != null && requiresPostgres) {
            POSTGRES_HOST = "127.0.0.1";
          });
          environmentFiles = allEnvironmentFiles;
          volumes = volumes;
          # Rootless containers use slirp4netns with allow_host_loopback
          # This allows them to access services on the host's localhost
          networks = if (containerUser != null)
                     then [ "slirp4netns:allow_host_loopback=true" ]
                     else [ "podman" ];

          # Health check configuration via podman args
          # NOTE: Disabled by default - quadlet-nix doesn't fully support health checks yet
          podmanArgs = lib.optionals (healthCheck.enable && healthCheckCmd != null) [
            "--health-cmd"
            healthCheckCmd
            "--health-interval"
            healthCheck.interval
            "--health-timeout"
            healthCheck.timeout
            "--health-start-period"
            healthCheck.startPeriod
            "--health-retries"
            (toString healthCheck.retries)
            # Note: --sdnotify removed because containers don't support sd_notify protocol
            # Health checks still work and status is visible in 'podman ps' output
          ];

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
          # - Containers then can't resolve hera.lan, etc.
          #
          # SYMPTOMS WHEN BROKEN:
          # - "socket.gaierror: [Errno -3] Temporary failure in name resolution"
          # - "ClientConnectorDNSError: Cannot connect to host *.lan"
          # - litellm can't load models from hera.lan
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
          # Rootless containers use localhost, root containers use podman gateway
          ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h ${if containerUser != null then "127.0.0.1" else common.postgresDefaults.host} -p ${toString common.postgresDefaults.port} -t 30";
        })
        # Add restart behavior to [Service] section
        common.restartPolicies.always.service
        # Watchdog disabled - requires --sdnotify which containers don't support
        # (lib.optionalAttrs (watchdogSec != null) {
        #   WatchdogSec = watchdogSec;
        #   NotifyAccess = "all";
        # })
        # Rootless operation: run container as specific user when containerUser is set
        (lib.optionalAttrs (containerUser != null) {
          User = containerUser;
          Group = containerUser;
          # Ensure rootless podman can find slirp4netns and other system binaries
          Environment = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
        })
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
    # When containerUser is set, secrets are deployed to /run/secrets-<user>/ with user ownership
    # When containerUser is null, secrets use default /run/secrets/ path with root ownership
    sops.secrets = lib.mkMerge [
      (lib.mapAttrs' (secretName: sopsKey:
        lib.nameValuePair sopsKey ({
          sopsFile = common.secretsPath;
          owner = if containerUser != null then containerUser else "root";
          group = if containerUser != null then containerUser else "root";
          mode = "0400";
          restartUnits = lib.optional secretsRestartUnits "${name}.service";
        } // lib.optionalAttrs (containerUser != null) {
          # Deploy to user-specific directory for rootless containers
          path = "/run/secrets-${containerUser}/${sopsKey}";
        })
      ) secrets)
    ];

    # Nginx virtual host (optional)
    services.nginx.virtualHosts = lib.mkIf (nginxVirtualHost != null && nginxVirtualHost.enable) {
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
      [ "d /var/lib/${name} 0755 root root -" ]
      ++ tmpfilesRules;
  };
}
