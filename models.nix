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
      # name = "hera/Qwen3.5-27B-Instruct";
      name = "hera/omlx/GLM-5.1-MXFP4-Q8";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
    };
    # Low-latency model for latency-sensitive callers (e.g. rspamd spam
    # classification, where Postfix is blocked on the milter response).
    fast = {
      name = "hera/omlx/Qwen3.5-9B-Instruct-unsloth-mlx";
      maxSeconds = 60;
      initialDelay = 2;
      maxDelay = 10;
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
