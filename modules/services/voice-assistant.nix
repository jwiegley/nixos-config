# Voice Assistant - Wyoming STT bridge to LiteLLM
#
# wyoming-openai (roryeckel) exposes a Wyoming STT server that forwards
# complete utterances to an OpenAI-compatible /v1/audio/transcriptions
# endpoint. We point it at the local LiteLLM proxy (127.0.0.1:4000) and
# select the cohere-transcribe alias (defined in /etc/litellm/config.yaml,
# which routes to hera).
#
# Setup checklist (one-time, outside this module):
#   1. Add a SOPS secret "wyoming-openai-env" to /etc/nixos/secrets/secrets.yaml
#      as a multi-line env file with a single STT_OPENAI_KEY=... line.
#      The key is a LiteLLM virtual key with permission to call the
#      cohere-transcribe model. Generate one in the LiteLLM admin UI at
#      https://litellm.vulcan.lan.
#   2. Verify /etc/litellm/config.yaml has a model_list entry whose
#      model_name is "cohere-transcribe" and whose api_base routes to
#      hera. Restart litellm if you add a new alias.
#   3. After this module is built and switched, in HA UI:
#      Settings -> Devices & Services -> Add Integration -> "Wyoming Protocol"
#      Host: 127.0.0.1   Port: 10300
#      Then Settings -> Voice Assistants -> create a pipeline using the
#      discovered Wyoming STT, your existing TTS engine, and a
#      conversation agent.

{
  config,
  lib,
  pkgs,
  ...
}:

{
  # SOPS-deployed env file. Contents (managed via `sops /etc/nixos/secrets/secrets.yaml`):
  #   wyoming-openai-env: |
  #     STT_OPENAI_KEY=<litellm-virtual-key>
  sops.secrets."wyoming-openai-env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "root";
    path = "/run/secrets/wyoming-openai-env";
    restartUnits = [ "wyoming-openai.service" ];
  };

  virtualisation.quadlet.containers.wyoming-openai = {
    autoStart = true;

    containerConfig = {
      # `latest` tracks the latest stable release per the upstream README.
      # Pin to a tag (e.g. "0.4.3") if you want reproducible image pulls.
      image = "ghcr.io/roryeckel/wyoming_openai:latest";

      # Host network so the container can reach LiteLLM on 127.0.0.1:4000
      # and the Wyoming server can listen on 127.0.0.1:10300 directly.
      # Same pattern as matter-server-quadlet.nix and open-webui.nix.
      networks = [ "host" ];

      environments = {
        # Bind Wyoming STT on host loopback only. HA on the same host
        # connects via 127.0.0.1; remote satellites reach this through HA.
        WYOMING_URI = "tcp://127.0.0.1:10300";
        WYOMING_LANGUAGES = "en";
        WYOMING_LOG_LEVEL = "INFO";

        # Talk to local LiteLLM. STT_MODELS must match a model name visible
        # to the virtual key (verify with `/v1/models`). If you add an alias
        # like `cohere-transcribe` to /etc/litellm/config.yaml's model_list,
        # update this to match.
        STT_OPENAI_URL = "http://127.0.0.1:4000/v1";
        STT_MODELS = "hera/cohere-transcribe-03-2026";
      };

      # STT_OPENAI_KEY=<litellm-virtual-key> comes from SOPS.
      environmentFiles = [ "/run/secrets/wyoming-openai-env" ];

      # Python installs a SIGINT handler even as container PID 1; the quadlet
      # default SIGTERM was ignored, so every stop rode the 10s timeout into
      # SIGKILL/exit 137 and logged a spurious unit failure (2026-07-03 audit).
      stopSignal = "SIGINT";
    };

    unitConfig = {
      Description = "wyoming-openai - Wyoming STT bridge to LiteLLM";
      After = [
        "network-online.target"
        "podman.service"
      ];
      Wants = [
        "network-online.target"
        "podman.service"
      ];
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "15s";
      # Generous start timeout to allow first-time image pulls (multi-blob,
      # ~40MB total). Subsequent restarts use the cached image and are fast.
      TimeoutStartSec = "600";
      # Container exit on SIGTERM is success (matches matter-server pattern)
      SuccessExitStatus = "143";
    };
  };

  # Loopback-only listener; no firewall rule required.
  # HA reaches it via 127.0.0.1:10300 on the same host.
}
