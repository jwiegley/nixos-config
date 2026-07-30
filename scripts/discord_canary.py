#!/usr/bin/env python3
"""Discord round-trip canary (direction-agnostic).

Actively verifies the ONE leg no other probe exercises for a Discord agent:
the inbound MESSAGE_CREATE -> agent dispatch -> reply pipeline. Posts an
`@target <nonce>` message to a dedicated channel *as one bot* and verifies
the *target bot* replies.

Wired as a mutually-probing pair (2026-07-15, replacing the dedicated
probe-bot design):
  - OpenClaw's @Claw probes Hermes   -> metric hermes_discord_canary_*
  - Hermes probes OpenClaw's @Claw   -> metric openclaw_discord_canary_*
Blind spot (accepted): if BOTH gateways die at once, neither probe reports.

LIVE since 2026-07-30 in #interconnect, and BOTH directions have gone green:
  - hermes_discord_canary  (tests Hermes)   first green 12:01, rt=6.773s. Its only
    defect was a dead timer, NOT a missing allowlist entry.
  - openclaw_discord_canary (tests OpenClaw) first green 12:46, rt=7.437s, once
    Hermes was added to @Claw's channels.discord.allowFrom.

REPLY LATENCY IS THE SUBTLE PART, and it shaped both the timeout and the alerts.
These targets are LLM agents, so a reply takes anywhere from ~3s to ~90s (measured:
3.5, 6.8, 7.4, 30.2, 85.3, 87.8). The original 90s timeout therefore scored healthy
slow replies as dead round-trips, which produced a confidently wrong diagnosis
before the pattern was visible. timeoutSeconds is now 180.

Worse, the agents answer only about HALF their mentions, so ok flips between 1 and 0
run to run. Alerting on that directly (`ok == 0 for: 15m`) pages on any two
consecutive misses, so the *DiscordCanaryDown rules key on the AGE of
last_success_timestamp_seconds instead -- monotonic, so it cannot oscillate -- and
*DiscordCanaryDegraded reports the success RATE. See
modules/monitoring/alerts/openclaw.yaml, which also records why a canary-down alert
must NOT auto-restart the VM.

Why this is needed (2026-07-15 incident):
  Hermes' Discord connection zombied — the WebSocket stayed "connected" and
  kept ACKing heartbeats / RESUMEing, but MESSAGE_CREATE events stopped
  reaching the agent, so it silently answered nobody for hours. Every
  existing probe missed it: e2e-chat hits the api_server directly,
  ask_hermes uses MCP, and HermesDiscordZombieSuspected keys off gateway.log
  event age (heartbeat/RESUME) which a still-ACKing zombie keeps fresh. Only
  an active message->reply round-trip proves the inbound path delivers.

Emits (NAME = $CANARY_METRIC_NAME, e.g. hermes_discord_canary):
  {NAME}_ok                          1 if the target replied within the timeout
  {NAME}_roundtrip_seconds           seconds from post to observed reply (0 on failure)
  {NAME}_post_http_code              HTTP status of the message POST (0 on connection error)
  {NAME}_last_run_timestamp_seconds  when the probe last ran (Unix epoch)
  {NAME}_last_success_timestamp_seconds  when it last succeeded (carried forward on failure)

Config (environment; see the systemd unit):
  Token, first of:  CANARY_BOT_TOKEN | CANARY_BOT_TOKEN_FILE (raw token file) | DISCORD_BOT_TOKEN
  CANARY_CHANNEL_ID        channel snowflake for the probe conversation
  CANARY_TARGET_USER_ID    the target bot's user id (to recognise its reply)
  CANARY_TARGET_NAME       display name for the mention/log (cosmetic)
  CANARY_METRIC_NAME       metric base name (default "discord_canary")
  CANARY_METRIC_PATH       textfile path (default derived from CANARY_METRIC_NAME)

Pure stdlib (urllib) — no external deps, same as hermes_e2e_chat_probe.py.
"""

from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import re
import secrets
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = "https://discord.com/api/v10"


def _load_token() -> str:
    tok = os.environ.get("CANARY_BOT_TOKEN", "").strip()
    if tok:
        return tok
    path = os.environ.get("CANARY_BOT_TOKEN_FILE", "").strip()
    if path:
        try:
            return pathlib.Path(path).read_text().strip()
        except OSError:
            return ""
    # Fallback: hermes/env EnvironmentFile exposes DISCORD_BOT_TOKEN directly.
    return os.environ.get("DISCORD_BOT_TOKEN", "").strip()


BOT_TOKEN = _load_token()
CHANNEL_ID = os.environ.get("CANARY_CHANNEL_ID", "")
TARGET_USER_ID = os.environ.get("CANARY_TARGET_USER_ID", "")
TARGET_NAME = os.environ.get("CANARY_TARGET_NAME", "the target bot")
METRIC_NAME = os.environ.get("CANARY_METRIC_NAME", "discord_canary")

REPLY_TIMEOUT_SECONDS = float(os.environ.get("CANARY_TIMEOUT", "90"))
POLL_INTERVAL_SECONDS = float(os.environ.get("CANARY_POLL_INTERVAL", "3"))
RETRIES = int(os.environ.get("CANARY_RETRIES", "1"))
RETRY_DELAY_SECONDS = float(os.environ.get("CANARY_RETRY_DELAY", "5"))

METRIC_PATH = os.environ.get(
    "CANARY_METRIC_PATH",
    f"/var/lib/prometheus-node-exporter-textfiles/{METRIC_NAME}.prom",
)

USER_AGENT = "DiscordBot (https://vulcan.lan/discord-canary, 1.0)"


@dataclasses.dataclass
class ProbeResult:
    ok: bool = False
    roundtrip_seconds: float = 0.0
    post_http_code: int = 0
    timestamp: float = 0.0
    detail: str = ""
    # Messages this run failed to delete. Deleting our OWN probe needs no permission, but
    # deleting the TARGET's reply needs MANAGE_MESSAGES. Cleanup used to be fire-and-forget,
    # so without that permission the channel silently accumulated ~576 replies/day with no
    # signal anywhere. The operator granted a dedicated channel on the explicit condition
    # that it stays clean, so "we could not clean up" has to be observable, not ignored.
    cleanup_failed: int = 0


def _request(method: str, path: str, body: dict | None = None) -> tuple[int, object]:
    """One Discord REST call. Returns (http_code, parsed_json_or_None).

    Honors a single 429 rate-limit retry using the server's retry_after.
    Never raises for HTTP errors — returns the code so the caller decides.
    """
    url = f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(2):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bot {BOT_TOKEN}")
        req.add_header("User-Agent", USER_AGENT)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                raw = resp.read()
                parsed = json.loads(raw) if raw else None
                return resp.status, parsed
        except urllib.error.HTTPError as exc:
            if exc.code == 429 and attempt == 0:
                try:
                    payload = json.loads(exc.read() or b"{}")
                    wait = float(payload.get("retry_after", 1.0))
                except Exception:
                    wait = 1.0
                time.sleep(min(wait, 10.0) + 0.1)
                continue
            return exc.code, None
        except (urllib.error.URLError, TimeoutError, OSError):
            return 0, None
    return 0, None


def run_probe() -> ProbeResult:
    now = time.time()
    result = ProbeResult(timestamp=now)

    if not (BOT_TOKEN and CHANNEL_ID and TARGET_USER_ID):
        result.detail = "missing config (token/channel/target-user-id)"
        return result

    nonce = secrets.token_hex(4)
    content = f"<@{TARGET_USER_ID}> canary {nonce} — reply with `CANARY OK {nonce}`"

    start = time.monotonic()
    code, posted = _request(
        "POST", f"/channels/{CHANNEL_ID}/messages", {"content": content}
    )
    result.post_http_code = code
    if code != 200 or not isinstance(posted, dict):
        result.detail = f"post failed http={code}"
        return result

    posted_id = posted.get("id", "")

    deadline = start + REPLY_TIMEOUT_SECONDS
    reply_id = ""
    while time.monotonic() < deadline:
        time.sleep(POLL_INTERVAL_SECONDS)
        code, msgs = _request(
            "GET", f"/channels/{CHANNEL_ID}/messages?after={posted_id}&limit=25"
        )
        if code == 200 and isinstance(msgs, list):
            for m in msgs:
                author = (m.get("author") or {}).get("id", "")
                if author == str(TARGET_USER_ID):
                    result.ok = True
                    result.roundtrip_seconds = round(time.monotonic() - start, 3)
                    reply_id = m.get("id", "")
                    # nonce echo is a bonus signal, not required — any reply
                    # from the target in this dedicated channel proves routing.
                    result.detail = "reply+nonce" if nonce in (m.get("content") or "") else "reply"
                    break
        if result.ok:
            break

    if not result.ok:
        result.detail = "no reply within timeout"

    # Cleanup so the channel doesn't accumulate probe chatter. Deleting our own message
    # needs no special permission; deleting the target's reply needs MANAGE_MESSAGES.
    # Failures no longer pass silently -- they are counted and exported, because an
    # undetected cleanup failure turns this canary into a channel-spammer.
    # 204 = deleted, 404 = already gone (both fine). Anything else, notably 403 Forbidden
    # for a missing MANAGE_MESSAGES, is a real failure.
    for mid in (posted_id, reply_id):
        if mid:
            code, _ = _request("DELETE", f"/channels/{CHANNEL_ID}/messages/{mid}")
            if code not in (204, 404):
                result.cleanup_failed += 1
                print(
                    f"canary cleanup FAILED for message in channel (http {code}); "
                    "the bot likely lacks MANAGE_MESSAGES, so replies will accumulate",
                    file=sys.stderr,
                )

    return result


def _read_last_success(target: str) -> float:
    """Carry forward last-success across failing runs so the staleness alert
    measures 'time since it actually worked', not 'time since last run'."""
    try:
        txt = pathlib.Path(target).read_text()
    except OSError:
        return 0.0
    m = re.search(
        rf"^{re.escape(METRIC_NAME)}_last_success_timestamp_seconds\s+([0-9.]+)",
        txt,
        re.MULTILINE,
    )
    return float(m.group(1)) if m else 0.0


def write_metrics(result: ProbeResult, target: str = METRIC_PATH) -> None:
    last_success = result.timestamp if result.ok else _read_last_success(target)
    n = METRIC_NAME
    lines = [
        f"# HELP {n}_ok 1 if the target bot replied to a probe @mention within the timeout",
        f"# TYPE {n}_ok gauge",
        f"{n}_ok {1 if result.ok else 0}",
        f"# HELP {n}_roundtrip_seconds Seconds from probe post to observed reply (0 on failure)",
        f"# TYPE {n}_roundtrip_seconds gauge",
        f"{n}_roundtrip_seconds {result.roundtrip_seconds}",
        f"# HELP {n}_post_http_code HTTP status of the probe message POST (0 on connection error)",
        f"# TYPE {n}_post_http_code gauge",
        f"{n}_post_http_code {result.post_http_code}",
        f"# HELP {n}_last_run_timestamp_seconds When the canary last ran (Unix epoch)",
        f"# TYPE {n}_last_run_timestamp_seconds gauge",
        f"{n}_last_run_timestamp_seconds {result.timestamp}",
        f"# HELP {n}_cleanup_failed Messages this run could not delete (non-zero means the channel is accumulating)",
        f"# TYPE {n}_cleanup_failed gauge",
        f"{n}_cleanup_failed {result.cleanup_failed}",
        f"# HELP {n}_last_success_timestamp_seconds When the canary last succeeded (Unix epoch, carried forward)",
        f"# TYPE {n}_last_success_timestamp_seconds gauge",
        f"{n}_last_success_timestamp_seconds {last_success}",
        "",
    ]
    target_path = pathlib.Path(target)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", dir=str(target_path.parent), delete=False, suffix=".tmp"
    ) as tmp:
        tmp.write("\n".join(lines))
        tmp_path = tmp.name
    os.chmod(tmp_path, 0o644)  # node-exporter reads as its own user
    os.replace(tmp_path, target_path)


def main() -> int:
    result = run_probe()
    attempts = 1
    while not result.ok and attempts <= RETRIES:
        time.sleep(RETRY_DELAY_SECONDS)
        result = run_probe()
        attempts += 1
    write_metrics(result)
    print(
        f"{METRIC_NAME} ok={int(result.ok)} target={TARGET_NAME} "
        f"post_http={result.post_http_code} rt={result.roundtrip_seconds}s "
        f"detail={result.detail!r}",
        file=sys.stderr,
    )
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
