{ config, lib, pkgs, inputs, ... }:

{
  home-manager.users.letta = { config, lib, pkgs, ... }: {
    # Import the quadlet-nix Home Manager module
    imports = [
      inputs.quadlet-nix.homeManagerModules.quadlet
    ];

    # Home Manager state version
    home.stateVersion = "24.11";

    # Basic home settings
    home.username = "letta";
    home.homeDirectory = "/var/lib/containers/letta";

    # Environment for rootless container operation
    home.sessionVariables = {
      PODMAN_USERNS = "keep-id";
    };

    # Ensure home directory structure exists
    home.file.".keep".text = "";

    # Basic packages available in container user environment
    home.packages = with pkgs; [
      podman
      coreutils
      postgresql  # For pg_isready health check
    ];

    # Rootless quadlet container configuration
    virtualisation.quadlet.containers.letta = {
      autoStart = true;

      containerConfig = {
        image = "docker.io/letta/letta:latest";
        publishPorts = [ "127.0.0.1:8283:8283/tcp" ];

        # Rootless networking with host loopback access
        networks = [ "slirp4netns:allow_host_loopback=true" ];

        # Environment configuration for external PostgreSQL and Redis
        # Using host.containers.internal to access host services from rootless container
        environments = {
          # Disable internal PostgreSQL and Redis - use external services
          LETTA_USE_EXTERNAL_POSTGRES = "true";
          LETTA_USE_EXTERNAL_REDIS = "true";

          # Redis connection (external instance on host)
          REDIS_URL = "redis://host.containers.internal:6384";

          # LiteLLM proxy as OpenAI-compatible backend
          # This allows using models like "hera/gpt-oss-120b" via the openai provider
          OPENAI_API_BASE = "http://host.containers.internal:4000";
        };

        # Secrets via environment file (contains LETTA_PG_URI, OPENAI_API_KEY, etc.)
        # LETTA_PG_URI format: postgresql://letta:<password>@host.containers.internal:5432/letta
        environmentFiles = [ "/run/secrets-letta/letta-secrets" ];

        # Volume mounts for persistent data
        volumes = [
          "/var/lib/letta:/root/.letta:rw"
        ];
      };

      unitConfig = {
        After = [ "network-online.target" ];

        # Restart rate limiting
        StartLimitIntervalSec = "300";
        StartLimitBurst = "5";
      };

      serviceConfig = {
        # Wait for PostgreSQL and Redis to be ready
        ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 30";

        # Restart policies
        Restart = "always";
        RestartSec = "10s";
        TimeoutStartSec = "900";
      };
    };
  };
}
