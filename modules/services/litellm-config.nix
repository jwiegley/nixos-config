# LiteLLM proxy config — native-Nix source of truth.
#
# The full proxy configuration (model_list, credential_list, routing, etc.)
# lives as a native Nix expression in ./litellm-settings.nix. This module:
#
#   1. Declares the SOPS secrets litellm/<name> that back each provider API key.
#   2. Serializes litellm-settings.nix with the secret placeholders embedded and
#      hands that to sops-nix, which substitutes the decrypted values at
#      activation and writes the result to /etc/litellm/config.yaml (owner
#      litellm, mode 0400 — a symlink into the SOPS runtime store).
#   3. Asserts at evaluation time that every model referenced in models.nix is
#      actually offered by this LiteLLM config (present as a model_name).
#
# Serialization format: we emit JSON (builtins.toJSON), not block YAML. JSON is
# a strict subset of YAML, so LiteLLM's YAML loader parses config.yaml
# unchanged. This is deliberate: the only pure-eval alternative that produces
# block YAML is pkgs.formats.yaml.generate, which forces import-from-derivation
# (readFile of a build output) during evaluation. We keep this module IFD-free —
# matching the same choice made three files over in model-config.nix — at the
# cost of the on-disk file being JSON-shaped rather than block YAML.
#
# Editing the config: edit ./litellm-settings.nix directly (it is plain Nix).
# Adding/removing a provider key: add `mkSecret "<name>"` at the value site and
# a matching `litellm/<name>` entry in the SOPS file, then extend `secretNames`
# below. Rebuild to deploy. A `nixos-rebuild switch` that changes the rendered
# config (or rotates a backing key) auto-restarts the rootless `litellm`
# container via the litellm-restart bridge service below — no manual restart.
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
    "factory-api-key"
  ];

  # Native-Nix config, with each secret site resolved to a sops-nix placeholder
  # token (a unique, non-secret marker substituted for the real value at
  # activation).
  settings = import ./litellm-settings.nix {
    mkSecret = name: config.sops.placeholder."litellm/${name}";
  };

  # Serialize to JSON (valid YAML; see header). The placeholder tokens survive
  # string-encoding verbatim; sops-nix replaces them with the decrypted secrets
  # when it materialises the template. No IFD.
  rendered = builtins.toJSON settings;

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
  # restartUnits fires only when the rendered content actually changes (config
  # edit or key rotation), and points at the litellm-restart bridge below —
  # sops-nix runs in the system manager and cannot restart the rootless *user*
  # container directly, so it restarts a system oneshot that can.
  sops.templates."litellm-config.yaml" = {
    content = rendered;
    path = "/etc/litellm/config.yaml";
    owner = "litellm";
    group = "litellm";
    mode = "0400";
    restartUnits = [ "litellm-restart.service" ];
  };

  # Bridge: restart the rootless `litellm` user container from the system
  # manager. Triggered by sops-nix (restartUnits above) whenever the rendered
  # config or a backing secret changes, so a `nixos-rebuild switch` takes effect
  # without a manual restart. `restart` on an inactive/not-yet-started unit is a
  # no-op-then-start, so this is safe at boot too (it orders after the user
  # manager and machined are up).
  systemd.services.litellm-restart = {
    description = "Restart the rootless litellm container after a config/secret change";
    # machined is needed for the `-M litellm@` cross-manager call. We do NOT
    # order after the litellm user manager: restartUnits fires during switch
    # activation (user manager already up), and at boot the container starts on
    # its own via lingering, so a failed restart here is a tolerated no-op.
    after = [ "systemd-machined.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl --user -M litellm@ restart litellm.service";
      # A restart failure (e.g. user manager briefly unavailable) must not fail
      # the activation; the container's own Restart=always will recover it.
      SuccessExitStatus = "0 1";
    };
  };
}
