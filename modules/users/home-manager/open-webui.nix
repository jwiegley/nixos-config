{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  models = import ../../../models.nix;
  defaultModel = models.llm.primary.name;
in
{
  systemd.services.open-webui-model-defaults = {
    description = "Reconcile OpenWebUI model defaults";
    wantedBy = [ "multi-user.target" ];
    after = [
      "postgresql.service"
      "postgresql-setup.service"
    ];
    requires = [
      "postgresql.service"
      "postgresql-setup.service"
    ];
    restartTriggers = [ (builtins.toJSON { inherit defaultModel; }) ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      if ! schema_columns="$(${pkgs.util-linux}/bin/runuser -u postgres -- \
        ${pkgs.postgresql}/bin/psql -Atq -d open_webui -c \
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'config' AND column_name IN ('key', 'value', 'updated_at')" \
        2>/dev/null)"; then
        echo "OpenWebUI database is not ready; environment defaults will seed it"
        exit 0
      fi

      if [[ "$schema_columns" != 3 ]]; then
        echo "OpenWebUI per-key config schema is not ready; deferring reconciliation"
        exit 0
      fi

      changed="$(${pkgs.util-linux}/bin/runuser -u postgres -- \
        ${pkgs.postgresql}/bin/psql -Atq -v ON_ERROR_STOP=1 -d open_webui <<'SQL'
      WITH desired(key, value) AS (
        VALUES
          ('ui.default_models', '${defaultModel}'),
          ('ui.default_pinned_models', '${defaultModel}'),
          ('task.model.default', '${defaultModel}'),
          ('task.model.external', '${defaultModel}')
      ), changed AS (
        INSERT INTO config (key, value, updated_at)
        SELECT key, to_json(value), extract(epoch FROM now())::bigint
        FROM desired
        ON CONFLICT (key) DO UPDATE SET
          value = EXCLUDED.value,
          updated_at = EXCLUDED.updated_at
        WHERE config.value::jsonb IS DISTINCT FROM EXCLUDED.value::jsonb
        RETURNING 1
      )
      SELECT count(*) FROM changed;
      SQL
      )"

      if [[ "$changed" != 0 ]]; then
        uid="$(${pkgs.coreutils}/bin/id -u open-webui)"
        runtime_dir="/run/user/$uid"
        if [[ -S "$runtime_dir/bus" ]]; then
          ${pkgs.util-linux}/bin/runuser -u open-webui -- \
            ${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR="$runtime_dir" \
            ${pkgs.systemd}/bin/systemctl --user try-restart open-webui.service
        fi
      fi
    '';
  };

  systemd.timers.open-webui-model-defaults = {
    description = "Retry OpenWebUI model-default reconciliation after migrations";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };

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
          # With host network mode, no port mapping needed - app listens on 8084 directly
          # (PORT=8084 below; 8080 is open-webui's default but belongs to llama-swap here)
          # publishPorts is not used with host networking

          # Use host network mode to access host services directly
          networks = [ "host" ];

          # Environment configuration
          # Note: DATABASE_URL with password is in the secrets file
          environments = {
            # Port configuration (8080 is used by llama-swap)
            PORT = "8084";

            # OpenAI-compatible API configuration - point to the host LLM gateway
            # TWO OpenAI-compatible backends, semicolon-joined. Open WebUI matches this
            # list positionally against OPENAI_API_KEYS, which is supplied by the
            # environmentFile below (it holds Hermes' key, so it cannot live here).
            # IF YOU REORDER THIS LIST, REORDER THAT ONE TOO.
            #
            #   1. the host LLM gateway -> hera's llama-swap. The raw model. nginx
            #      injects the upstream key, so the client-side key is a placeholder.
            #   2. the Hermes AGENT (Discord-connected, with mail/calendar/Postgres/HA
            #      tools) -- a different thing from the model above. It lives inside the
            #      microVM; `hermes-vm` is an /etc/hosts name published by
            #      modules/services/hermes-microvm.nix so its bridge address is not
            #      restated here. The port must match apiServerPort in that same file.
            #
            # NOTE 8080 below is the guest's port. Do NOT change it to 127.0.0.1:8080 --
            # that is vulcan's OWN local llama-swap, an entirely different service (and
            # the reason this container runs on PORT 8084).
            OPENAI_API_BASE_URLS = "http://127.0.0.1:4000/v1;http://hermes-vm:8080/v1";

            # Disable default Ollama integration (we use the LLM gateway on :4000)
            OLLAMA_BASE_URL = "";

            # WebUI configuration
            WEBUI_NAME = "Vulcan AI";
            WEBUI_URL = "https://chat.vulcan.lan";

            # Data directory inside container
            DATA_DIR = "/app/backend/data";

            # Enable signup for initial admin account creation
            # Can be disabled from Admin Panel after first user is created
            ENABLE_SIGNUP = "true";

            # Disable community sharing
            ENABLE_COMMUNITY_SHARING = "false";

            # Disable update checks (we manage via container updates)
            ENABLE_UPDATE_CHECK = "false";

            # Safe mode - disable code execution in chat
            SAFE_MODE = "true";

            # Default model (must be a real id served by the gateway; see models.nix)
            DEFAULT_MODELS = defaultModel;
            DEFAULT_PINNED_MODELS = defaultModel;
            TASK_MODEL = defaultModel;
            TASK_MODEL_EXTERNAL = defaultModel;
          };

          # Secrets via environment file
          # Second file carries OPENAI_API_KEYS, built at activation by
          # open-webui-compose-keys (modules/containers/open-webui-quadlet.nix)
          # so Hermes' key never enters the Nix store.
          environmentFiles = [
            "/run/secrets-open-webui/open-webui-secrets"
            "/run/secrets-open-webui/hermes-openai-keys"
          ];

          # Volume mounts for persistent data
          volumes = [
            "/var/lib/containers/open-webui/data:/app/backend/data:rw"
          ];

          # Health check disabled to prevent systemd-logind session spam
          # Each 30s health check creates a session = 3 log lines = ~12,960 lines/day
          # External monitoring (Nagios) handles health checks instead
          # healthCmd = "CMD-SHELL curl -f http://localhost:8084/health || exit 1";
          # healthInterval = "30s";
          # healthTimeout = "10s";
          # healthStartPeriod = "60s";
          # healthRetries = 3;
        };

        unitConfig = {
          After = [ "network-online.target" ];

          # Restart rate limiting
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          ExecStartPre = [
            # Wait for PostgreSQL to be ready
            "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do ${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 2 && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; exit 1'"
            # Wait for open-webui-compose-keys to write the OPENAI_API_KEYS file that
            # environmentFiles references. That is a SYSTEM unit, so this rootless
            # user unit cannot order itself After= it; polling is the available
            # mechanism, and matches the pg_isready wait above.
            "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do [ -r /run/secrets-open-webui/hermes-openai-keys ] && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; echo \"hermes keys file never appeared\" >&2; exit 1'"
          ];

          # Restart policies
          Restart = "always";
          RestartSec = "15s";
          TimeoutStartSec = "300";
        };
      };
    };
}
