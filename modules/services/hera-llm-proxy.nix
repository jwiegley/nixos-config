# Host-side LLM gateway on 127.0.0.1:4000.
#
# This replaces the LiteLLM proxy that used to own this port. Every LLM
# consumer on vulcan -- host services, the Hermes microVM (via the
# hermes-br0 DNAT, see modules/services/hermes-microvm.nix), Home Assistant,
# rspamd, the log summarizer -- already points at 127.0.0.1:4000, so keeping
# the port and the OpenAI wire shape means none of them need to be rewired.
#
# What changed underneath: instead of a routing proxy with its own model
# catalog and a dozen hosted-provider API keys, this is a plain nginx reverse
# proxy onto the single llama-swap backend at https://hera.lan:8443/v1.
#
# Consequences that are deliberate, not oversights:
#   * Model ALIASING is gone. llama-swap serves its models under their real
#     names, so callers must ask for `Qwen3.6-27B-oQ4e-mtp`, not the old
#     `hera/omlx/Qwen3.6-27B-oQ4e-mtp` alias. models.nix carries the real
#     names now and is still the single source of truth.
#   * HOSTED providers (anthropic/openai/gemini/groq/openrouter/perplexity)
#     are gone with the catalog that defined them. The backend is local MLX
#     only.
#   * Rerank is gone -- no rerank model is loaded upstream (/v1/rerank -> 400).
#
# Verified against the live backend on 2026-08-01: /v1/models, /v1/chat/completions,
# /v1/embeddings (bge-m3-mlx-fp16, dim 1024), /v1/audio/transcriptions and
# /v1/messages (llama-swap speaks the Anthropic shape natively, which is why the
# old litellm-anthropic-fixup translation proxy is not carried forward) all answer.
{
  config,
  ...
}:

let
  listenPort = 4000;
  upstreamHost = "hera.lan";
  upstreamUrl = "https://${upstreamHost}:8443";

  # The rendered one-line nginx snippet holding the Authorization header.
  authSnippet = config.sops.templates."hera-llm-proxy-auth.conf".path;
in
{
  # The backend authenticates the bearer token by VALUE (a bogus token gets
  # 401), so the key is a real credential and must not land in the
  # world-readable Nix store. sops-nix renders the header line at activation
  # into /run, and nginx `include`s it -- the value exists only on tmpfs.
  #
  # THE LAST `litellm`-NAMED SECRET REFERENCE IN THIS REPO, and it is
  # unavoidable rather than an oversight. Every other module that used to
  # reference a `litellm*` SOPS entry was made independent of it on 2026-08-01,
  # because in all those cases the value was inert -- this proxy overwrites the
  # client's Authorization header, so those consumers only ever needed a
  # non-empty placeholder, and they now use a literal sentinel.
  #
  # This one is different: it is the REAL bearer token the gateway presents
  # upstream, and the backend validates it BY VALUE (a bogus token gets 401,
  # verified 2026-08-01). It cannot be replaced with a sentinel, and
  # secrets.yaml contains no other entry holding this value, so the pointer has
  # to keep the existing name.
  #
  # TO FINISH THE RENAME (operator action, needs an interactive `sops` session):
  #   1. sops /etc/nixos/secrets/secrets.yaml
  #   2. copy the value of `litellm/omlx-api-key` to a new key, e.g.
  #      `hera/llm-gateway-key`
  #   3. change the `key =` line below to match, rebuild, then confirm with
  #      `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/v1/models`
  #      (200 = the new entry is correct; 401 = wrong value)
  #   4. only then delete the old entry
  # The nix attribute name is already neutral, so step 3 is a one-line change.
  sops.secrets."hera-llm-api-key" = {
    key = "litellm/omlx-api-key";
    owner = "root";
    mode = "0400";
  };

  # owner MUST be nginx, not root: this host runs nginx with User=nginx, and the
  # config *test* in ExecStartPre reads every `include` as that user. A 0400
  # root-owned snippet makes `nginx -t` fail with EACCES, which fails the unit
  # and takes down EVERY vhost, not just this one.
  sops.templates."hera-llm-proxy-auth.conf" = {
    content = ''
      proxy_set_header Authorization "Bearer ${config.sops.placeholder."hera-llm-api-key"}";
    '';
    owner = "nginx";
    group = "nginx";
    mode = "0400";
  };

  services.nginx.virtualHosts."hera-llm-proxy" = {
    # Plain HTTP on loopback only. Consumers used http://127.0.0.1:4000
    # against LiteLLM and continue to; the TLS leg is nginx -> hera.
    listen = [
      {
        addr = "127.0.0.1";
        port = listenPort;
      }
    ];

    locations."/" = {
      proxyPass = upstreamUrl;

      # MUST stay false. The recommended-settings include is appended AFTER
      # extraConfig, and it contains `proxy_set_header Host $host;` -- so with
      # it enabled the upstream receives `Host: 127.0.0.1:4000` instead of
      # `hera.lan`, matches no server_name on hera, and every request comes
      # back 400 from *hera's* nginx. The X-Forwarded-* headers it adds are
      # meaningless here anyway: the only client is loopback.
      recommendedProxySettings = false;

      extraConfig = ''
        # Injected host-side so no consumer -- and in particular not the
        # Hermes guest, which has no sops-nix -- ever holds this key.
        include ${authSnippet};

        # Verify the backend's certificate against the Vulcan CA rather than
        # trusting the LAN. hera.lan:8443 presents a cert issued by the Vulcan
        # intermediate; proxy_ssl_name/server_name are required for SNI, and
        # without them the handshake gets the default vhost's cert.
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 3;
        # Runtime path, not the build-time store path: this is the convention
        # everywhere else in this repo (openclaw.nix, mbsync.nix, ...) and it
        # picks up a CA rotation without needing a rebuild.
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_name ${upstreamHost};
        proxy_ssl_server_name on;

        # Token streaming (SSE) must not sit in a buffer, or callers see the
        # whole completion arrive at once after a long silence.
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        # A cold model load plus a long generation can run for many minutes;
        # models.nix allows up to maxSeconds = 3600 for the primary model, so
        # the proxy must not time out before the caller's own budget does.
        proxy_connect_timeout 30s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        # Prompts and embedding batches are large.
        client_max_body_size 128m;
        client_body_buffer_size 1m;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host ${upstreamHost};
      '';
    };
  };
}
