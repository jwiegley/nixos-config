"""Write data points to VictoriaMetrics via the InfluxDB line protocol.

VM exposes a `/write` endpoint that accepts a newline-separated stream of
InfluxDB line-protocol records. This is the simplest path for the Phase 3
backfill, which needs to splice synthetic per-day cumulative totals into
the same database the live recorder writes to.

Line protocol shape::

    measurement,tag1=v1,tag2=v2 field1=v1,field2=v2 ts_ns

Tags and fields are alphabetically sorted so two equivalent points always
serialise byte-for-byte identically (helps idempotency on re-runs).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Iterable

import requests


@dataclass(frozen=True)
class DataPoint:
    """A single InfluxDB line-protocol record."""

    measurement: str
    tags: dict[str, str]
    fields: dict[str, float]
    timestamp: datetime


def format_line_protocol(p: DataPoint) -> str:
    """Serialise a ``DataPoint`` to InfluxDB line protocol.

    The output ends in the nanosecond timestamp so VM stores the point at
    the exact instant the caller supplied (no server-side clock drift).
    """
    tag_str = ",".join(f"{k}={v}" for k, v in sorted(p.tags.items()))
    field_str = ",".join(f"{k}={v}" for k, v in sorted(p.fields.items()))
    ts_ns = int(p.timestamp.timestamp() * 1_000_000_000)
    base = p.measurement
    if tag_str:
        base = f"{base},{tag_str}"
    return f"{base} {field_str} {ts_ns}"


def write_points(
    points: Iterable[DataPoint],
    base_url: str,
    batch_size: int = 1000,
    timeout: float = 30.0,
) -> None:
    """POST a batched stream of points to VM's ``/write`` endpoint.

    Args:
        points: Iterable of points to serialise. Consumed lazily.
        base_url: ``http://host:port`` root of the VM instance.
        batch_size: Maximum lines per POST. Defaults to 1000 — VM tolerates
            far larger batches, but staying small bounds memory + makes
            mid-stream failure recoverable.
        timeout: Per-request timeout in seconds.
    """
    batch: list[str] = []
    for p in points:
        batch.append(format_line_protocol(p))
        if len(batch) >= batch_size:
            _flush(batch, base_url, timeout)
            batch = []
    if batch:
        _flush(batch, base_url, timeout)


def _flush(batch: list[str], base_url: str, timeout: float) -> None:
    resp = requests.post(
        f"{base_url.rstrip('/')}/write",
        data="\n".join(batch).encode("utf-8"),
        headers={"Content-Type": "text/plain; charset=utf-8"},
        timeout=timeout,
    )
    resp.raise_for_status()
