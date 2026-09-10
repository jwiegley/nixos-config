"""Probe the LLM gateway that every Hermes tool depends on.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add
one here or flake8 flags it as E265.

WHY THIS EXISTS. On 2026-09-09 an org-mode lookup through Hermes failed with a 502
and NOTHING alerted. Hermes' own health check reported api_server_ok=1 the whole
time, correctly by its own definition: all 21 hermes_* metrics ask "is Hermes up?"
-- api server, Discord heartbeat, extract worker, memory/Qdrant, VM uptime -- and
none of them ask "does a tool call work?".

The failing path is longer than it looks:

    Hermes -> org-db (stdio MCP) -> org_search -> `org db search`
           -> LLM gateway :4000 -> hera's embedding model

org_sql reaches PostgreSQL directly, but org_search makes an HTTP call to the
gateway for embeddings, so a gateway with no live upstream surfaces to the user as
a 502. Checked at the time: no blackbox target touched :4000, embeddings were not
probed at all, and the only reference to the gateway in any alert was advice TEXT
inside a rule about the self-heal daemon -- which fires only when self-heal happens
to be escalating, not when a user's tool call fails.

That is a whole dependency tier, on another host, feeding all eight of Hermes' MCP
servers, with no coverage.

WHAT IS PROBED, and why each one:

  * GET /v1/models -- reachability. The cheapest possible "is the relay answering".

  * POST /v1/embeddings -- THE PATH THAT ACTUALLY BROKE. Reachability alone would
    not have caught it: the gateway process can be answering /v1/models from its
    own memory while having no live upstream for an actual inference request. This
    is the difference between the check that existed and the check that was needed.

  * Configured-model-is-served, per role. models.json names a model per role; the
    gateway serves whatever hera has loaded. A rename or a retired model on either
    side breaks every caller silently, and comparing the two catches it before a
    human does. This is cheap -- it reuses the /v1/models response.

DELIBERATELY NOT a completions probe. Generating tokens costs real GPU time on a
shared host, and today's incidents showed that host is contention-sensitive; an
embeddings call on a three-character input is a few milliseconds of work and
exercises the same relay-to-upstream path.
"""

import json
import os
import time
import urllib.error
import urllib.request

TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
OUT = os.path.join(TEXTFILE_DIR, "llm_gateway.prom")

GATEWAY = os.environ.get("LLM_GATEWAY_URL", "http://127.0.0.1:4000")
MODELS_JSON = os.environ.get("LLM_MODELS_JSON", "/etc/models.json")

# Bounded so a wedged gateway cannot pin the unit. /v1/models is served from the
# gateway's own state and should be instant; embeddings crosses to hera, which has
# been observed slow under load, so it gets more room.
MODELS_TIMEOUT_S = 15
EMBED_TIMEOUT_S = 60


def _get_json(url, timeout, payload=None):
    """Return (ok, parsed_or_None, seconds, detail)."""
    started = time.monotonic()
    req = urllib.request.Request(
        url,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="GET" if payload is None else "POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
        return True, json.loads(body), time.monotonic() - started, ""
    except urllib.error.HTTPError as e:
        # Surface the body. The 502 that prompted this exporter was diagnosed only
        # after someone read an upstream error body by hand; a status code alone
        # says nothing about which side failed.
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:200]
        except Exception:
            pass
        return False, None, time.monotonic() - started, f"HTTP {e.code} {detail}"
    except Exception as e:
        return False, None, time.monotonic() - started, repr(e)[:200]


def _configured_models():
    """Role -> model name, from models.json. Empty dict if unreadable."""
    try:
        with open(MODELS_JSON) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    llm = data.get("llm", {})
    for role in ("primary", "fast", "reasoning"):
        v = llm.get(role)
        if isinstance(v, dict) and v.get("name"):
            out[role] = v["name"]
    emb = data.get("embedding", {}).get("primary")
    if isinstance(emb, dict) and emb.get("name"):
        out["embedding"] = emb["name"]
    elif isinstance(emb, str):
        out["embedding"] = emb
    return out


def main():
    lines = []
    roles = _configured_models()

    ok, models, models_s, models_detail = _get_json(
        f"{GATEWAY}/v1/models", MODELS_TIMEOUT_S)
    served = set()
    if ok and isinstance(models, dict):
        served = {m.get("id") for m in models.get("data", []) if m.get("id")}

    # Embeddings against the CONFIGURED embedding model, which is what org_search
    # uses. Probing some other model would test a path nothing depends on.
    embed_model = roles.get("embedding")
    if embed_model:
        e_ok, e_body, embed_s, embed_detail = _get_json(
            f"{GATEWAY}/v1/embeddings", EMBED_TIMEOUT_S,
            payload={"model": embed_model, "input": "ok"})
        # A 200 with no vector is a failure too -- guard against a relay that
        # answers politely with nothing, which is exactly how a silent-green
        # dependency looks.
        if e_ok:
            try:
                e_ok = len(e_body["data"][0]["embedding"]) > 0  # type: ignore[index]
                if not e_ok:
                    embed_detail = "200 but empty embedding vector"
            except (KeyError, IndexError, TypeError):
                e_ok = False
                embed_detail = "200 but unparseable embedding response"
    else:
        e_ok, embed_s, embed_detail = False, 0.0, "no embedding model in models.json"

    lines += [
        "# HELP llm_gateway_reachable 1 if GET /v1/models answered, 0 otherwise",
        "# TYPE llm_gateway_reachable gauge",
        f"llm_gateway_reachable {1 if ok else 0}",
        "",
        "# HELP llm_gateway_models_probe_seconds Wall time of the /v1/models call",
        "# TYPE llm_gateway_models_probe_seconds gauge",
        f"llm_gateway_models_probe_seconds {models_s:.3f}",
        "",
        "# HELP llm_gateway_models_served Number of models the gateway advertises",
        "# TYPE llm_gateway_models_served gauge",
        f"llm_gateway_models_served {len(served)}",
        "",
        "# HELP llm_gateway_embeddings_ok 1 if a real embedding vector came back "
        "for the configured embedding model (the path org_search uses), 0 otherwise",
        "# TYPE llm_gateway_embeddings_ok gauge",
        f"llm_gateway_embeddings_ok {1 if e_ok else 0}",
        "",
        "# HELP llm_gateway_embeddings_probe_seconds Wall time of the embeddings call",
        "# TYPE llm_gateway_embeddings_probe_seconds gauge",
        f"llm_gateway_embeddings_probe_seconds {embed_s:.3f}",
        "",
        "# HELP llm_gateway_configured_model_served 1 if the model models.json names "
        "for this role is advertised by the gateway, 0 if it is missing",
        "# TYPE llm_gateway_configured_model_served gauge",
    ]
    for role, name in sorted(roles.items()):
        # Label the ROLE only, never the model name: names carry no secret but the
        # role is the stable thing to alert on, and a renamed model would otherwise
        # silently create a new series instead of flipping the old one to 0.
        lines.append(
            f'llm_gateway_configured_model_served{{role="{role}"}} '
            f"{1 if name in served else 0}")

    lines += [
        "",
        "# HELP llm_gateway_run_timestamp_seconds Unix time of the last run "
        "(collector liveness)",
        "# TYPE llm_gateway_run_timestamp_seconds gauge",
        f"llm_gateway_run_timestamp_seconds {time.time():.0f}",
        "",
    ]

    # Details go to stderr for the journal, never into the metrics: an upstream
    # error body is free-form third-party text.
    if not ok:
        print(f"llm-gateway: /v1/models failed: {models_detail}", flush=True)
    if not e_ok:
        print(f"llm-gateway: embeddings failed: {embed_detail}", flush=True)

    tmp = f"{OUT}.{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
