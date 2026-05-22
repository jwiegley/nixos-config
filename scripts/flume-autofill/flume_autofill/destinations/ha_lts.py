"""HA Long-Term Statistics writer via WebSocket ``recorder/import_statistics``.

The Phase 3 backfill injects synthetic hourly cumulative totals into the
``flume_autofill:water_*_total`` external-statistic namespace. HA's
recorder integration documents two operations we need:

- ``recorder/import_statistics`` — insert/overwrite hourly LTS records
  for a given ``statistic_id`` (idempotent on ``(statistic_id, hour)``).
- ``recorder/clear_statistics`` — wipe a statistic namespace; used by
  ``backfill --unpromote``.

The ``flume_autofill:`` prefix marks these as external statistics so
they remain visible alongside the live ``sensor.water_*_total`` series
but never compete with the recorder's own write path.

Reference:
https://www.home-assistant.io/integrations/recorder/#service-recorderimport_statistics
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Any


def _ws_connect(url: str, token: str):
    """Open an authenticated HA WebSocket connection.

    ``websocket-client`` is imported lazily so unit tests don't need it on
    the path — the build payload is the only thing exercised in tests.
    """
    from websocket import create_connection  # type: ignore[import]

    ws = create_connection(url, timeout=30)
    ws.send(json.dumps({"type": "auth", "access_token": token}))
    # HA replies with auth_required followed by auth_ok / auth_invalid.
    # We don't inspect the handshake here; downstream sends will raise
    # if auth failed.
    _ = ws.recv()
    return ws


@dataclass(frozen=True)
class StatisticsPoint:
    """One hourly LTS sample for a cumulative ``total_increasing`` sensor.

    Attributes:
        start: Hour-aligned UTC timestamp (HA rejects non-aligned values).
        sum_: Cumulative running sum at the end of this hour.
        state: Sensor state at the end of this hour. For
            ``total_increasing`` cumulative counters, equals ``sum_``.
    """

    start: datetime
    sum_: float
    state: float


def build_import_payload(
    statistic_id: str,
    name: str,
    unit_of_measurement: str,
    points: list[StatisticsPoint],
) -> dict[str, Any]:
    """Construct the ``recorder/import_statistics`` WebSocket payload.

    Note: the ``id`` field required by HA's WebSocket transport is added
    by :func:`import_statistics` (it owns message ordering); this helper
    returns the type-specific body only.
    """
    return {
        "type": "recorder/import_statistics",
        "statistic_id": statistic_id,
        "name": name,
        "source": "recorder",
        "unit_of_measurement": unit_of_measurement,
        "has_sum": True,
        "has_mean": False,
        "stats": [
            {
                "start": p.start.isoformat(),
                "sum": p.sum_,
                "state": p.state,
            }
            for p in points
        ],
    }


def import_statistics(
    ws_url: str,
    access_token: str,
    statistic_id: str,
    name: str,
    unit_of_measurement: str,
    points: list[StatisticsPoint],
) -> dict[str, Any]:
    """Open a WebSocket, send ``import_statistics``, and return HA's ack.

    Idempotent: re-sending the same ``(statistic_id, start)`` overwrites
    rather than duplicates, so this is safe to retry.
    """
    ws = _ws_connect(ws_url, access_token)
    try:
        msg = build_import_payload(
            statistic_id, name, unit_of_measurement, points
        )
        ws.send(json.dumps({**msg, "id": 1}))
        return json.loads(ws.recv())
    finally:
        ws.close()
