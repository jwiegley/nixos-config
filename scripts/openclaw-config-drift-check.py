#!/usr/bin/env python3
"""
OpenClaw config schema-drift detector.

Compares the live openclaw.json key set (read from the guest VM via
SSH) against the in-store openclaw-config-template's key set. Emits
Prometheus textfile metrics. Stdlib-only.

Pre-strips secret-named keys with the canonical regex before any byte
reaches stdout. The metric file contains only integer counts plus the
probe-up gauge — no key names, no values.
"""
from __future__ import annotations
import json
import os
import re
import subprocess
import sys
import time
from typing import Optional

SECRET_RE = re.compile(
    r"([Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Pp]assphrase"
    r"|[Ss]ecret|[Ss]ecretKey|[Pp]sk|[Bb]earer)"
)

GUEST_USER = "openclaw"
GUEST_ADDR = "10.99.0.2"
GUEST_CONFIG_PATH = "/var/lib/openclaw/.openclaw/openclaw.json"
TEMPLATE_PATH_ENV = "OPENCLAW_TEMPLATE_PATH"
SSH_KEY_PATH_ENV = "OPENCLAW_PROBE_SSH_KEY"
METRIC_PATH = (
    "/var/lib/prometheus-node-exporter-textfiles/"
    "openclaw_config_drift.prom"
)


def _strip_paths(buf: bytes) -> set[str]:
    """Walk JSON, return set of dotted paths with secret-named keys removed."""
    obj = json.loads(buf)

    def walk(o, prefix=""):
        if isinstance(o, dict):
            for k, v in o.items():
                if SECRET_RE.search(k):
                    continue
                path = f"{prefix}.{k}" if prefix else k
                yield path
                yield from walk(v, path)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                path = f"{prefix}.{i}"
                yield path
                yield from walk(v, path)

    return set(walk(obj))


def _read_template_keys() -> set[str]:
    path = os.environ.get(TEMPLATE_PATH_ENV)
    if not path:
        raise RuntimeError(f"{TEMPLATE_PATH_ENV} not set")
    with open(path, "rb") as f:
        return _strip_paths(f.read())


def _read_live_keys() -> Optional[set[str]]:
    """Returns None if SSH probe fails."""
    ssh_key = os.environ.get(SSH_KEY_PATH_ENV)
    if not ssh_key:
        print(f"{SSH_KEY_PATH_ENV} not set", file=sys.stderr)
        return None
    try:
        result = subprocess.run(
            [
                "ssh", "-i", ssh_key,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=10",
                f"{GUEST_USER}@{GUEST_ADDR}",
                f"cat {GUEST_CONFIG_PATH}",
            ],
            capture_output=True, timeout=30, check=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"SSH probe failed: {e}", file=sys.stderr)
        return None
    return _strip_paths(result.stdout)


def write_metrics(probe_up: bool, added: int, removed: int) -> None:
    lines = [
        "# HELP openclaw_config_drift_probe_up 1 if the SSH probe succeeded",
        "# TYPE openclaw_config_drift_probe_up gauge",
        f"openclaw_config_drift_probe_up {1 if probe_up else 0}",
        "# HELP openclaw_config_drift_keys_added Number of keys present in live config but not in Nix template",
        "# TYPE openclaw_config_drift_keys_added gauge",
        f"openclaw_config_drift_keys_added {added}",
        "# HELP openclaw_config_drift_keys_removed Number of keys present in Nix template but not in live config",
        "# TYPE openclaw_config_drift_keys_removed gauge",
        f"openclaw_config_drift_keys_removed {removed}",
        "# HELP openclaw_config_drift_last_run_timestamp_seconds When the drift check last ran",
        "# TYPE openclaw_config_drift_last_run_timestamp_seconds gauge",
        f"openclaw_config_drift_last_run_timestamp_seconds {time.time()}",
        "",
    ]
    tmp = METRIC_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.rename(tmp, METRIC_PATH)


def main() -> int:
    try:
        template_keys = _read_template_keys()
    except (FileNotFoundError, json.JSONDecodeError, RuntimeError) as e:
        print(f"template read failed: {e}", file=sys.stderr)
        write_metrics(probe_up=False, added=0, removed=0)
        return 0

    live_keys = _read_live_keys()
    if live_keys is None:
        write_metrics(probe_up=False, added=0, removed=0)
        return 0

    added = len(live_keys - template_keys)
    removed = len(template_keys - live_keys)
    write_metrics(probe_up=True, added=added, removed=removed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
