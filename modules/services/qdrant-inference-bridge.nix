{
  pkgs,
  ...
}:

let
  bridgePort = 6335;
  upstreamUrl = "http://hera.lan:8080/v1/embeddings";

  bridgeScript = pkgs.writeText "qdrant-inference-bridge.py" ''
    #!/usr/bin/env python3
    """
    Qdrant-to-OpenAI inference bridge.

    Qdrant's native inference protocol POSTs:
      {"inputs": [{"data": "...", "data_type": "text", "model": "bge-m3"}],
       "inference": "update", "token": "..."}

    This bridge translates that to OpenAI-compatible:
      {"model": "bge-m3", "input": ["..."]}
    and returns Qdrant's expected {"embeddings": [[...], ...]} format.
    """
    import json
    import logging
    import urllib.request
    import urllib.error
    from http.server import HTTPServer, BaseHTTPRequestHandler
    from itertools import groupby

    UPSTREAM_URL = "${upstreamUrl}"
    LISTEN_HOST = "127.0.0.1"
    LISTEN_PORT = ${toString bridgePort}

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    log = logging.getLogger(__name__)


    def embed(model: str, texts: list) -> tuple:
        payload = json.dumps({"model": model, "input": texts}).encode()
        req = urllib.request.Request(
            UPSTREAM_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
        embeddings = [
            item["embedding"]
            for item in sorted(data["data"], key=lambda x: x["index"])
        ]
        # Convert OpenAI usage {"prompt_tokens": N} to Qdrant usage {"models": {"model": {"tokens": N}}}
        oai_usage = data.get("usage") or {}
        tokens = oai_usage.get("prompt_tokens") or oai_usage.get("total_tokens") or 0
        qdrant_usage = {"models": {model: {"tokens": tokens}}} if tokens else None
        return embeddings, qdrant_usage


    class BridgeHandler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            log.info(fmt, *args)

        def send_json(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length))
            except Exception as e:
                self.send_json(400, {"error": f"Bad request: {e}"})
                return

            inputs = body.get("inputs", [])
            if not inputs:
                self.send_json(200, {"embeddings": [], "usage": None})
                return

            try:
                # Track original positions, group by model to batch calls
                indexed = list(enumerate(inputs))
                sorted_by_model = sorted(indexed, key=lambda x: x[1]["model"])

                result_embeddings = [None] * len(inputs)
                merged_models = {}

                for model, group in groupby(sorted_by_model, key=lambda x: x[1]["model"]):
                    group_list = list(group)
                    positions = [pos for pos, _ in group_list]
                    texts = [inp["data"] for _, inp in group_list]

                    embeddings, usage = embed(model, texts)

                    for pos, embedding in zip(positions, embeddings):
                        result_embeddings[pos] = embedding

                    if usage:
                        for m, mu in usage["models"].items():
                            merged_models.setdefault(m, {"tokens": 0})["tokens"] += mu["tokens"]

                combined_usage = {"models": merged_models} if merged_models else None

                self.send_json(200, {"embeddings": result_embeddings, "usage": combined_usage})

            except urllib.error.HTTPError as e:
                err_body = e.read().decode()
                log.error("Upstream error %s: %s", e.code, err_body)
                self.send_json(502, {"error": f"Upstream {e.code}: {err_body}"})
            except Exception as e:
                log.exception("Internal error")
                self.send_json(500, {"error": str(e)})


    if __name__ == "__main__":
        server = HTTPServer((LISTEN_HOST, LISTEN_PORT), BridgeHandler)
        log.info("Listening on %s:%d -> %s", LISTEN_HOST, LISTEN_PORT, UPSTREAM_URL)
        server.serve_forever()
  '';
in
{
  # ============================================================================
  # Qdrant Inference Bridge
  # ============================================================================
  # Translates Qdrant's native inference protocol to OpenAI-compatible
  # embeddings API so Qdrant can use local embedding models via llama-swap.
  # Qdrant -> bridge (127.0.0.1:6335) -> hera.lan:8080/v1/embeddings

  systemd.services.qdrant-inference-bridge = {
    description = "Qdrant-to-OpenAI inference bridge";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "qdrant.service"
    ];

    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${bridgeScript}";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts = [
    bridgePort # Qdrant inference bridge
  ];
}
