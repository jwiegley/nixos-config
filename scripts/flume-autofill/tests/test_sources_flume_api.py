"""Tests for the Flume Personal API client."""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
import responses

from flume_autofill.sources.flume_api import (
    Credentials,
    FlumeAPIClient,
    FlumeAPIError,
)


CREDS = Credentials(
    client_id="cid",
    client_secret="csec",
    username="uname",
    password="pwd",
)


@responses.activate
def test_mint_token_caches_and_reuses():
    """A second access of `.token` must NOT hit the mint endpoint twice."""
    responses.post(
        "https://api.flumewater.com/oauth/token",
        json={
            "data": [
                {
                    "access_token": "tok",
                    "refresh_token": "ref",
                    "expires_in": 604800,
                }
            ]
        },
        status=200,
    )
    client = FlumeAPIClient(CREDS, token_cache_path=None)
    tok1 = client.token
    tok2 = client.token  # second call hits the in-memory cache, no second mint
    assert tok1 == tok2 == "tok"
    assert len(responses.calls) == 1


@responses.activate
def test_query_returns_per_minute_series(tmp_path):
    """query_gpm returns a list of (UTC datetime, gpm) tuples."""
    responses.post(
        "https://api.flumewater.com/oauth/token",
        json={
            "data": [
                {
                    "access_token": "tok",
                    "refresh_token": "ref",
                    "expires_in": 600,
                }
            ]
        },
    )
    responses.post(
        "https://api.flumewater.com/users/0/devices/dev1/query",
        json={
            "data": [
                {
                    "req1": [
                        {"datetime": "2026-05-21 22:00:00", "value": 4.1},
                        {"datetime": "2026-05-21 22:01:00", "value": 4.0},
                    ]
                }
            ]
        },
    )
    client = FlumeAPIClient(CREDS, token_cache_path=tmp_path / "tok.json")
    series = client.query_gpm(
        device_id="dev1",
        user_id=0,
        since=datetime(2026, 5, 21, 22, 0, tzinfo=timezone.utc),
        until=datetime(2026, 5, 21, 22, 5, tzinfo=timezone.utc),
    )
    assert len(series) == 2
    assert series[0][1] == 4.1
    assert series[1][1] == 4.0


@responses.activate
def test_query_backs_off_on_429():
    """A 429 with Retry-After triggers a sleep, then a successful retry."""
    responses.post(
        "https://api.flumewater.com/oauth/token",
        json={
            "data": [
                {
                    "access_token": "tok",
                    "refresh_token": "ref",
                    "expires_in": 600,
                }
            ]
        },
    )
    responses.post(
        "https://api.flumewater.com/users/0/devices/dev1/query",
        status=429,
        headers={"Retry-After": "1"},
    )
    responses.post(
        "https://api.flumewater.com/users/0/devices/dev1/query",
        json={"data": [{"req1": []}]},
        status=200,
    )
    client = FlumeAPIClient(
        CREDS, token_cache_path=None, retry_initial_seconds=0.01
    )
    series = client.query_gpm(
        device_id="dev1",
        user_id=0,
        since=datetime(2026, 5, 21, 22, 0, tzinfo=timezone.utc),
        until=datetime(2026, 5, 21, 22, 5, tzinfo=timezone.utc),
    )
    assert series == []
    # 1 mint + 1 throttled + 1 success = 3 calls
    assert len(responses.calls) == 3
