"""Typed async client for Hermes Agent's aiohttp api_server platform.

Auth model: Bearer token in the Authorization header (Hermes' api_server
validates with hmac.compare_digest against API_SERVER_KEY).  Sessions are
tracked separately via the X-Hermes-Session-Id header sent per-request.
"""
from __future__ import annotations

import httpx

from hermes_mcp.config import Config


class HermesClient:
    def __init__(self, config: Config, http: httpx.AsyncClient | None = None):
        self._cfg = config
        self._http = http or httpx.AsyncClient(
            base_url=config.hermes_api_url,
            timeout=httpx.Timeout(
                connect=30.0,
                read=config.request_timeout_seconds,
                write=config.request_timeout_seconds,
                pool=30.0,
            ),
            headers={"Authorization": f"Bearer {config.hermes_api_key}"},
        )

    async def chat(
        self,
        *,
        hermes_session_id: str,
        prompt: str,
        model: str | None = None,
    ) -> str:
        payload = {
            "model": model or self._cfg.model,
            "messages": [{"role": "user", "content": prompt}],
        }
        r = await self._http.post(
            "/v1/chat/completions",
            headers={"X-Hermes-Session-Id": hermes_session_id},
            json=payload,
        )
        r.raise_for_status()
        data = r.json()
        return data["choices"][0]["message"]["content"]

    async def get_capabilities(self) -> dict:
        r = await self._http.get("/v1/capabilities")
        r.raise_for_status()
        return r.json()

    async def aclose(self) -> None:
        await self._http.aclose()
