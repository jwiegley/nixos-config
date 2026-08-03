# Vane LLM shim -- forces non-thinking chat completions for Vane only.
#
# WHY THIS EXISTS
#
# Vane (Perplexica) asks its LLM to rephrase the user's question into a standalone
# web search query, expecting a terse string back. The reasoning model it uses,
# DeepSeek-V4-Flash, emits its chain of thought as ORDINARY CONTENT -- no <think>
# tags, no reasoning_content field -- so Perplexica receives
#
#   "1.  The user asks to rephrase ... 2.  The instruction says ..."
#
# fails to parse a query out of it, and then NEVER CALLS SEARXNG AT ALL. Diagnosed
# 2026-08-03: uwsgi logged 16 lines for a hand-issued searxng query and ZERO for a
# Vane query in the same window, while the Vane container could reach searxng fine
# (node fetch -> 200). User-visible symptom: Vane answers "Hmm, sorry I could not
# find any relevant information on this topic" with 0 sources.
#
# The model can be told to skip thinking, but ONLY via a nested key. Verified against
# the live gateway:
#
#   {"enable_thinking": false}                           -> ignored, still monologues
#   {"chat_template_kwargs": {"enable_thinking": false}} -> "NixOS Linux distribution
#                                                            features reproducibility
#                                                            declarative configuration"
#
# Perplexica cannot send it -- its openai provider config accepts only name, apiKey
# and baseURL. Three alternatives were rejected:
#   * inject at the nginx gateway: this nginx has no njs/lua, so it cannot rewrite a
#     JSON body;
#   * inject globally at the gateway: Hermes shares :4000 and WANTS thinking;
#   * patch Perplexica: mutable container state, reverts on image update -- the same
#     trap as the versatile_thermostat patch.
#
# So: a per-consumer shim, modelled directly on qdrant-inference-bridge (same shape --
# a tiny python HTTP proxy that rewrites a request body and forwards to :4000).
#
# Holds NO credentials: the nginx gateway injects the upstream Authorization header
# itself, so this forwards whatever placeholder Vane sends.
{
  pkgs,
  ...
}:

let
  shimPort = 4001;
  # The gateway, deliberately, not hera directly -- so the gateway keeps owning auth
  # and TLS and this stays a body rewriter with no secrets.
  upstreamBase = "http://127.0.0.1:4000/v1";

  shimScript = pkgs.writeScript "vane-llm-shim.py" ''
    #!${pkgs.python3}/bin/python3
    """OpenAI-compatible passthrough that forces non-thinking chat completions.

    Two behaviours only:
      1. On /chat/completions, merge chat_template_kwargs.enable_thinking = false
         into the JSON body. A value already present is LEFT ALONE, so a caller that
         deliberately wants thinking can still ask for it.
      2. Everything else (/models, /embeddings, ...) is forwarded untouched.

    Streaming is passed through chunk by chunk rather than buffered: Perplexica
    streams chat completions, and buffering would hold a whole answer until it
    completed, turning a working setup into an apparent hang.
    """
    import json
    import sys
    import urllib.error
    import urllib.request
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    UPSTREAM_BASE = "${upstreamBase}"
    LISTEN_HOST = "127.0.0.1"
    LISTEN_PORT = ${toString shimPort}

    # Generous: a reasoning model behind a cold MLX load can take minutes, and this
    # shim must never be the component that gives up first. Perplexica keeps its own
    # shorter budget.
    UPSTREAM_TIMEOUT = 900

    # Hop-by-hop headers must not be forwarded (RFC 7230 6.1). Content-Length is
    # dropped because injection changes the body length.
    SKIP_REQUEST_HEADERS = {
        "host", "content-length", "connection", "keep-alive",
        "transfer-encoding", "upgrade", "proxy-authorization", "te", "trailer",
    }
    SKIP_RESPONSE_HEADERS = {
        "connection", "keep-alive", "transfer-encoding", "upgrade", "trailer",
        "content-length",
    }


    def log(msg):
        print(msg, file=sys.stderr, flush=True)


    def inject_no_thinking(raw):
        """Return body bytes with chat_template_kwargs.enable_thinking=false.

        On ANY parse failure the original bytes are returned unchanged. A shim that
        mangles a body it does not understand is worse than one that does nothing,
        and the upstream is better placed to reject a malformed request.
        """
        try:
            payload = json.loads(raw)
        except Exception:
            log("shim: body is not JSON, forwarding unchanged")
            return raw
        if not isinstance(payload, dict):
            return raw

        ctk = payload.get("chat_template_kwargs")
        if not isinstance(ctk, dict):
            ctk = {}
        # setdefault, NOT assignment: an explicit caller choice wins.
        ctk.setdefault("enable_thinking", False)
        payload["chat_template_kwargs"] = ctk
        return json.dumps(payload).encode("utf-8")


    class ShimHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "vane-llm-shim/1.0"

        def log_message(self, fmt, *args):
            pass  # journald already timestamps; an access log here is pure noise

        def _forward(self, method):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None

            path = self.path
            if body and path.endswith("/chat/completions"):
                body = inject_no_thinking(body)

            # Keep whatever follows /v1 and graft it onto the upstream base.
            suffix = path.split("/v1", 1)[1] if "/v1" in path else path
            url = UPSTREAM_BASE + suffix

            headers = {
                k: v for k, v in self.headers.items()
                if k.lower() not in SKIP_REQUEST_HEADERS
            }
            if body is not None:
                headers["Content-Length"] = str(len(body))

            req = urllib.request.Request(url, data=body, headers=headers, method=method)
            try:
                resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
            except urllib.error.HTTPError as exc:
                # Pass the upstream's own error through verbatim -- Perplexica shows
                # more useful diagnostics that way than from a synthesised 502.
                payload = exc.read()
                self.send_response(exc.code)
                self.send_header(
                    "Content-Type", exc.headers.get("Content-Type", "application/json")
                )
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            except Exception as exc:
                payload = json.dumps({
                    "error": {
                        "message": "vane-llm-shim: upstream unreachable: " + str(exc),
                        "type": "upstream_error",
                    }
                }).encode("utf-8")
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            with resp:
                ctype = resp.headers.get("Content-Type", "")
                is_stream = "text/event-stream" in ctype.lower()

                if not is_stream:
                    # Buffer and send a real Content-Length.
                    #
                    # Do NOT re-chunk non-streaming replies. The first version of
                    # this shim set Transfer-Encoding: chunked unconditionally, and
                    # Perplexica's HTTP client closed the connection mid-write --
                    # the shim died with BrokenPipeError and Vane surfaced a 502
                    # after ~5s, even though the same request via curl worked. A
                    # plain JSON completion is small, so buffering costs nothing and
                    # keeps the response byte-for-byte conventional.
                    payload = resp.read()
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        if k.lower() not in SKIP_RESPONSE_HEADERS:
                            self.send_header(k, v)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    self.wfile.flush()
                    return

                # Streaming (SSE): chunked is required, since the length is not
                # known up front. Read in small blocks so tokens are relayed as
                # they arrive rather than in 8KB batches.
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in SKIP_RESPONSE_HEADERS:
                        self.send_header(k, v)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                try:
                    while True:
                        chunk = resp.read1(1024) if hasattr(resp, "read1") else resp.read(1024)
                        if not chunk:
                            break
                        self.wfile.write(
                            format(len(chunk), "X").encode() + b"\r\n" + chunk + b"\r\n"
                        )
                        self.wfile.flush()
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    # The client hung up mid-stream. Normal when a user cancels;
                    # not worth a traceback in the journal.
                    log("shim: client disconnected during stream")

        def do_POST(self):
            self._forward("POST")

        def do_GET(self):
            self._forward("GET")


    def main():
        server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ShimHandler)
        log("vane-llm-shim listening on " + LISTEN_HOST + ":" + str(LISTEN_PORT)
            + " -> " + UPSTREAM_BASE)
        server.serve_forever()


    if __name__ == "__main__":
        main()
  '';
in
{
  systemd.services.vane-llm-shim = {
    description = "Vane LLM shim (forces chat_template_kwargs.enable_thinking=false)";
    after = [
      "network.target"
      "nginx.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${shimScript}";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      # Loopback only. It carries no credentials but also has no auth of its own, so
      # it must never be reachable off-host.
      IPAddressAllow = "127.0.0.1/32";
      IPAddressDeny = "any";
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts = [
    shimPort # Vane LLM shim
  ];
}
