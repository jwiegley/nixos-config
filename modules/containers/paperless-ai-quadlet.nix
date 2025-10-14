{ config, lib, pkgs, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
  inherit (mkQuadletLib) mkQuadletService;

  # Environment file for paperless-ai configuration (non-sensitive)
  paperlessAiEnvFile = pkgs.writeText "paperless-ai.env" ''
    # Paperless-ngx API Configuration (use podman gateway to reach host)
    PAPERLESS_API_URL=http://10.88.0.1:28981/api

    # AI Provider Configuration (using LiteLLM)
    AI_PROVIDER=custom
    CUSTOM_BASE_URL=https://litellm.vulcan.lan/v1
    CUSTOM_MODEL=athena/gpt-oss-20b

    # Scanning Configuration
    SCAN_INTERVAL=*/30 * * * *
    PROCESS_PREDEFINED_DOCUMENTS=no  # Process all documents, not just tagged ones
    # TAGS=pre-process  # Disabled - process all documents without tag filtering

    # AI Processing Tags - disabled to avoid cluttering documents
    ADD_AI_PROCESSED_TAG=no
    # AI_PROCESSED_TAG_NAME=ai-processed

    # Use existing document data for context
    USE_EXISTING_DATA=yes

    # System Prompt for Document Analysis
    SYSTEM_PROMPT=Analyze this document and provide: 1) A clear, descriptive title 2) Relevant tags for categorization 3) Document type (invoice, receipt, letter, contract, etc.) 4) Correspondent/sender if identifiable. Be concise and accurate.
  '';

  # Secrets environment file - generated at runtime from SOPS secrets
  paperlessAiSecretsEnvPath = "/var/lib/paperless-ai/secrets.env";
in
{
  # Create systemd service to generate secrets env file
  systemd.services.paperless-ai-secrets = {
    description = "Generate paperless-ai secrets environment file";
    before = [ "paperless-ai.service" ];
    wantedBy = [ "paperless-ai.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /var/lib/paperless-ai
      cat > ${paperlessAiSecretsEnvPath} <<EOF
      CUSTOM_API_KEY=$(cat ${config.sops.secrets."litellm-vulcan-lan".path})
      PAPERLESS_API_TOKEN=$(cat ${config.sops.secrets."paperless-ai/paperless-api-token".path})
      EOF
      chmod 600 ${paperlessAiSecretsEnvPath}
    '';
  };

  imports = [
    (mkQuadletService {
      name = "paperless-ai";
      image = "docker.io/clusterzx/paperless-ai:latest";
      port = 3001;

      # Bind to localhost only (nginx reverse proxy provides access)
      publishPorts = [
        "127.0.0.1:3001:3000/tcp"  # Map host 3001 to container 3000 (Grafana uses 3000)
      ];

      secrets = {};  # All secrets handled via paperless-ai-secrets.service

      # Load both non-sensitive config and runtime-generated secrets
      environmentFiles = [ "${paperlessAiEnvFile}" paperlessAiSecretsEnvPath ];

      # Additional environments (merged with those from environmentFiles)
      environments = {
        # Tell Node.js to use system CA certificates (includes our mounted cert)
        NODE_EXTRA_CA_CERTS = "/usr/local/share/ca-certificates/vulcan-ca.crt";
      };

      # Persistent volume for paperless-ai data
      volumes = [
        "paperless-ai-data:/app/data"
        # Mount Vulcan CA root cert so container trusts internal HTTPS services
        "/var/lib/step-ca/certs/root_ca.crt:/usr/local/share/ca-certificates/vulcan-ca.crt:ro"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:3001/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 20M;
          proxy_read_timeout 5m;
          proxy_connect_timeout 60s;
          proxy_send_timeout 60s;
        '';
      };
    })
  ];

  # SOPS secrets for paperless-ai configuration
  sops.secrets."paperless-ai/paperless-api-token" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    mode = "0400";
    restartUnits = [ "paperless-ai.service" ];
  };

  # Reference to existing litellm-vulcan-lan secret is already handled by mkQuadletService
}
