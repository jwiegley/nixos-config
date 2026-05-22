"""Flume Personal API client.

References:
  - https://help.flumewater.com/en/articles/3108017-flume-personal-api
  - https://flumetech.readme.io/reference/query-a-user-device

Authentication is OAuth password-grant: a single POST mints a bearer token
plus a refresh token. Tokens are cached on disk (mode 0600) so a fresh
process doesn't burn the rate-limited oauth/token endpoint on every run.
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import requests


BASE_URL = "https://api.flumewater.com"


@dataclass(frozen=True)
class Credentials:
    """Flume Personal API password-grant credentials."""

    client_id: str
    client_secret: str
    username: str
    password: str


class FlumeAPIError(RuntimeError):
    """Raised when the Flume API returns an unrecoverable error."""


class FlumeAPIClient:
    """Bearer-token-cached Flume API client with simple retry/backoff.

    Token cache layout (JSON):
        {
            "access_token": "...",
            "expires_at":  <epoch_seconds>,
            "user_id":     <int or null>
        }

    `expires_at` is set to (now + expires_in - 60) so a 60-second skew
    buffer prevents reuse of a token that's about to lapse mid-request.
    """

    def __init__(
        self,
        creds: Credentials,
        token_cache_path: Path | None,
        retry_initial_seconds: float = 1.0,
        max_retries: int = 4,
    ) -> None:
        self._creds = creds
        self._cache_path = token_cache_path
        self._retry_initial_seconds = retry_initial_seconds
        self._max_retries = max_retries
        self._token: str | None = None
        self._user_id: int | None = None

        if token_cache_path and token_cache_path.exists():
            cached = json.loads(token_cache_path.read_text())
            if cached.get("expires_at", 0) > time.time() + 60:
                self._token = cached["access_token"]
                self._user_id = cached.get("user_id")

    @property
    def token(self) -> str:
        if self._token is None:
            self._mint_token()
        assert self._token is not None  # mypy/runtime guard
        return self._token

    def _mint_token(self) -> None:
        body = {
            "grant_type": "password",
            "client_id": self._creds.client_id,
            "client_secret": self._creds.client_secret,
            "username": self._creds.username,
            "password": self._creds.password,
        }
        resp = requests.post(f"{BASE_URL}/oauth/token", json=body, timeout=30)
        if resp.status_code != 200:
            # Don't include resp.text — the response body can echo back the
            # request body which contains our credentials.
            raise FlumeAPIError(
                f"oauth/token returned HTTP {resp.status_code}"
            )
        data = resp.json()["data"][0]
        self._token = data["access_token"]
        # The user_id is embedded in the JWT; parse it lazily on first query call.
        if self._cache_path:
            # Atomic 0600 write: the previous `write_text` + `chmod(0o600)`
            # pair left a ≈microsecond TOCTOU window where the cache file
            # was world-readable. `os.open` with O_CREAT | O_WRONLY | O_TRUNC
            # at mode 0600 establishes permissions in the same syscall that
            # creates the file (subject to the process umask, which Python
            # respects). Use os.fdopen to wrap the descriptor for the JSON
            # write; the descriptor is closed on success by the context
            # manager, or explicitly on exception.
            payload = {
                "access_token": self._token,
                "expires_at": time.time() + int(data["expires_in"]) - 60,
                "user_id": self._user_id,
            }
            fd = os.open(
                str(self._cache_path),
                os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                0o600,
            )
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(payload, f)
            except Exception:
                # os.fdopen() with a successful return path closes via the
                # context manager. If json.dump or fdopen itself raises
                # before that handoff, close the raw fd to avoid leakage.
                try:
                    os.close(fd)
                except OSError:
                    pass
                raise

    def query_gpm(
        self,
        device_id: str,
        user_id: int,
        since: datetime,
        until: datetime,
    ) -> list[tuple[datetime, float]]:
        """Return per-minute (timestamp_utc, gpm) tuples for the window.

        Retries on HTTP 429 with exponential backoff (capped at max_retries),
        honoring the Retry-After header when present.
        """
        body = {
            "queries": [
                {
                    "request_id": "req1",
                    "bucket": "MIN",
                    "since_datetime": since.strftime("%Y-%m-%d %H:%M:%S"),
                    "until_datetime": until.strftime("%Y-%m-%d %H:%M:%S"),
                    "units": "GALLONS",
                    "sort_direction": "ASC",
                }
            ]
        }
        url = f"{BASE_URL}/users/{user_id}/devices/{device_id}/query"

        resp = None
        for attempt in range(self._max_retries):
            resp = requests.post(
                url,
                json=body,
                headers={"Authorization": f"Bearer {self.token}"},
                timeout=60,
            )
            if resp.status_code == 200:
                break
            if resp.status_code == 429:
                wait = self._retry_initial_seconds * (2 ** attempt)
                if "Retry-After" in resp.headers:
                    try:
                        wait = max(wait, float(resp.headers["Retry-After"]))
                    except ValueError:
                        pass
                time.sleep(wait)
                continue
            raise FlumeAPIError(
                f"query returned HTTP {resp.status_code}"
            )
        else:
            raise FlumeAPIError("max retries exhausted on query endpoint")

        if resp is None or resp.status_code != 200:
            raise FlumeAPIError("query did not yield a 200 response")

        items = resp.json()["data"][0].get("req1", [])
        return [
            (
                datetime.strptime(
                    it["datetime"], "%Y-%m-%d %H:%M:%S"
                ).replace(tzinfo=timezone.utc),
                float(it["value"]),
            )
            for it in items
        ]
