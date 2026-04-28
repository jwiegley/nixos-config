# litellm-anthropic-fixup: forwarding proxy that sanitizes
# Anthropic /v1/messages requests before they hit LiteLLM.
#
# WHY:
# LiteLLM's anthropic→responses-API converter
# (/app/litellm/llms/anthropic/experimental_pass_through/responses_adapters/
# transformation.py) emits `function_call` items BEFORE the assistant
# `message` item in the converted Responses API input array when an
# assistant turn has both text and tool_use blocks. The downstream
# Vibe proxy converts back to Anthropic and the resulting structure
# violates Anthropic's "tool_use must be immediately followed by
# tool_result" rule, returning 400. See
# /etc/nixos/docs/LITELLM_TOOL_USE_BUG_REPORT.md for the full
# upstream write-up.
#
# Stock-trader's prompt-level workaround (v0.1.3+) tried to prevent
# the model from ever emitting text + tool_use in one response. Real
# usage shows the model frequently ignores that rule on naturalistic
# queries, so the bug fires anyway.
#
# This proxy strips text blocks from any assistant message whose
# content also contains tool_use blocks, BEFORE forwarding to
# LiteLLM. User-visible UX is unaffected: claude CLI streams the
# text to the SPA before the body hits this proxy. We only sanitize
# the conversation-history snapshot sent upstream so the misorder
# converter produces a valid request.
#
# Listening on 127.0.0.1:4001; LiteLLM continues to listen on :4000
# for direct callers. stock-trader.nix points ANTHROPIC_BASE_URL at
# the proxy.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.litellm-anthropic-fixup;

  # The proxy script. Stdlib + aiohttp; no other deps so the runtime
  # python env is small. The fixup logic is a single function that
  # only mutates POST /v1/messages bodies; everything else is a
  # transparent passthrough.
  proxyScript =
    pkgs.writers.writePython3 "litellm-anthropic-fixup"
      {
        libraries = [ pkgs.python3Packages.aiohttp ];
        flakeIgnore = [
          "E501" # long lines in docstrings
          "W503" # line break before binary operator (black/ruff style)
        ];
      }
      ''
        """LiteLLM Anthropic /v1/messages preprocessing proxy."""

        import asyncio
        import json
        import sys

        from aiohttp import ClientSession, web

        UPSTREAM = "http://127.0.0.1:4000"
        LISTEN_HOST = "127.0.0.1"
        LISTEN_PORT = 4001


        def fixup_messages(body_bytes: bytes) -> bytes:
            """Strip text blocks from assistant messages that also have tool_use.

            Anthropic format permits an assistant turn whose content is
            [text, tool_use]. LiteLLM's responses-API converter then misorders
            the resulting items and the downstream upstream rejects with
            "tool_use ids without tool_result blocks immediately after". We
            keep tool_use, drop text, on the way out — the user already saw
            the streamed text on the way in.
            """
            try:
                body = json.loads(body_bytes)
            except json.JSONDecodeError:
                return body_bytes

            messages = body.get("messages")
            if not isinstance(messages, list):
                return body_bytes

            mutated = False
            for m in messages:
                if not isinstance(m, dict) or m.get("role") != "assistant":
                    continue
                content = m.get("content")
                if not isinstance(content, list):
                    continue
                types = {b.get("type") for b in content if isinstance(b, dict)}
                if "tool_use" in types and "text" in types:
                    m["content"] = [
                        b for b in content
                        if not (isinstance(b, dict) and b.get("type") == "text")
                    ]
                    mutated = True

            if not mutated:
                return body_bytes
            return json.dumps(body).encode("utf-8")


        async def handle(request: web.Request) -> web.StreamResponse:
            body = await request.read()

            if request.path == "/v1/messages" and body:
                new_body = fixup_messages(body)
                if new_body is not body:
                    body = new_body

            url = UPSTREAM + request.path_qs
            headers = dict(request.headers)
            headers.pop("Host", None)
            headers["Content-Length"] = str(len(body))

            async with ClientSession() as sess:
                async with sess.request(
                    request.method,
                    url,
                    headers=headers,
                    data=body,
                    allow_redirects=False,
                ) as upstream:
                    # Drop hop-by-hop headers; aiohttp would object to
                    # Content-Length on a chunked response.
                    resp_headers = {
                        k: v for k, v in upstream.headers.items()
                        if k.lower() not in (
                            "transfer-encoding",
                            "content-encoding",
                            "content-length",
                            "connection",
                        )
                    }
                    resp = web.StreamResponse(
                        status=upstream.status, headers=resp_headers
                    )
                    await resp.prepare(request)
                    async for chunk in upstream.content.iter_any():
                        await resp.write(chunk)
                    await resp.write_eof()
                    return resp


        async def main() -> None:
            app = web.Application(client_max_size=128 * 1024 * 1024)
            app.router.add_route("*", "/{path:.*}", handle)
            runner = web.AppRunner(app)
            await runner.setup()
            site = web.TCPSite(runner, LISTEN_HOST, LISTEN_PORT)
            await site.start()
            print(
                f"litellm-anthropic-fixup listening on "
                f"{LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}",
                file=sys.stderr,
                flush=True,
            )
            while True:
                await asyncio.sleep(3600)


        if __name__ == "__main__":
            asyncio.run(main())
      '';
in
{
  options.services.litellm-anthropic-fixup = {
    enable = lib.mkEnableOption "the LiteLLM Anthropic /v1/messages fixup proxy";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.litellm-anthropic-fixup = {
      description = "LiteLLM Anthropic /v1/messages preprocessing proxy";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "exec";
        ExecStart = "${proxyScript}";
        Restart = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
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
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryMax = "256M";
      };
    };
  };
}
