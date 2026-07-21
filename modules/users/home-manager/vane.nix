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
  litellmBaseUrl = "http://127.0.0.1:4000/v1";
  syncVaneModel = pkgs.writeShellScript "sync-vane-model" ''
    set -euo pipefail
    config=/var/lib/vane/data/config.json
    input="$(${pkgs.coreutils}/bin/mktemp "$config.input.XXXXXX")"
    updated="$(${pkgs.coreutils}/bin/mktemp "$config.updated.XXXXXX")"
    hashed="$(${pkgs.coreutils}/bin/mktemp "$config.hashed.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$input" "$updated" "$hashed"' EXIT

    if [[ -e "$config" ]]; then
      had_config=1
      ${pkgs.coreutils}/bin/cp --preserve=mode "$config" "$input"
    else
      had_config=0
      ${pkgs.jq}/bin/jq -n '{
        version: 1,
        setupComplete: true,
        preferences: {},
        personalization: {},
        modelProviders: [],
        search: {searxngURL: "http://127.0.0.1:8890"}
      }' >"$input"
    fi

    provider_id="$(${pkgs.util-linux}/bin/uuidgen)"
    ${pkgs.jq}/bin/jq -e \
      --rawfile api_key '${config.sops.secrets."litellm-vulcan-lan-vane".path}' \
      --arg model '${defaultModel}' \
      --arg base_url '${litellmBaseUrl}' \
      --arg provider_id "$provider_id" '
      ($api_key | sub("[\\r\\n]+$"; "")) as $key |
      if $key == "" then
        error("LiteLLM API key is empty")
      else
        .modelProviders = (
          (.modelProviders // []) |
          if any(.[]; .name == "LiteLLM" and .type == "openai") then
            map(
              if .name == "LiteLLM" and .type == "openai" then
                .config.apiKey = $key |
                .config.baseURL = $base_url |
                .chatModels = [{"name": $model, "key": $model}]
              else . end
            )
          else
            . + [{
              id: $provider_id,
              name: "LiteLLM",
              type: "openai",
              chatModels: [{"name": $model, "key": $model}],
              embeddingModels: [],
              config: {apiKey: $key, baseURL: $base_url},
              hash: ""
            }]
          end
        )
      end
    ' "$input" >"$updated"

    # Vane identifies duplicate providers by the SHA-256 of the compact,
    # key-sorted provider config.  Keep that derived field coherent when the
    # LiteLLM endpoint changes; chatModels are deliberately not part of it.
    hash="$(${pkgs.jq}/bin/jq -cS '
      [.modelProviders[] | select(.name == "LiteLLM" and .type == "openai")][0].config
    ' "$updated" | ${pkgs.coreutils}/bin/tr -d '\n' | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
    ${pkgs.jq}/bin/jq --arg hash "$hash" '
      .modelProviders |= map(
        if .name == "LiteLLM" and .type == "openai" then
          .hash = $hash
        else . end
      )
    ' "$updated" >"$hashed"
    if [[ "$had_config" == 1 ]]; then
      ${pkgs.coreutils}/bin/chmod --reference="$config" "$hashed"
    else
      ${pkgs.coreutils}/bin/chmod 0600 "$hashed"
    fi
    ${pkgs.coreutils}/bin/mv "$hashed" "$config"
    trap - EXIT
  '';
in
{
  sops.secrets."litellm-vulcan-lan-vane" = {
    key = "litellm-vulcan-lan";
    owner = "vane";
    mode = "0400";
  };

  home-manager.users.vane =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      home.stateVersion = "24.11";
      home.username = "vane";
      home.homeDirectory = "/var/lib/containers/vane";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      # Rootless quadlet container using host networking for SearXNG access
      virtualisation.quadlet.containers.vane = {
        autoStart = true;

        containerConfig = {
          # Use slim image (no bundled SearXNG — we use the existing instance)
          image = "itzcrazykns1337/vane:slim-latest";

          # Host networking allows direct access to host's localhost services
          # (SearXNG at 127.0.0.1:8890, etc.)
          networks = [ "host" ];

          environments = {
            # Bind to localhost only (host network mode)
            HOSTNAME = "127.0.0.1";
            PORT = "3007";

            # Point to the existing SearXNG instance
            SEARXNG_API_URL = "http://127.0.0.1:8890";

            # Data directory inside container (maps to our volume)
            DATA_DIR = "/home/vane";

            # Trust local Step-CA for outbound HTTPS verification
            NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/vulcan-ca.crt";
          };

          # Persistent data volumes
          volumes = [
            "/var/lib/vane/data:/home/vane/data:rw"
            "/var/lib/vane/uploads:/home/vane/uploads:rw"
            # Mount Step-CA root certificate for HTTPS connections to local services
            "/etc/ssl/certs/vulcan-ca.crt:/etc/ssl/certs/vulcan-ca.crt:ro"
          ];
        };

        unitConfig = {
          After = [
            "network-online.target"
            "sops-nix.service"
          ];
          Wants = [ "sops-nix.service" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          ExecStartPre = syncVaneModel;
          Restart = "always";
          RestartSec = "15s";
          TimeoutStartSec = "300";
        };
      };
    };
}
