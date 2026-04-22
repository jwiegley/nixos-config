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
      name = "hera/Qwen3.5-27B-Instruct";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
    };
    # Low-latency model for latency-sensitive callers (e.g. rspamd spam
    # classification, where Postfix is blocked on the milter response).
    fast = {
      name = "hera/Qwen3.5-9B-Instruct";
      maxSeconds = 60;
      initialDelay = 2;
      maxDelay = 10;
    };
    # Agent-grade model for long-running, tool-using sessions (OpenClaw
    # memory-qdrant, Discord/WhatsApp channels, ACP backend).  Kept separate
    # from `primary` so summarizers / alert probes can move independently.
    agent = {
      # name = "hera/omlx/Qwen3.5-397B-A17B-unsloth-mlx-4bit";
      name = "hera/omlx/Qwen3.6-35B-A3B-UD-MLX-4bit";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
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
