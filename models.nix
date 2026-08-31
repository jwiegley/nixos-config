# /etc/nixos/models.nix
#
# Single source of truth for LLM and embedding model selection.
# All services that call an LLM or embedding model import this file.
#
# These are the REAL model ids as served by the oMLX backend behind the
# host gateway on 127.0.0.1:4000 (see modules/services/hera-llm-proxy.nix).
# There is no aliasing layer any more -- the gateway is a plain reverse proxy
# and does not rewrite request bodies, so whatever is written here is what the
# backend receives. Check a candidate name against the live list first:
#
#   curl -s http://127.0.0.1:4000/v1/models | jq -r '.data[].id'
#
# To change the primary model, edit here and run: /etc/nixos/build
{
  llm = {
    primary = {
      name = "Qwen3.8-27B-oQ4e-mtp";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
    };
    # Low-latency model for latency-sensitive callers (e.g. rspamd spam
    # classification, where Postfix is blocked on the milter response).
    fast = {
      name = "Qwen3.8-27B-oQ4e-mtp";
      maxSeconds = 120;
      initialDelay = 5;
      maxDelay = 60;
    };

    # Reasoning tier: long context + reasoning enabled. Added 2026-08-02 for
    # the two consumers that want it -- the Hermes agent and Vane (Perplexica).
    # Everything else on this host stays on Qwen via `primary`/`fast`.
    #
    # Why a separate role rather than editing an existing one: `primary` is shared
    # by Vane AND stock-trader AND Open WebUI, so changing it would have moved
    # services the operator wanted left alone. Roles here describe a TIER, not a
    # service, so the correct fix for "these two and no others" is a new tier.
    #
    # HISTORY: this rationale used to weigh a fourth `agent` tier as well. That
    # tier existed for a second agent VM, lost its last consumer when Hermes moved
    # here, and was removed 2026-08-05. hermes-microvm.nix serialises this attrset
    # into restartTriggers, so its field shape still matters -- a changed shape
    # changes the trigger hash and restarts the VM.
    reasoning = {
      # name = "DeepSeek-V4-Flash-0731-MXFP4-MLX";
      name = "GLM-5.3-Flash-oQ4e";
      maxSeconds = 3600;
      initialDelay = 5;
      maxDelay = 60;
      contextWindow = 1048576;
      maxTokens = 81920;
      api = "openai-completions";
      reasoning = true;
      input = [ "text" ];
      cost = {
        input = 0;
        output = 0;
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
      name = "bge-m3-mlx-fp16";
    };
    fallbacks = [ ];
  };
}
