#!/usr/bin/env python3
"""End-to-end Hermes chat completion probe.

Exercises the exact code path a real Discord conversation takes:
  - POSTs to the Hermes Agent api_server at http://10.99.1.2:8080
  - Uses Authorization: Bearer <API_SERVER_KEY>
  - Sends a deterministic prompt that requires the model to actually
    generate the token "ROVER" (case-insensitive)
  - Validates HTTP 200 AND response body contains the token

Emits four gauges to /var/lib/prometheus-node-exporter-textfiles/:
  hermes_e2e_chat_ok                              1 if both HTTP and content checks passed
  hermes_e2e_chat_http_code                       HTTP status of the request
  hermes_e2e_chat_duration_seconds                Wall-clock seconds for the round-trip
  hermes_e2e_chat_response_bytes                  Response body length in bytes
  hermes_e2e_chat_last_run_timestamp_seconds      When the probe last ran

Why this complements openclaw_hermes_smoke:
  The smoke probe goes through the MCP `ask_hermes` tool, which on this
  host returns a fixed 185-byte canned reply that does NOT exercise the
  Hermes Agent → LiteLLM → MLX backend path. The 2026-05-24 incident
  proved this: smoke greened up while the actual Discord chat path
  returned HTTP 401 from openrouter.ai because the model.base_url
  override was missing from the streaming-off code path.

  This probe sends a chat completion through the same api_server
  endpoint Discord uses, so any future routing/auth regression in the
  main chat path shows up within one probe interval.
"""

from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERMES_URL = os.environ.get(
    "HERMES_E2E_CHAT_URL", "http://10.99.1.2:8080/v1/chat/completions"
)
MODEL = os.environ.get("HERMES_E2E_CHAT_MODEL", "hera/omlx/Qwen3.6-27B-MLX-8bit")
EXPECTED_TOKEN = os.environ.get("HERMES_E2E_CHAT_TOKEN", "ROVER")
PROMPT = os.environ.get(
    "HERMES_E2E_CHAT_PROMPT",
    f"Reply with the single word {EXPECTED_TOKEN} and nothing else.",
)
TIMEOUT_SECONDS = float(os.environ.get("HERMES_E2E_CHAT_TIMEOUT", "90"))
METRIC_PATH = os.environ.get(
    "HERMES_E2E_CHAT_METRIC_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/hermes_e2e_chat.prom",
)


@dataclasses.dataclass
class ProbeResult:
    ok: bool
    http_code: int
    duration_seconds: float
    response_bytes: int
    timestamp: float


def run_probe() -> ProbeResult:
    api_key = os.environ.get("API_SERVER_KEY", "").strip()
    if not api_key:
        # No key → can't probe. Emit ok=0 with http_code=0 so the alert
        # fires and the user gets paged about the misconfig.
        return ProbeResult(
            ok=False, http_code=0, duration_seconds=0.0, response_bytes=0,
            timestamp=time.time(),
        )

    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        # Cap output — we only need ~10 tokens to verify EXPECTED_TOKEN.
        # Smaller cap = lower probe cost. Hermes' default is much larger.
        "max_tokens": 32,
        # Force non-streaming (Hermes config also sets this) so we
        # exercise the same path Discord uses.
        "stream": False,
    }).encode("utf-8")

    req = urllib.request.Request(
        HERMES_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    start = time.monotonic()
    timestamp = time.time()
    http_code = 0
    response_bytes = 0
    ok = False

    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            http_code = resp.status
            payload = resp.read()
            response_bytes = len(payload)
            if http_code == 200:
                try:
                    obj = json.loads(payload)
                    content = (
                        obj.get("choices", [{}])[0]
                        .get("message", {})
                        .get("content", "")
                    )
                    if EXPECTED_TOKEN.lower() in str(content).lower():
                        ok = True
                except (json.JSONDecodeError, IndexError, AttributeError):
                    ok = False
    except urllib.error.HTTPError as exc:
        http_code = exc.code
        try:
            response_bytes = len(exc.read() or b"")
        except Exception:
            response_bytes = 0
    except (urllib.error.URLError, TimeoutError, OSError):
        http_code = 0
    except Exception:
        http_code = 0

    duration_seconds = time.monotonic() - start

    return ProbeResult(
        ok=ok,
        http_code=http_code,
        duration_seconds=round(duration_seconds, 3),
        response_bytes=response_bytes,
        timestamp=timestamp,
    )


def write_metrics(result: ProbeResult, target: str = METRIC_PATH) -> None:
    lines = [
        "# HELP hermes_e2e_chat_ok 1 if the end-to-end chat probe returned HTTP 200 and contained the expected token",
        "# TYPE hermes_e2e_chat_ok gauge",
        f"hermes_e2e_chat_ok {1 if result.ok else 0}",
        "# HELP hermes_e2e_chat_http_code Last HTTP status code from the probe (0 on connection error)",
        "# TYPE hermes_e2e_chat_http_code gauge",
        f"hermes_e2e_chat_http_code {result.http_code}",
        "# HELP hermes_e2e_chat_duration_seconds Wall-clock seconds for the chat round-trip",
        "# TYPE hermes_e2e_chat_duration_seconds gauge",
        f"hermes_e2e_chat_duration_seconds {result.duration_seconds}",
        "# HELP hermes_e2e_chat_response_bytes Length of the chat response body in bytes",
        "# TYPE hermes_e2e_chat_response_bytes gauge",
        f"hermes_e2e_chat_response_bytes {result.response_bytes}",
        "# HELP hermes_e2e_chat_last_run_timestamp_seconds When the probe last ran (Unix epoch)",
        "# TYPE hermes_e2e_chat_last_run_timestamp_seconds gauge",
        f"hermes_e2e_chat_last_run_timestamp_seconds {result.timestamp}",
        "",
    ]
    target_path = pathlib.Path(target)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    # Atomic write via tempfile + rename so node_exporter never sees half-written file
    with tempfile.NamedTemporaryFile(
        mode="w", dir=str(target_path.parent), delete=False, suffix=".tmp"
    ) as tmp:
        tmp.write("\n".join(lines))
        tmp_path = tmp.name
    # node-exporter runs as `node-exporter` user; need world-readable
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, target_path)


def main() -> int:
    result = run_probe()
    write_metrics(result)
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
