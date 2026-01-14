{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.open-webui =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # Import the quadlet-nix Home Manager module
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];
      # Home Manager state version
      home.stateVersion = "24.11";

      # Basic home settings
      home.username = "open-webui";
      home.homeDirectory = "/var/lib/containers/open-webui";

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
        postgresql # For pg_isready health check
      ];

      # Rootless quadlet container configuration
      virtualisation.quadlet.containers.open-webui = {
        autoStart = true;

        containerConfig = {
          image = "ghcr.io/open-webui/open-webui:main";
          # With host network mode, no port mapping needed - app listens on 8080 directly
          # publishPorts is not used with host networking

          # Use host network mode to access host services directly
          networks = [ "host" ];

          # Environment configuration
          # Note: DATABASE_URL with password is in the secrets file
          environments = {
            # Port configuration (8080 is used by llama-swap)
            PORT = "8084";

            # OpenAI-compatible API configuration - point to LiteLLM
            OPENAI_API_BASE_URL = "http://127.0.0.1:4000/v1";

            # Disable default Ollama integration (we're using LiteLLM)
            OLLAMA_BASE_URL = "";

            # WebUI configuration
            WEBUI_NAME = "Vulcan AI";
            WEBUI_URL = "https://chat.vulcan.lan";

            # Data directory inside container
            DATA_DIR = "/app/backend/data";

            # Enable signup for initial admin account creation
            # Can be disabled from Admin Panel after first user is created
            ENABLE_SIGNUP = "true";

            # Enable community sharing
            ENABLE_COMMUNITY_SHARING = "false";

            # Disable update checks (we manage via container updates)
            ENABLE_UPDATE_CHECK = "false";

            # Safe mode - disable code execution in chat
            SAFE_MODE = "true";

            # Default model (adjust as needed based on LiteLLM config)
            DEFAULT_MODELS = "gpt-4o";
          };

          # Secrets via environment file
          environmentFiles = [ "/run/secrets-open-webui/open-webui-secrets" ];

          # Volume mounts for persistent data
          volumes = [
            "/var/lib/containers/open-webui/data:/app/backend/data:rw"
          ];

          # Health check
          healthCmd = "CMD-SHELL curl -f http://localhost:8084/health || exit 1";
          healthInterval = "30s";
          healthTimeout = "10s";
          healthStartPeriod = "60s";
          healthRetries = 3;
        };

        unitConfig = {
          After = [ "network-online.target" ];

          # Restart rate limiting
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          # Wait for PostgreSQL to be ready
          ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 60";

          # Restart policies
          Restart = "always";
          RestartSec = "15s";
          TimeoutStartSec = "300";
        };
      };
    };
}
