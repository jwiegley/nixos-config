{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  models = import ../../../models.nix;
  # Vane runs multi-step search-and-synthesis, so it uses the reasoning tier
  # (DeepSeek, 1M context) rather than the general `primary` model. Moved off
  # primary 2026-08-02 -- primary is shared with stock-trader and Open WebUI,
  # which stay on Qwen.
  defaultModel = models.llm.reasoning.name;
  # :4001, the Vane LLM shim -- NOT :4000, the gateway itself. Load bearing, not a
  # preference.
  #
  # DeepSeek emits its chain of thought as ordinary content (no <think> tags, no
  # reasoning_content field). Perplexica asks the model to rephrase the question into
  # a standalone search query, receives "1. The user asks to rephrase ... 2. The
  # instruction says ..." instead, cannot parse a query out of it, and then NEVER
  # CALLS SEARXNG AT ALL -- confirmed 2026-08-03 by uwsgi logging 16 lines for a
  # hand-issued searxng query and ZERO for a Vane query in the same window. The
  # symptom is Vane replying "I could not find any relevant information" with 0
  # sources, which reads as an outage rather than a parsing failure.
  #
  # The shim injects chat_template_kwargs.enable_thinking=false, which suppresses it
  # (verified A/B: through :4001 the same prompt returns "NixOS definition"; through
  # :4000 it returns the monologue). It cannot be set here instead -- Perplexica's
  # openai provider config accepts only name/apiKey/baseURL -- and must not be done
  # globally at :4000, because Hermes shares that gateway and WANTS thinking.
  # See modules/services/vane-llm-shim.nix.
  #
  # The shim forwards to :4000, so the gateway still owns auth and TLS and the
  # sentinel apiKey below is unchanged.
  gatewayBaseUrl = "http://127.0.0.1:4001/v1";

  # SENTINEL, not a credential. Vane posts this as the provider apiKey, but the
  # host LLM gateway on :4000 injects the real upstream Authorization header and
  # discards whatever the client sent (modules/services/hera-llm-proxy.nix).
  # Perplexica's openai provider requires a non-empty apiKey, so it gets a fixed
  # placeholder. This replaced a SOPS secret whose value was already inert for
  # the same reason, removing this module's dependency on a stale secret name.
  # NOTE: this string is part of the provider config that gets SHA-256'd into
  # `.hash` below, so changing it re-hashes the provider (handled automatically).
  gatewayApiKey = "gateway-injects-real-key";
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
      --arg api_key '${gatewayApiKey}' \
      --arg model '${defaultModel}' \
      --arg base_url '${gatewayBaseUrl}' \
      --arg provider_id "$provider_id" '
      ($api_key | sub("[\\r\\n]+$"; "")) as $key |
      if $key == "" then
        error("gateway API key sentinel is empty")
      else
        .modelProviders = (
          (.modelProviders // []) |
          # MIGRATION: drop the legacy "LiteLLM" provider. The name below is
          # the identity this script matches on, so without this a rename
          # would append a second provider and leave the stale one (with its
          # dead baseURL) visible in the vane UI forever.
          map(select((.name == "LiteLLM" and .type == "openai") | not)) |
          # MIGRATION 2026-08-03: drop the legacy "Hera (oMLX)" provider, for the
          # same reason as LiteLLM above. This script only ever matched
          # .name == "Hera", so a provider created under the older label was never
          # updated -- it sat there with a stale baseURL while the script appended
          # a SECOND, correct "Hera" beside it. Not cosmetic: both vane-mcp.py and
          # Vane take the FIRST provider that has chatModels, and "Hera (oMLX)"
          # sorted first, so every request went to the stale endpoint. Exposed
          # while pointing Vane at the :4001 no-thinking shim -- config.json kept
          # reporting baseURL :4000 after a SUCCESSFUL reconcile.
          map(select((.name == "Hera (oMLX)" and .type == "openai") | not)) |
          if any(.[]; .name == "Hera" and .type == "openai") then
            map(
              if .name == "Hera" and .type == "openai" then
                .config.apiKey = $key |
                .config.baseURL = $base_url |
                .chatModels = [{"name": $model, "key": $model}]
              else . end
            )
          else
            . + [{
              id: $provider_id,
              name: "Hera",
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
    # gateway endpoint changes; chatModels are deliberately not part of it.
    hash="$(${pkgs.jq}/bin/jq -cS '
      [.modelProviders[] | select(.name == "Hera" and .type == "openai")][0].config
    ' "$updated" | ${pkgs.coreutils}/bin/tr -d '\n' | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
    ${pkgs.jq}/bin/jq --arg hash "$hash" '
      .modelProviders |= map(
        if .name == "Hera" and .type == "openai" then
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
