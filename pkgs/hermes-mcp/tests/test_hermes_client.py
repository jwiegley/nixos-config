import os
from pathlib import Path

import httpx
import pytest
import respx

from hermes_mcp.config import Config
from hermes_mcp.hermes_client import HermesClient


@pytest.fixture
def cfg(tmp_path: Path) -> Config:
    return Config(
        hermes_api_url="http://hermes.test:8080",
        hermes_api_key="key-deadbeef",
        model="test-model",
        db_path=tmp_path / "s.db",
        sse_host="127.0.0.1",
        sse_port=9081,
    )


def test_config_from_env_requires_url_and_key(monkeypatch):
    monkeypatch.delenv("HERMES_API_URL", raising=False)
    monkeypatch.delenv("HERMES_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="HERMES_API_URL"):
        Config.from_env()
    monkeypatch.setenv("HERMES_API_URL", "http://x")
    with pytest.raises(RuntimeError, match="HERMES_API_KEY"):
        Config.from_env()


@pytest.mark.asyncio
@respx.mock
async def test_chat_sends_session_headers_and_returns_content(cfg):
    route = respx.post("http://hermes.test:8080/v1/chat/completions").mock(
        return_value=httpx.Response(
            200,
            json={
                "id": "cmpl-1",
                "object": "chat.completion",
                "created": 0,
                "model": "test-model",
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": "hello back"},
                     "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3},
            },
        )
    )
    client = HermesClient(cfg)
    try:
        reply = await client.chat(hermes_session_id="hsid-1", prompt="hello")
    finally:
        await client.aclose()

    assert reply == "hello back"
    sent = route.calls.last.request
    assert sent.headers["Authorization"] == "Bearer key-deadbeef"
    assert sent.headers["X-Hermes-Session-Id"] == "hsid-1"
    body = sent.read().decode()
    assert "test-model" in body
    assert "hello" in body


@pytest.mark.asyncio
@respx.mock
async def test_chat_raises_on_non_200(cfg):
    respx.post("http://hermes.test:8080/v1/chat/completions").mock(
        return_value=httpx.Response(401, json={"error": "bad key"})
    )
    client = HermesClient(cfg)
    try:
        with pytest.raises(httpx.HTTPStatusError):
            await client.chat(hermes_session_id="hsid-1", prompt="hi")
    finally:
        await client.aclose()


@pytest.mark.asyncio
@respx.mock
async def test_get_capabilities_returns_endpoint_map(cfg):
    respx.get("http://hermes.test:8080/v1/capabilities").mock(
        return_value=httpx.Response(
            200,
            json={
                "object": "hermes.api_server.capabilities",
                "endpoints": {"chat_completions": {"method": "POST", "path": "/v1/chat/completions"}},
            },
        )
    )
    client = HermesClient(cfg)
    try:
        caps = await client.get_capabilities()
    finally:
        await client.aclose()
    assert caps["object"] == "hermes.api_server.capabilities"
