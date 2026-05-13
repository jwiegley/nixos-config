from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from hermes_mcp.config import Config
from hermes_mcp.hermes_client import HermesClient
from hermes_mcp.session_store import SessionStore
from hermes_mcp import tools


@pytest.fixture
def cfg(tmp_path: Path) -> Config:
    return Config(
        hermes_api_url="http://hermes.test:8080",
        hermes_api_key="k",
        model="m",
        db_path=tmp_path / "s.db",
        sse_host="127.0.0.1",
        sse_port=9081,
    )


@pytest.fixture
async def store(cfg: Config) -> SessionStore:
    s = SessionStore(cfg.db_path)
    await s.init()
    return s


@pytest.fixture
def mock_client() -> AsyncMock:
    c = AsyncMock(spec=HermesClient)
    c.chat.return_value = "mock reply"
    return c


@pytest.mark.asyncio
async def test_start_session_creates_row_without_calling_hermes(store, mock_client):
    out = await tools.tool_start_session(store, mock_client, name="planning")
    assert out["name"] == "planning"
    assert len(out["session_id"]) == 32
    assert "hermes_session_id" in out
    mock_client.chat.assert_not_awaited()


@pytest.mark.asyncio
async def test_ask_hermes_without_session_creates_one(store, mock_client):
    out = await tools.tool_ask_hermes(store, mock_client, prompt="hi there")
    assert out["reply"] == "mock reply"
    assert "session_id" in out
    assert out["message_count"] == 1
    mock_client.chat.assert_awaited_once()


@pytest.mark.asyncio
async def test_ask_hermes_with_session_reuses(store, mock_client):
    started = await tools.tool_start_session(store, mock_client, name="x")
    out = await tools.tool_ask_hermes(
        store, mock_client, prompt="hi", session_id=started["session_id"]
    )
    assert out["session_id"] == started["session_id"]
    assert out["message_count"] == 1


@pytest.mark.asyncio
async def test_continue_session_requires_existing(store, mock_client):
    out = await tools.tool_continue_session(
        store, mock_client, session_id="nonexistent", prompt="hi"
    )
    assert "error" in out
    assert "not found" in out["error"].lower()
    mock_client.chat.assert_not_awaited()


@pytest.mark.asyncio
async def test_continue_session_happy_path(store, mock_client):
    started = await tools.tool_start_session(store, mock_client, name=None)
    out = await tools.tool_continue_session(
        store, mock_client, session_id=started["session_id"], prompt="hi"
    )
    assert out["reply"] == "mock reply"


@pytest.mark.asyncio
async def test_list_sessions(store, mock_client):
    await tools.tool_start_session(store, mock_client, name="a")
    await tools.tool_start_session(store, mock_client, name="b")
    out = await tools.tool_list_sessions(store, mock_client)
    assert len(out["sessions"]) == 2


@pytest.mark.asyncio
async def test_summarize_session_uses_meta_prompt_and_stores(store, mock_client):
    mock_client.chat.return_value = "Summary: discussed plans."
    started = await tools.tool_start_session(store, mock_client, name="x")
    out = await tools.tool_summarize_session(
        store, mock_client, session_id=started["session_id"]
    )
    assert out["summary"] == "Summary: discussed plans."
    after = await store.get(started["session_id"])
    assert after.summary == "Summary: discussed plans."
    sent_kwargs = mock_client.chat.await_args.kwargs
    assert sent_kwargs["hermes_session_id"] == started["hermes_session_id"]


@pytest.mark.asyncio
async def test_delete_session_returns_true_then_false(store, mock_client):
    started = await tools.tool_start_session(store, mock_client, name=None)
    out1 = await tools.tool_delete_session(store, mock_client, session_id=started["session_id"])
    assert out1["deleted"] is True
    out2 = await tools.tool_delete_session(store, mock_client, session_id=started["session_id"])
    assert out2["deleted"] is False
