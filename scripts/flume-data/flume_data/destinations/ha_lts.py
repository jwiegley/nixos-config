"""HA Long-Term Statistics writer via WebSocket ``recorder/import_statistics``.

The Phase 3 backfill injects synthetic hourly cumulative totals into the
``flume_data:water_*_total`` external-statistic namespace. HA's
recorder integration documents two operations we need:

- ``recorder/import_statistics`` — insert/overwrite hourly LTS records
  for a given ``statistic_id`` (idempotent on ``(statistic_id, hour)``).
- ``recorder/clear_statistics`` — wipe a statistic namespace; used by
  ``backfill --unpromote``.

The ``flume_data:`` prefix marks these as external statistics so
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

    HA's WebSocket auth is a THREE-message handshake (see
    https://developers.home-assistant.io/docs/api/websocket/#authentication-phase):

      1. server → ``{"type": "auth_required", ...}``  (greeting)
      2. client → ``{"type": "auth", "access_token": "<token>"}``
      3. server → ``{"type": "auth_ok"}`` or ``{"type": "auth_invalid"}``

    Misaligning these steps causes every subsequent ``ws.recv()`` to return
    the auth result instead of the command response. We synchronously
    walk all three steps and raise on anything unexpected, so callers
    can rely on ``recv()`` returning the *command* response.

    ``websocket-client`` is imported lazily so unit tests don't need it on
    the path — the build payload is the only thing exercised in tests.
    """
    from websocket import create_connection  # type: ignore[import]

    ws = create_connection(url, timeout=30)
    # Step 1: server sends auth_required greeting
    greeting = json.loads(ws.recv())
    if greeting.get("type") != "auth_required":
        ws.close()
        raise RuntimeError(
            f"HA WebSocket unexpected greeting: {greeting.get('type')}"
        )
    # Step 2: client sends auth
    ws.send(json.dumps({"type": "auth", "access_token": token}))
    # Step 3: server sends auth_ok or auth_invalid (no token echoed back).
    auth_resp = json.loads(ws.recv())
    if auth_resp.get("type") != "auth_ok":
        ws.close()
        raise RuntimeError(
            f"HA WebSocket auth failed: {auth_resp.get('type')}"
        )
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
    # HA validates `source` against the statistic_id: an EXTERNAL statistic
    # (id contains a `:`, e.g. "flume_data:water_pool_autofill_total") MUST set
    # source to the prefix before the colon; a recorder statistic (a "sensor.*"
    # id, no colon) MUST use "recorder". Hardcoding "recorder" for the external
    # backfill id made HA silently reject every import.
    source = statistic_id.split(":", 1)[0] if ":" in statistic_id else "recorder"
    # recorder/import_statistics nests the descriptor under `metadata`; the
    # earlier flat layout was rejected by HA ("extra keys not allowed ...
    # required key not provided @ data['metadata']").
    return {
        "type": "recorder/import_statistics",
        "metadata": {
            "has_mean": False,
            "has_sum": True,
            "name": name,
            "source": source,
            "statistic_id": statistic_id,
            "unit_of_measurement": unit_of_measurement,
        },
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
        ack = json.loads(ws.recv())
        # HA acks every command with {"success": bool}. The backfill used to
        # ignore this and print "imported" even when HA rejected the payload
        # (e.g. a wrong `source`), so failures were silent. Fail loud instead.
        if not ack.get("success", False):
            raise RuntimeError(f"HA import_statistics rejected: {ack.get('error')}")
        return ack
    finally:
        ws.close()
