# Native Nix source of truth for the LiteLLM proxy config. This IS the config —
# edit model_list/credential_list/routing/etc. here directly.
# `mkSecret "name"` marks a point where the SOPS secret litellm/<name> is
# expanded (at activation, via sops.templates) into the rendered config.yaml.
# Consumed by modules/services/litellm-config.nix, which renders this to
# /etc/litellm/config.yaml.
{ mkSecret }:
{
  model_list = [
    {
      model_name = "hera/bge-m3";
      litellm_params = {
        model = "openai/bge-m3";
        litellm_credential_name = "hera_llama_swap_credential";
        drop_params = true;
        encoding_format = "float";
        supports_system_message = true;
      };
      model_info = {
        mode = "embedding";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "clio/bge-m3";
      litellm_params = {
        model = "openai/bge-m3";
        litellm_credential_name = "clio_llama_swap_credential";
        drop_params = true;
        encoding_format = "float";
        supports_system_message = true;
      };
      model_info = {
        mode = "embedding";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/omlx/bge-m3-mlx-fp16";
      litellm_params = {
        model = "openai/bge-m3-mlx-fp16";
        litellm_credential_name = "omlx_credential";
        drop_params = true;
        encoding_format = "float";
        supports_system_message = true;
      };
      model_info = {
        mode = "embedding";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/bge-reranker-v2-m3";
      litellm_params = {
        model = "openai/bge-reranker-v2-m3";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "reranker";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "clio/bge-reranker-v2-m3";
      litellm_params = {
        model = "openai/bge-reranker-v2-m3";
        litellm_credential_name = "clio_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "reranker";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-fable-5-thinking-32000";
      litellm_params = {
        model = "openai/claude-fable-5";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-fable-5";
      litellm_params = {
        model = "openai/claude-fable-5";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-fable-5";
      litellm_params = {
        model = "anthropic/claude-fable-5";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-fable-5[1m]";
      litellm_params = {
        model = "anthropic/claude-fable-5[1m]";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "anthropic/claude-fable-5";
      litellm_params = {
        model = "anthropic/claude-fable-5";
        litellm_credential_name = "anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-haiku-4-5-20251001";
      litellm_params = {
        model = "openai/claude-haiku-4-5-20251001";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-haiku-4-5-20251001";
      litellm_params = {
        model = "anthropic/claude-haiku-4-5-20251001";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "anthropic/claude-haiku-4-5-20251001";
      litellm_params = {
        model = "anthropic/claude-haiku-4-5-20251001";
        litellm_credential_name = "anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-opus-5-thinking-32000";
      litellm_params = {
        model = "openai/claude-opus-5";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-opus-5";
      litellm_params = {
        model = "openai/claude-opus-5";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-opus-5";
      litellm_params = {
        model = "anthropic/claude-opus-5";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-opus-5[1m]";
      litellm_params = {
        model = "anthropic/claude-opus-5[1m]";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "anthropic/claude-opus-5";
      litellm_params = {
        model = "anthropic/claude-opus-5";
        litellm_credential_name = "anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-sonnet-5-thinking-32000";
      litellm_params = {
        model = "openai/claude-sonnet-5";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/claude-sonnet-5";
      litellm_params = {
        model = "openai/claude-sonnet-5";
        litellm_credential_name = "hera_vibe_proxy_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-sonnet-5";
      litellm_params = {
        model = "anthropic/claude-sonnet-5";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_anthropic/claude-sonnet-5[1m]";
      litellm_params = {
        model = "anthropic/claude-sonnet-5[1m]";
        litellm_credential_name = "positron_anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "anthropic/claude-sonnet-5";
      litellm_params = {
        model = "anthropic/claude-sonnet-5";
        litellm_credential_name = "anthropic_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/omlx/cohere-transcribe-03-2026-mlx-fp16";
      litellm_params = {
        model = "openai/cohere-transcribe-03-2026-mlx-fp16";
        litellm_credential_name = "omlx_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "audio_transcription";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/cohere-transcribe-03-2026";
      litellm_params = {
        model = "openai/cohere-transcribe-03-2026";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "audio_transcription";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/mlx-community/deepseek-ai-DeepSeek-V4-Flash-8bit";
      litellm_params = {
        model = "openai/mlx-community/deepseek-ai-DeepSeek-V4-Flash-8bit";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_gemini/gemini-3-pro-preview";
      litellm_params = {
        model = "gemini/gemini-3-pro-preview";
        litellm_credential_name = "positron_gemini_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "Gemini 3 Pro (Positron)";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_gemini/gemini-3.1-pro-preview";
      litellm_params = {
        model = "gemini/gemini-3.1-pro-preview";
        litellm_credential_name = "positron_gemini_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "Gemini 3.1 Pro (Positron)";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/GLM-4.7-Flash";
      litellm_params = {
        model = "openai/GLM-4.7-Flash";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/GLM-5.2";
      litellm_params = {
        model = "openai/GLM-5.2";
        litellm_credential_name = "hera_llama_swap_credential";
        stream_timeout = 7200;
        timeout = 7200;
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "openrouter/z-ai/glm-5.2";
      litellm_params = {
        model = "openrouter/z-ai/glm-5.2";
        litellm_credential_name = "openrouter_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "factory/glm-5.2";
      litellm_params = {
        # DORMANT: returns 401 — Factory's model gateway needs a WorkOS JWT, not
        # the fk- API key. See factory_credential in credential_list for the full
        # rationale and the options for making it live.
        model = "openai/glm-5.2";
        litellm_credential_name = "factory_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "openrouter/deepseek/deepseek-v4-flash";
      litellm_params = {
        model = "openrouter/deepseek/deepseek-v4-flash";
        litellm_credential_name = "openrouter_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_openai/gpt-5.5";
      litellm_params = {
        model = "openai/gpt-5.5";
        litellm_credential_name = "positron_openai_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "ChatGPT 5.5 (Positron)";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_openai/gpt-5.6-luna";
      litellm_params = {
        model = "openai/gpt-5.6-luna";
        litellm_credential_name = "positron_openai_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "ChatGPT 5.6 Luna (Positron)";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_openai/gpt-5.6-sol";
      litellm_params = {
        model = "openai/gpt-5.6-sol";
        litellm_credential_name = "positron_openai_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "ChatGPT 5.6 Sol (Positron)";
        max_input_tokens = 1050000;
        max_output_tokens = 128000;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron_openai/gpt-5.6-terra";
      litellm_params = {
        model = "openai/gpt-5.6-terra";
        litellm_credential_name = "positron_openai_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "ChatGPT 5.6 Terra (Positron)";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/gpt-oss-120b";
      litellm_params = {
        model = "openai/gpt-oss-120b";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/gpt-oss-20b";
      litellm_params = {
        model = "openai/gpt-oss-20b";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/gpt-oss-safeguard-20b";
      litellm_params = {
        model = "openai/gpt-oss-safeguard-20b";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/granite-speech-4.1-2b";
      litellm_params = {
        model = "openai/granite-speech-4.1-2b";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "audio_transcription";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Huihui-Qwable-3.6-27b-abliterated-MTP";
      litellm_params = {
        model = "openai/Huihui-Qwable-3.6-27b-abliterated-MTP";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "openrouter/moonshotai/kimi-k3";
      litellm_params = {
        model = "openrouter/moonshotai/kimi-k3";
        litellm_credential_name = "openrouter_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/LFM2.5-350M";
      litellm_params = {
        model = "openai/LFM2.5-350M";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/GreenBitAI/Llama-2-13B-layer-mix-bpw-2.2-mlx";
      litellm_params = {
        model = "openai/GreenBitAI/Llama-2-13B-layer-mix-bpw-2.2-mlx";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/GreenBitAI/Llama-2-13B-layer-mix-bpw-2.5-mlx";
      litellm_params = {
        model = "openai/GreenBitAI/Llama-2-13B-layer-mix-bpw-2.5-mlx";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/GreenBitAI/Llama-2-13B-layer-mix-bpw-3.0-mlx";
      litellm_params = {
        model = "openai/GreenBitAI/Llama-2-13B-layer-mix-bpw-3.0-mlx";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "positron/llama-3.3-70b-instruct-good-tp2";
      litellm_params = {
        model = "openai/llama-3.3-70b-instruct-good-tp2";
        litellm_credential_name = "positron_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "groq/llama-3.3-70b-versatile";
      litellm_params = {
        model = "groq/llama-3.3-70b-versatile";
        litellm_credential_name = "groq_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Meta-Llama-3.1-8B";
      litellm_params = {
        model = "openai/Meta-Llama-3.1-8B";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Nemotron-3-Nano-30B-A3B";
      litellm_params = {
        model = "openai/Nemotron-3-Nano-30B-A3B";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Nemotron-Cascade-2-30B-A3B";
      litellm_params = {
        model = "openai/Nemotron-Cascade-2-30B-A3B";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/nomic-embed-text-v2-moe";
      litellm_params = {
        model = "openai/nomic-embed-text-v2-moe";
        litellm_credential_name = "hera_llama_swap_credential";
        drop_params = true;
        encoding_format = "float";
        supports_system_message = true;
      };
      model_info = {
        mode = "embedding";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/NVIDIA-Nemotron-3-Super-120B-A12B";
      litellm_params = {
        model = "openai/NVIDIA-Nemotron-3-Super-120B-A12B";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Phi-4-reasoning-plus";
      litellm_params = {
        model = "openai/Phi-4-reasoning-plus";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Qwen.Qwen3-Reranker-8B";
      litellm_params = {
        model = "openai/Qwen.Qwen3-Reranker-8B";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "reranker";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Qwen3-Embedding-8B";
      litellm_params = {
        model = "openai/Qwen3-Embedding-8B";
        litellm_credential_name = "hera_llama_swap_credential";
        drop_params = true;
        encoding_format = "float";
        supports_system_message = true;
      };
      model_info = {
        mode = "embedding";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/omlx/Qwen3.6-27B-oQ4e-mtp";
      litellm_params = {
        model = "openai/Qwen3.6-27B-oQ4e-mtp";
        litellm_credential_name = "omlx_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "clio/omlx/Qwen3.6-35B-A3B-oQ4-mtp";
      litellm_params = {
        model = "openai/Qwen3.6-35B-A3B-oQ4-mtp";
        litellm_credential_name = "clio_omlx_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "openrouter/qwen/qwen3.7-max";
      litellm_params = {
        model = "openrouter/qwen/qwen3.7-max";
        litellm_credential_name = "openrouter_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/Qwopus3.5-27B-v3";
      litellm_params = {
        model = "openai/Qwopus3.5-27B-v3";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/SERA-32B";
      litellm_params = {
        model = "openai/SERA-32B";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = true;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/atorsvn/TinyLlama-1.1B-Chat-v0.1-gptq-4bit";
      litellm_params = {
        model = "openai/atorsvn/TinyLlama-1.1B-Chat-v0.1-gptq-4bit";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
    {
      model_name = "hera/atorsvn/TinyLlama-1.1B-step-50K-105b-gptq-4bit";
      litellm_params = {
        model = "openai/atorsvn/TinyLlama-1.1B-step-50K-105b-gptq-4bit";
        litellm_credential_name = "hera_llama_swap_credential";
        supports_system_message = true;
      };
      model_info = {
        mode = "chat";
        description = "";
        max_output_tokens = 81920;
        supports_function_calling = true;
        supports_reasoning = false;
        supports_response_schema = false;
      };
    }
  ];
  credential_list = [
    {
      credential_name = "hera_llama_swap_credential";
      credential_values = {
        api_base = "https://hera.lan:8443/v1";
        api_key = "fake";
      };
      credential_info = {
        description = "API Key for llama-swap on Hera";
      };
    }
    {
      credential_name = "hera_vibe_proxy_credential";
      credential_values = {
        api_base = "http://hera.lan:8317/v1";
        api_key = "fake";
      };
      credential_info = {
        description = "API Key for vibe-proxy on Hera";
      };
    }
    {
      credential_name = "clio_llama_swap_credential";
      credential_values = {
        api_base = "http://clio.lan:8080/v1";
        api_key = "fake";
      };
      credential_info = {
        description = "API Key for llama-swap on Clio";
      };
    }
    {
      credential_name = "clio_omlx_credential";
      credential_values = {
        api_base = "http://clio.lan:8000/v1";
        api_key = "fake";
      };
      credential_info = {
        description = "API Key for oMLX on Clio";
      };
    }
    {
      credential_name = "openai_credential";
      credential_values = {
        api_key = "os.environ/OPENAI_API_KEY";
      };
      credential_info = {
        description = "API Key for OpenAI";
      };
    }
    {
      credential_name = "anthropic_credential";
      credential_values = {
        api_key = "os.environ/ANTHROPIC_API_KEY";
      };
      credential_info = {
        description = "API Key for Anthropic";
      };
    }
    {
      credential_name = "perplexity_credential";
      credential_values = {
        api_key = "os.environ/PERPLEXITYAI_API_KEY";
      };
      credential_info = {
        description = "API Key for Perplexity";
      };
    }
    {
      credential_name = "groq_credential";
      credential_values = {
        api_key = "os.environ/GROQ_API_KEY";
      };
      credential_info = {
        description = "API Key for Groq";
      };
    }
    {
      credential_name = "openrouter_credential";
      credential_values = {
        api_key = "os.environ/OPENROUTER_API_KEY";
      };
      credential_info = {
        description = "API Key for OpenRouter";
      };
    }
    {
      credential_name = "factory_credential";
      credential_values = {
        # ── DORMANT SCAFFOLD — factory/glm-5.2 cannot work as configured. ──
        #
        # This is Factory's OpenAI-compatible model gateway (the /o/ tree = OpenAI
        # format; /a/ = Anthropic /v1/messages, /g/ = Google). It is the endpoint
        # Droid itself targets, and it is NOT app.factory.ai/v1 (that serves the
        # web console: SPA HTML / 405). Model ids here are bare (glm-5.2), and
        # `factory/` is not a LiteLLM provider, hence litellm_params.model =
        # "openai/glm-5.2" on the model entry above.
        #
        # WHY IT 401s (investigated 2026-07-26): this gateway validates
        # short-lived WorkOS JWT access tokens ONLY. The FACTORY_API_KEY below is
        # an `fk-` key from app.factory.ai/settings/api-keys, which authenticates
        # Factory's CONTROL PLANE (api.factory.ai/api/v0/sessions, billing/limits,
        # usage, readiness reports) and the `droid exec` CLI — but the LLM data
        # plane rejects it with 401 "Access token is invalid or expired. Please
        # sign in again." (i.e. it tried to parse the key as a WorkOS JWT).
        # Verified: adding Droid's full client header set (x-factory-client: cli,
        # factory-cli/<ver> UA, x-session-id, x-stainless-*) does NOT help — it is
        # the token TYPE, not missing headers. There is no fk- -> JWT exchange
        # endpoint; Droid's token comes from a browser sign-in whose refresh_token
        # is re-exchanged at WorkOS every ~6h.
        #
        # Kept dormant deliberately: the endpoint and routing here are correct, so
        # this becomes live the moment a valid Bearer token is available. Options
        # if that is ever wanted: (a) a droid2api-style sidecar holding the WorkOS
        # refresh loop (needs a Droid browser login + refresh_token in SOPS;
        # unsupported, spoofs the CLI user-agent, and Factory's ToS forbids
        # reverse engineering), or (b) skip LiteLLM and use `droid exec` /
        # `droid exec --output-format acp`, where the fk- key works as intended.
        # Calling factory/glm-5.2 meanwhile just returns 401; nothing else breaks.
        api_base = "https://app.factory.ai/api/llm/o/v1";
        api_key = "os.environ/FACTORY_API_KEY";
      };
      credential_info = {
        description = "API Key for Factory (dormant — gateway needs a WorkOS JWT, not this fk- key)";
      };
    }
    {
      credential_name = "positron_openai_credential";
      credential_values = {
        api_key = "os.environ/POSITRON_OPENAI_API_KEY";
      };
      credential_info = {
        description = "API Key for OpenAI (Positron)";
      };
    }
    {
      credential_name = "positron_anthropic_credential";
      credential_values = {
        api_key = "os.environ/POSITRON_ANTHROPIC_API_KEY";
      };
      credential_info = {
        description = "API Key for Anthropic (Positron)";
      };
    }
    {
      credential_name = "positron_gemini_credential";
      credential_values = {
        api_key = "os.environ/POSITRON_GEMINI_API_KEY";
      };
      credential_info = {
        description = "API Key for Google AI (Positron)";
      };
    }
    {
      credential_name = "positron_credential";
      credential_values = {
        api_base = "https://api-dev.positron.ai/v1";
        api_key = "os.environ/POSITRON_API_KEY";
      };
      credential_info = {
        description = "API Key for Positron.ai";
      };
    }
    {
      credential_name = "omlx_credential";
      credential_values = {
        api_base = "http://hera.lan:8000/v1";
        api_key = mkSecret "omlx-api-key";
      };
      credential_info = {
        description = "API Key for oMLX on Hera";
      };
    }
  ];
  environment_variables = {
    ANTHROPIC_API_KEY = mkSecret "anthropic-api-key";
    GEMINI_API_KEY = mkSecret "gemini-api-key";
    OPENAI_API_KEY = mkSecret "openai-api-key";
    PERPLEXITYAI_API_KEY = mkSecret "perplexityai-api-key";
    GROQ_API_KEY = mkSecret "groq-api-key";
    OPENROUTER_API_KEY = mkSecret "openrouter-api-key";
    FACTORY_API_KEY = mkSecret "factory-api-key";
    POSITRON_ANTHROPIC_API_KEY = mkSecret "positron_anthropic-api-key";
    POSITRON_GEMINI_API_KEY = mkSecret "positron_gemini-api-key";
    POSITRON_OPENAI_API_KEY = mkSecret "positron_openai-api-key";
    POSITRON_API_KEY = mkSecret "positron-api-key";
  };
  litellm_settings = {
    request_timeout = 7200;
    ssl_verify = false;
    drop_params = true;
    model_group_settings = {
      forward_client_headers_to_llm_api = [ "openrouter/z-ai/glm-5.2" ];
    };
    cache = true;
    cache_params = {
      type = "redis";
      mode = "default_off";
      namespace = "agent-response-cache:v1";
      ttl = 300;
      host = "10.0.2.2";
      port = 8085;
      supported_call_types = [
        "completion"
        "atext_completion"
        "aembedding"
        "atranscription"
      ];
    };
  };
  guardrails = [
    {
      guardrail_name = "harmony_filter";
      litellm_params = {
        guardrail = "harmony_filter.HarmonyResponseFilter";
        mode = "post_call";
        default_on = true;
      };
    }
  ];
  router_settings = {
    routing_strategy = "least-busy";
    num_retries = 3;
    request_timeout = 7200;
    max_parallel_requests = 100;
    allowed_fails = 3;
    cooldown_time = 30;
  };
  general_settings = {
    background_health_checks = false;
    health_check_interval = 0;
    store_model_in_db = true;
    # Prompt/response BODIES are no longer persisted. Set false 2026-07-28 after an
    # audit found LiteLLM_SpendLogs holding 273 days of request and response bodies
    # in 55 GB of TOAST -- three times the 90d policy below, because that policy had
    # never once executed (see the interval note). The bodies land in
    # `proxy_server_request` (~38 GB) and `response` (~17 GB), NOT in the
    # innocuously-named `messages` column, which held 21 kB. On a host whose
    # CLAUDE.md documents repeated pasted-secret incidents, and which proxies for
    # Claude Code / OpenClaw / Hermes, that table was a standing privacy surface.
    # Cost/attribution data is unaffected: model, model_group, provider, spend,
    # token counts, timings, cache_hit, session_id, metadata and tags all persist.
    store_prompts_in_spend_logs = false;
    maximum_spend_logs_retention_period = "90d";
    # 7d -> 6h. The retention sweep is gated on PROCESS UPTIME, and this rootless
    # container is restarted nightly by update-containers.timer, so uptime never
    # reached 7d and the 90d retention above was dead config from the day it was
    # written. Any value below the ~24h restart cadence works; 6h gives four
    # chances per day so a single missed window is not a lost day.
    maximum_spend_logs_retention_interval = "6h";
    enable_pass_through_endpoints = true;
  };
}
