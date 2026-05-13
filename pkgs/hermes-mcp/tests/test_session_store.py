import asyncio
import time

import pytest

from hermes_mcp.session_store import SessionStore


@pytest.mark.asyncio
async def test_create_assigns_uuid_and_timestamps(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    before = time.time()
    s = await store.create(name="research")
    after = time.time()

    assert len(s.id) == 32  # uuid4().hex
    assert s.name == "research"
    assert s.hermes_session_id  # non-empty
    assert before <= s.created_at <= after
    assert s.created_at == s.last_used_at
    assert s.message_count == 0
    assert s.summary is None


@pytest.mark.asyncio
async def test_get_returns_none_for_missing(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    assert await store.get("nonexistent") is None


@pytest.mark.asyncio
async def test_get_by_name(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create(name="planning")
    found = await store.get_by_name("planning")
    assert found is not None
    assert found.id == s.id


@pytest.mark.asyncio
async def test_list_returns_descending_by_last_used(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s1 = await store.create(name="first")
    await asyncio.sleep(0.01)
    s2 = await store.create(name="second")
    sessions = await store.list()
    assert [s.id for s in sessions] == [s2.id, s1.id]


@pytest.mark.asyncio
async def test_touch_updates_last_used_and_increments_count(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create()
    original_last = s.last_used_at
    original_count = s.message_count
    await asyncio.sleep(0.01)
    await store.touch(s.id, increment_messages=True)
    after = await store.get(s.id)
    assert after.last_used_at > original_last
    assert after.message_count == original_count + 1


@pytest.mark.asyncio
async def test_set_summary_persists(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create()
    await store.set_summary(s.id, "User explored MCP integration options.")
    after = await store.get(s.id)
    assert after.summary == "User explored MCP integration options."


@pytest.mark.asyncio
async def test_delete_returns_true_then_false(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create()
    assert await store.delete(s.id) is True
    assert await store.delete(s.id) is False
    assert await store.get(s.id) is None


@pytest.mark.asyncio
async def test_init_is_idempotent(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    await store.init()  # must not raise
