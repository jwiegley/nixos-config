# stock-trader: NixOS service module.
#
# Wraps the stock-trader package (defined in pkgs/stock-trader.nix and
# wired through overlays/default.nix) as a hardened systemd service
# behind an nginx vhost terminating step-ca TLS at
# https://trader.vulcan.lan.
#
# Modeled on modules/services/jupyterlab.nix (the gold-standard native
# Python service on this host). Differences vs jupyterlab.nix:
#
#   - Stricter hardening: stock-trader does not need SageMath's broad
#     system access, so we keep the Protect* / Restrict* directives
#     enabled. jupyterlab.nix disables them in comments — that
#     accommodation does not apply here.
#   - Uses LoadCredential rather than passing secrets through HOME
#     because the runtime reads API keys from environment variables.
#     A small wrapper script bridges $CREDENTIALS_DIRECTORY/<name> →
#     real env vars before exec'ing the package's /bin/stock-trader.
#   - MemoryMax = "2G" (per spec); jupyterlab is 8G for ML workloads.
#
# The whole config block is `lib.mkIf cfg.enable {...}` so a dry-build
# with the service disabled does not require the secrets to exist or
# the TLS cert to have been issued. Final activation is part of the
# Chunk 3 bring-up.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.stock-trader;

  # Bridge LoadCredential files into env vars expected by the runtime.
  # Each file under $CREDENTIALS_DIRECTORY is the plaintext API key,
  # produced by sops-install-secrets and exposed read-only to the
  # service via systemd's LoadCredential mechanism. We read it into a
  # variable, export, then exec the package's wrapped uvicorn.
  #
  # POLYGON_API_KEY and ANTHROPIC_API_KEY are loaded conditionally —
  # the service degrades gracefully if either is missing (the chat
  # engine will fall back to the litellm proxy on :4000 when the
  # Anthropic key is absent, and Polygon is an optional fallback
  # source after Schwab and yfinance).
  startScript = pkgs.writeShellScript "stock-trader-start" ''
    set -euo pipefail

    if [ -f "$CREDENTIALS_DIRECTORY/anthropic-api-key" ]; then
      ANTHROPIC_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/anthropic-api-key")"
      export ANTHROPIC_API_KEY
    fi
    if [ -f "$CREDENTIALS_DIRECTORY/schwab-app-key" ]; then
      SCHWAB_APP_KEY="$(cat "$CREDENTIALS_DIRECTORY/schwab-app-key")"
      export SCHWAB_APP_KEY
    fi
    if [ -f "$CREDENTIALS_DIRECTORY/schwab-app-secret" ]; then
      SCHWAB_APP_SECRET="$(cat "$CREDENTIALS_DIRECTORY/schwab-app-secret")"
      export SCHWAB_APP_SECRET
    fi
    if [ -f "$CREDENTIALS_DIRECTORY/finnhub-api-key" ]; then
      FINNHUB_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/finnhub-api-key")"
      export FINNHUB_API_KEY
    fi
    if [ -f "$CREDENTIALS_DIRECTORY/fred-api-key" ]; then
      FRED_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/fred-api-key")"
      export FRED_API_KEY
    fi
    if [ -f "$CREDENTIALS_DIRECTORY/polygon-api-key" ]; then
      POLYGON_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/polygon-api-key")"
      export POLYGON_API_KEY
    fi
    if [ -f "$CREDENTIALS_DIRECTORY/alpha-vantage-api-key" ]; then
      ALPHA_VANTAGE_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/alpha-vantage-api-key")"
      export ALPHA_VANTAGE_API_KEY
    fi

    exec ${pkgs.stock-trader}/bin/stock-trader
  '';
in
{
  options.services.stock-trader = {
    enable = lib.mkEnableOption "the stock-trader web service";
  };

  config = lib.mkIf cfg.enable {
    # SOPS credentials. Each is a top-level entry under the
    # `stock-trader:` map in secrets/secrets.yaml. mode/owner is
    # locked tight; DynamicUser reads them indirectly through
    # LoadCredential (root reads from sops, copies into the per-unit
    # credential dir owned by root mode 0400, systemd then bind-mounts
    # that directory into the unit's namespace).
    sops.secrets."stock-trader/anthropic-api-key" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };
    sops.secrets."stock-trader/schwab-app-key" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };
    sops.secrets."stock-trader/schwab-app-secret" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };
    sops.secrets."stock-trader/finnhub-api-key" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };
    sops.secrets."stock-trader/fred-api-key" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };
    sops.secrets."stock-trader/polygon-api-key" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };
    sops.secrets."stock-trader/alpha-vantage-api-key" = {
      owner = "root";
      mode = "0400";
      restartUnits = [ "stock-trader.service" ];
    };

    systemd.services.stock-trader = {
      description = "Stock Trader web service";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wantedBy = [ "multi-user.target" ];

      # The Claude Agent SDK shells out to a `claude` binary it
      # locates via shutil.which("claude"). Without claude-code on
      # the unit's PATH the SDK prints "Claude Code not found" and
      # the chat panel hangs. Adding it here injects the package's
      # bin/ into the unit's PATH (systemd composes `path` with the
      # default, so coreutils etc. remain available).
      path = [ pkgs.claude-code ];

      environment = {
        # Bind the uvicorn listener on loopback only; nginx
        # reverse-proxies to it from the LAN-facing :443.
        STOCK_TRADER_HOST = "127.0.0.1";
        STOCK_TRADER_PORT = "8234";

        # %S expands to /var/lib/private/<StateDirectory> for
        # DynamicUser units; sub-dirs cache and schwab_token.json
        # live there (RW for the dynamic user).
        STOCK_TRADER_CACHE_DIR = "%S/stock-trader/cache";
        SCHWAB_TOKEN_PATH = "%S/stock-trader/schwab_token.json";

        # Static SPA bundle, served by FastAPI's StaticFiles. Points
        # at the package's read-only share/ directory.
        STOCK_TRADER_STATIC_DIR = "${pkgs.stock-trader}/share/stock-trader/web/dist";

        # ANTHROPIC_BASE_URL points at the litellm-anthropic-fixup
        # proxy on :4001, NOT directly at LiteLLM's :4000. The proxy
        # strips text blocks from assistant messages that also
        # contain tool_use blocks, working around LiteLLM's
        # anthropic→responses-API converter misorder bug; see
        # /etc/nixos/modules/services/litellm-anthropic-fixup.nix
        # and /etc/nixos/docs/LITELLM_TOOL_USE_BUG_REPORT.md. The
        # proxy forwards untouched everything else, so ANTHROPIC_MODEL
        # "hera/claude-opus-4-7" still routes through the same
        # LiteLLM model group as before.
        ANTHROPIC_BASE_URL = "http://127.0.0.1:4001";
        ANTHROPIC_MODEL = "hera/claude-opus-4-7";

        LOG_LEVEL = "INFO";

        # claude-code persists session metadata under $HOME/.claude/.
        # DynamicUser units default HOME to "/", which is read-only
        # under ProtectSystem=strict. Point HOME at the writable
        # StateDirectory so claude-code's session writes succeed.
        HOME = "%S/stock-trader";

        # STOCK_TRADER_ALLOW_OAUTH_BOOTSTRAP is intentionally NOT
        # set here. The Schwab OAuth flow does not run on the server
        # — the laptop bootstraps the token and we copy/mount the
        # resulting JSON into %S/stock-trader/schwab_token.json.
        # Leaving this unset disables the bootstrap routes via the
        # Chunk 1 Task 3 gate.
        #
        # SSL_CERT_FILE and REQUESTS_CA_BUNDLE are also intentionally
        # NOT set here. NixOS exports them globally via security.pki
        # so child processes inherit them. Pinning here would
        # circumvent the system-wide trust-store updates that happen
        # when step-ca rotates roots.
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${startScript}";
        Restart = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
        StateDirectory = "stock-trader";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "stock-trader";
        RuntimeDirectoryMode = "0750";

        LoadCredential = [
          "anthropic-api-key:${config.sops.secrets."stock-trader/anthropic-api-key".path}"
          "schwab-app-key:${config.sops.secrets."stock-trader/schwab-app-key".path}"
          "schwab-app-secret:${config.sops.secrets."stock-trader/schwab-app-secret".path}"
          "finnhub-api-key:${config.sops.secrets."stock-trader/finnhub-api-key".path}"
          "fred-api-key:${config.sops.secrets."stock-trader/fred-api-key".path}"
          "polygon-api-key:${config.sops.secrets."stock-trader/polygon-api-key".path}"
          "alpha-vantage-api-key:${config.sops.secrets."stock-trader/alpha-vantage-api-key".path}"
        ];

        # Hardening. Stricter than jupyterlab.nix because we don't
        # need sage's broad system access.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        # MemoryDenyWriteExecute would break Python's CPython JIT in
        # 3.13+; leaving false matches jupyterlab.nix which has the
        # same caveat. Python 3.12 (our runtime) does not strictly
        # need it disabled, but enable=False removes a future breakage.
        MemoryDenyWriteExecute = false;

        # Resource caps per spec.
        MemoryMax = "2G";
      };
    };

    # Upstream named "stock-trader" so the proxyPass URL preserves
    # the request URI without inserting a synthetic trailing slash.
    services.nginx.upstreams.stock-trader = {
      servers."127.0.0.1:8234" = {
        max_fails = 0;
      };
      extraConfig = ''
        keepalive 16;
        keepalive_timeout 60s;
      '';
    };

    services.nginx.virtualHosts."trader.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/trader.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/trader.vulcan.lan.key";

      locations."/" = {
        # No trailing slash on the upstream URL — preserves the
        # request URI exactly. /api/foo proxies to
        # http://stock-trader/api/foo, not
        # http://stock-trader//api/foo.
        proxyPass = "http://stock-trader";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_next_upstream error timeout http_502 http_503 http_504;
          proxy_next_upstream_tries 3;
          proxy_next_upstream_timeout 10s;

          # Long-running streams (chat / WebSocket / SSE) need
          # generous timeouts, otherwise nginx drops idle reads.
          proxy_connect_timeout 3600;
          proxy_send_timeout 3600;
          proxy_read_timeout 3600;

          # Stream responses straight back to the client; fast
          # path for chat token streaming.
          proxy_buffering off;
          proxy_request_buffering off;
        '';
      };
    };
  };
}
