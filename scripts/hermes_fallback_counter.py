#!/usr/bin/env python3
"""Count "Non-retryable" fallback events in Hermes' errors.log.

Emits a single Prometheus counter that increases monotonically each
time Hermes' conversation loop logs a non-retryable client error
(typically HTTP 401/403/404 from upstream, which presents to the user
on Discord as "⚠️ Non-retryable error (HTTP N) — trying fallback…").

The counter is reset to 0 whenever the log file is rotated/truncated
(inode changes), which Prometheus' increase() handles gracefully.

Why a separate signal from the e2e probe:
  - The e2e probe runs every 5 min and tests the chat path proactively
    with a synthetic prompt.
  - This counter records ACTUAL user-visible failures as they happen
    — including transients the probe might miss between intervals.
    Two failures within a probe interval would each be counted here
    but only show as one probe failure.

Output: /var/lib/prometheus-node-exporter-textfiles/hermes_fallback.prom

  hermes_fallback_chain_triggered_total   monotonic count (resets on log rotate)
  hermes_fallback_counter_last_run_timestamp_seconds
"""

from __future__ import annotations

import os
import pathlib
import re
import tempfile
import time

LOG_PATH = os.environ.get(
    "HERMES_FALLBACK_LOG_PATH",
    "/var/lib/hermes/.hermes/logs/errors.log",
)
METRIC_PATH = os.environ.get(
    "HERMES_FALLBACK_METRIC_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/hermes_fallback.prom",
)
# Match the exact phrase Hermes emits, e.g.:
#   "ERROR ... Non-retryable client error: Error code: 401 - {...}"
PATTERN = re.compile(r"Non-retryable client error", re.IGNORECASE)


def count_occurrences(path: str) -> int:
    """Count lines matching PATTERN in the log file.

    Returns 0 if the file is missing (counter will look like a reset,
    which is the correct semantic when the log is freshly rotated).
    """
    p = pathlib.Path(path)
    if not p.is_file():
        return 0
    total = 0
    try:
        # Read in binary mode — errors.log can contain stray utf-8
        # sequences from tool output that decode-strict would barf on.
        with p.open("rb") as fh:
            for raw in fh:
                # Decode lenient; we only need to match an ASCII pattern.
                try:
                    line = raw.decode("utf-8", errors="replace")
                except Exception:
                    continue
                if PATTERN.search(line):
                    total += 1
    except OSError:
        return 0
    return total


def write_metrics(count: int, timestamp: float, target: str = METRIC_PATH) -> None:
    lines = [
        "# HELP hermes_fallback_chain_triggered_total Cumulative count of 'Non-retryable client error' events in Hermes errors.log (resets on log rotation)",
        "# TYPE hermes_fallback_chain_triggered_total counter",
        f"hermes_fallback_chain_triggered_total {count}",
        "# HELP hermes_fallback_counter_last_run_timestamp_seconds When the counter last refreshed (Unix epoch)",
        "# TYPE hermes_fallback_counter_last_run_timestamp_seconds gauge",
        f"hermes_fallback_counter_last_run_timestamp_seconds {timestamp}",
        "",
    ]
    target_path = pathlib.Path(target)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", dir=str(target_path.parent), delete=False, suffix=".tmp"
    ) as tmp:
        tmp.write("\n".join(lines))
        tmp_path = tmp.name
    # node-exporter runs as `node-exporter` user; need world-readable
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, target_path)


def main() -> int:
    count = count_occurrences(LOG_PATH)
    write_metrics(count, time.time())
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
