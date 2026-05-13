"""MCP tool implementations.  Pure async functions — no MCP-SDK types here.

The SDK plumbing lives in server.py; keeping these functions pure makes
them testable with stdlib mocks.
"""
from __future__ import annotations

from hermes_mcp.hermes_client import HermesClient
from hermes_mcp.session_store import Session, SessionStore

_SUMMARY_PROMPT = (
    "Please summarize the conversation we've had in this session in "
    "3-5 sentences. Focus on decisions, open questions, and anything that "
    "would help someone resuming this thread later."
)


def _session_to_dict(s: Session) -> dict:
    return {
        "session_id": s.id,
        "name": s.name,
        "hermes_session_id": s.hermes_session_id,
        "created_at": s.created_at,
        "last_used_at": s.last_used_at,
        "message_count": s.message_count,
        "summary": s.summary,
    }


async def tool_start_session(
    store: SessionStore,
    client: HermesClient,  # noqa: ARG001 — kept in signature for symmetry
    *,
    name: str | None = None,
) -> dict:
    s = await store.create(name=name)
    return _session_to_dict(s)


async def tool_ask_hermes(
    store: SessionStore,
    client: HermesClient,
    *,
    prompt: str,
    session_id: str | None = None,
) -> dict:
    if session_id is None:
        s = await store.create()
    else:
        s = await store.get(session_id)
        if s is None:
            return {"error": f"session {session_id!r} not found"}
    reply = await client.chat(hermes_session_id=s.hermes_session_id, prompt=prompt)
    await store.touch(s.id, increment_messages=True)
    updated = await store.get(s.id)
    return {
        "session_id": s.id,
        "reply": reply,
        "message_count": updated.message_count,
    }


async def tool_continue_session(
    store: SessionStore,
    client: HermesClient,
    *,
    session_id: str,
    prompt: str,
) -> dict:
    s = await store.get(session_id)
    if s is None:
        return {"error": f"session {session_id!r} not found"}
    reply = await client.chat(hermes_session_id=s.hermes_session_id, prompt=prompt)
    await store.touch(s.id, increment_messages=True)
    updated = await store.get(s.id)
    return {
        "session_id": s.id,
        "reply": reply,
        "message_count": updated.message_count,
    }


async def tool_list_sessions(
    store: SessionStore,
    client: HermesClient,  # noqa: ARG001
    *,
    limit: int = 50,
) -> dict:
    sessions = await store.list(limit=limit)
    return {"sessions": [_session_to_dict(s) for s in sessions]}


async def tool_summarize_session(
    store: SessionStore,
    client: HermesClient,
    *,
    session_id: str,
) -> dict:
    s = await store.get(session_id)
    if s is None:
        return {"error": f"session {session_id!r} not found"}
    summary = await client.chat(
        hermes_session_id=s.hermes_session_id, prompt=_SUMMARY_PROMPT
    )
    await store.set_summary(s.id, summary)
    await store.touch(s.id, increment_messages=False)
    return {"session_id": s.id, "summary": summary}


async def tool_delete_session(
    store: SessionStore,
    client: HermesClient,  # noqa: ARG001
    *,
    session_id: str,
) -> dict:
    deleted = await store.delete(session_id)
    return {"deleted": deleted}
