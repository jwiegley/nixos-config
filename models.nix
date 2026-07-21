# /etc/nixos/models.nix
#
# Single source of truth for LLM and embedding model selection.
# All services that call an LLM or embedding model import this file.
# Exception: LiteLLM's own model catalog (backend endpoints, API keys, routing).
#
# To change the primary model, edit here and run: nixos-rebuild switch
{
  llm = {
    primary = {
      name = "hera/omlx/Qwen3.6-27B-oQ4e-mtp";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
    };
    # Low-latency model for latency-sensitive callers (e.g. rspamd spam
    # classification, where Postfix is blocked on the milter response).
    fast = {
      name = "hera/omlx/Qwen3.6-27B-oQ4e-mtp";
      maxSeconds = 120;
      initialDelay = 5;
      maxDelay = 60;
    };
    # Agent-grade model for long-running, tool-using sessions (OpenClaw
    # memory-qdrant, Discord/WhatsApp channels, ACP backend).  Kept separate
    # from `primary` so summarizers / alert probes can move independently.
    #
    # Optional fields below (contextWindow, maxTokens, api, reasoning, input,
    # cost) are consumed by modules/services/openclaw-config.nix to render
    # the .models.providers.vulcan.models[] entry. Defaults match what
    # openclaw expects today; tune per-model as needed.
    agent = {
      name = "hera/omlx/Qwen3.6-27B-oQ4e-mtp";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
      contextWindow = 262144;
      maxTokens = 81920;
      api = "openai-completions";
      reasoning = false;
      input = [ "text" ];
      cost = {
        input = 0;
        output = 0;
        # cacheRead/cacheWrite are required by openclaw's model-catalog schema
        # (agents/model-registry "Invalid models.json schema" doctor warning
        # when omitted). Zero because this is a local, cost-free MLX backend.
        cacheRead = 0;
        cacheWrite = 0;
      };
    };
    fallbacks = [
      # {
      #   name = "hera/gpt-oss-120b";
      #   maxSeconds = 3600;
      #   initialDelay = 5;
      #   maxDelay = 60;
      # }
      # {
      #   name = "hera/Qwen3.5-9B-Instruct";
      #   maxSeconds = 3600;
      #   initialDelay = 5;
      #   maxDelay = 30;
      # }
      # {
      #   name = "clio/Qwen3.5-9B-Instruct";
      #   maxSeconds = 3600;
      #   initialDelay = 5;
      #   maxDelay = 30;
      # }
      # {
      #   name = "hera/claude-sonnet-4-6";
      #   maxSeconds = 600;
      #   initialDelay = 5;
      #   maxDelay = 15;
      # }
    ];
  };

  embedding = {
    primary = {
      name = "hera/bge-m3";
    };
    fallbacks = [ ];
  };
}
