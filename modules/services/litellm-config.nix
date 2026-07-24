# LiteLLM proxy config — native-Nix source of truth.
#
# The full proxy configuration (model_list, credential_list, routing, etc.)
# lives as a native Nix expression in ./litellm-settings.nix. This module:
#
#   1. Declares the SOPS secrets litellm/<name> that back each provider API key.
#   2. Renders litellm-settings.nix to real YAML (pkgs.formats.yaml) with the
#      secret placeholders embedded, then hands that to sops-nix, which
#      substitutes the decrypted values at activation and writes the result to
#      /etc/litellm/config.yaml (owner litellm, mode 0400 — a symlink into the
#      SOPS runtime store).
#   3. Asserts at evaluation time that every model referenced in models.nix is
#      actually offered by this LiteLLM config (present as a model_name).
#
# Editing the config: edit ./litellm-settings.nix directly (it is plain Nix).
# Adding/removing a provider key: add `mkSecret "<name>"` at the value site and
# a matching `litellm/<name>` entry in the SOPS file, then extend `secretNames`
# below. Rebuild to deploy. The rootless `litellm` container is NOT auto-
# restarted by sops-nix (cross-manager); after a switch that changes the config,
# restart it with:
#   systemctl --user -M litellm@ restart litellm
{
  config,
  lib,
  pkgs,
  ...
}:

let
  models = import ../../models.nix;

  # Provider API keys backed by SOPS. Each maps a config point
  # (`mkSecret "anthropic-api-key"`) to the SOPS key `litellm/anthropic-api-key`.
  secretNames = [
    "anthropic-api-key"
    "gemini-api-key"
    "openai-api-key"
    "perplexityai-api-key"
    "groq-api-key"
    "openrouter-api-key"
    "positron_anthropic-api-key"
    "positron_gemini-api-key"
    "positron_openai-api-key"
    "positron-api-key"
    "omlx-api-key"
  ];

  # Native-Nix config, with each secret site resolved to a sops-nix placeholder
  # token (a unique, non-secret marker substituted for the real value at
  # activation).
  settings = import ./litellm-settings.nix {
    mkSecret = name: config.sops.placeholder."litellm/${name}";
  };

  # Render to real YAML. The placeholder tokens survive verbatim; sops-nix
  # replaces them with the decrypted secrets when it materialises the template.
  yamlFile = (pkgs.formats.yaml { }).generate "litellm-config.yaml" settings;

  # ── Eval-time model-coverage check ──────────────────────────────────────
  # Every model name selected in models.nix must be offered by this proxy
  # (i.e. appear as a model_name in model_list), or callers get 400s at runtime.
  offeredModels = map (m: m.model_name) settings.model_list;
  referencedModels = lib.unique (
    [
      models.llm.primary.name
      models.llm.fast.name
      models.llm.agent.name
      models.embedding.primary.name
    ]
    ++ map (f: f.name) models.llm.fallbacks
    ++ map (f: f.name) models.embedding.fallbacks
  );
  missingModels = lib.subtractLists offeredModels referencedModels;
in
{
  assertions = [
    {
      assertion = missingModels == [ ];
      message =
        "litellm-config: models referenced in models.nix are not offered by the "
        + "LiteLLM config (missing model_name in litellm-settings.nix model_list): "
        + lib.concatStringsSep ", " missingModels;
    }
  ];

  # One SOPS secret per provider key. The operator populates these with:
  #   sops secrets/secrets.yaml   (nested `litellm:` map)
  sops.secrets = lib.genAttrs (map (n: "litellm/${n}") secretNames) (_: {
    sopsFile = config.sops.defaultSopsFile;
    owner = "litellm";
    mode = "0400";
  });

  # Render config.yaml at activation with the real secrets substituted in.
  # No restartUnits: the litellm container is a rootless *user* unit that the
  # system-manager sops-nix cannot restart cross-manager (see module header).
  sops.templates."litellm-config.yaml" = {
    content = builtins.readFile yamlFile;
    path = "/etc/litellm/config.yaml";
    owner = "litellm";
    group = "litellm";
    mode = "0400";
  };
}
