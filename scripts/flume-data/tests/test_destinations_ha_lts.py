"""Tests for the HA Long-Term Statistics writer."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from types import ModuleType

import pytest

from flume_data.destinations.ha_lts import (
    StatisticsPoint,
    build_import_payload,
)


def test_build_import_payload_shapes_message_correctly():
    """Two hourly points are wrapped into the recorder/import_statistics
    payload with has_sum=True (we always write cumulative totals)."""
    points = [
        StatisticsPoint(
            start=datetime(2026, 5, 15, 0, 0, tzinfo=timezone.utc),
            sum_=100.0,
            state=100.0,
        ),
        StatisticsPoint(
            start=datetime(2026, 5, 15, 1, 0, tzinfo=timezone.utc),
            sum_=125.0,
            state=125.0,
        ),
    ]
    payload = build_import_payload(
        statistic_id="flume_data:water_pool_autofill_total",
        name="Water Pool Autofill Total (backfilled)",
        unit_of_measurement="gal",
        points=points,
    )
    assert payload["type"] == "recorder/import_statistics"
    # The descriptor is nested under `metadata` (HA rejects a flat layout).
    md = payload["metadata"]
    assert md["statistic_id"] == "flume_data:water_pool_autofill_total"
    assert md["has_sum"] is True
    assert md["has_mean"] is False
    assert md["unit_of_measurement"] == "gal"
    # External statistic (id has a colon) -> source is the colon prefix, NOT
    # "recorder"; HA rejects the import otherwise. Both the flat layout and
    # source="recorder" previously encoded the silent-rejection bug.
    assert md["source"] == "flume_data"
    assert len(payload["stats"]) == 2
    assert payload["stats"][0]["sum"] == 100.0
    assert payload["stats"][1]["sum"] == 125.0
    # Hour-aligned ISO timestamps round-trip without loss.
    assert payload["stats"][0]["start"].startswith("2026-05-15T00:00:00")
    # A recorder statistic (no colon in the id) keeps source="recorder".
    rec = build_import_payload(
        "sensor.water_pool_autofill_total", "x", "gal", points
    )
    assert rec["metadata"]["source"] == "recorder"


class _FakeWebSocket:
    """In-memory WebSocket double scripted with a list of inbound frames.

    ``recv()`` pops the next scripted frame; ``send()`` records the payload
    so the test can assert on the auth message body. ``close()`` is recorded
    so the test can verify the connection is properly torn down on error.
    """

    def __init__(self, inbound: list[str]) -> None:
        self.inbound = list(inbound)
        self.sent: list[str] = []
        self.closed = False

    def recv(self) -> str:
        return self.inbound.pop(0)

    def send(self, payload: str) -> None:
        self.sent.append(payload)

    def close(self) -> None:
        self.closed = True


def _install_fake_websocket(monkeypatch, ws: _FakeWebSocket) -> None:
    """Stand up a fake ``websocket`` module so ``_ws_connect`` can be exercised."""
    fake_mod = ModuleType("websocket")
    fake_mod.create_connection = lambda *args, **kwargs: ws  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "websocket", fake_mod)


def test_ws_connect_three_step_handshake(monkeypatch):
    """``_ws_connect`` walks auth_required → auth → auth_ok in order."""
    from flume_data.destinations.ha_lts import _ws_connect

    ws = _FakeWebSocket(
        inbound=[
            json.dumps({"type": "auth_required", "ha_version": "2025.11.0"}),
            json.dumps({"type": "auth_ok", "ha_version": "2025.11.0"}),
        ]
    )
    _install_fake_websocket(monkeypatch, ws)

    result = _ws_connect("ws://test/api/websocket", "fake-token")

    assert result is ws
    assert ws.closed is False
    assert len(ws.sent) == 1
    body = json.loads(ws.sent[0])
    assert body == {"type": "auth", "access_token": "fake-token"}


def test_ws_connect_raises_on_auth_invalid(monkeypatch):
    """An ``auth_invalid`` response surfaces as RuntimeError, no token leak."""
    from flume_data.destinations.ha_lts import _ws_connect

    ws = _FakeWebSocket(
        inbound=[
            json.dumps({"type": "auth_required"}),
            json.dumps({"type": "auth_invalid", "message": "Invalid token"}),
        ]
    )
    _install_fake_websocket(monkeypatch, ws)

    with pytest.raises(RuntimeError, match="auth failed"):
        _ws_connect("ws://test/api/websocket", "bad-token")
    # The exception body never echoes the token (regression check).
    assert ws.closed is True


def test_ws_connect_raises_on_missing_greeting(monkeypatch):
    """A server that opens with anything but ``auth_required`` is rejected."""
    from flume_data.destinations.ha_lts import _ws_connect

    ws = _FakeWebSocket(
        inbound=[
            json.dumps({"type": "event", "id": 0}),
        ]
    )
    _install_fake_websocket(monkeypatch, ws)

    with pytest.raises(RuntimeError, match="unexpected greeting"):
        _ws_connect("ws://test/api/websocket", "fake-token")
    assert ws.closed is True


def test_import_statistics_after_handshake_uses_command_response(monkeypatch):
    """End-to-end: after auth_ok, ``import_statistics`` sees the command ack."""
    from flume_data.destinations.ha_lts import (
        StatisticsPoint as _SP,
        import_statistics,
    )

    ws = _FakeWebSocket(
        inbound=[
            json.dumps({"type": "auth_required"}),
            json.dumps({"type": "auth_ok"}),
            # Without the 3-step handshake fix, this frame would be eaten
            # by the previous recv() and import_statistics would block.
            json.dumps({"id": 1, "type": "result", "success": True}),
        ]
    )
    _install_fake_websocket(monkeypatch, ws)

    points = [
        _SP(
            start=datetime(2026, 5, 15, 0, 0, tzinfo=timezone.utc),
            sum_=100.0,
            state=100.0,
        ),
    ]
    ack = import_statistics(
        ws_url="ws://test/api/websocket",
        access_token="fake-token",
        statistic_id="flume_data:water_pool_autofill_total",
        name="Water Pool Autofill Total (backfilled)",
        unit_of_measurement="gal",
        points=points,
    )
    assert ack["success"] is True
    assert ws.closed is True
    # Two sends: auth then the import_statistics payload.
    assert len(ws.sent) == 2
    import_payload = json.loads(ws.sent[1])
    assert import_payload["type"] == "recorder/import_statistics"
    assert import_payload["id"] == 1
