"""SQLite-backed session metadata store.

Holds OUR side of the session bookkeeping (id, name, last-used, count,
cached summary).  The actual conversation history lives inside Hermes
itself and is keyed by `hermes_session_id`, which we mint locally
(uuid4, see `create()`) and send on every request in the
`X-Hermes-Session-Id` request header.
"""
from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from pathlib import Path

import aiosqlite

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    name TEXT,
    hermes_session_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    last_used_at REAL NOT NULL,
    message_count INTEGER NOT NULL DEFAULT 0,
    summary TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_last_used ON sessions(last_used_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_name ON sessions(name) WHERE name IS NOT NULL;
"""


@dataclass(frozen=True)
class Session:
    id: str
    name: str | None
    hermes_session_id: str
    created_at: float
    last_used_at: float
    message_count: int
    summary: str | None


class SessionStore:
    def __init__(self, db_path: Path):
        self._db_path = db_path

    async def init(self) -> None:
        async with aiosqlite.connect(self._db_path) as db:
            await db.executescript(_SCHEMA)
            await db.commit()

    async def create(self, name: str | None = None) -> Session:
        now = time.time()
        sid = uuid.uuid4().hex
        hid = uuid.uuid4().hex  # what we'll send as X-Hermes-Session-Id
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "INSERT INTO sessions (id, name, hermes_session_id, created_at, "
                "last_used_at, message_count, summary) VALUES (?, ?, ?, ?, ?, 0, NULL)",
                (sid, name, hid, now, now),
            )
            await db.commit()
        return Session(sid, name, hid, now, now, 0, None)

    async def get(self, session_id: str) -> Session | None:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cur = await db.execute(
                "SELECT * FROM sessions WHERE id = ?", (session_id,)
            )
            row = await cur.fetchone()
            return _row_to_session(row) if row else None

    async def get_by_name(self, name: str) -> Session | None:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cur = await db.execute(
                "SELECT * FROM sessions WHERE name = ? ORDER BY last_used_at DESC LIMIT 1",
                (name,),
            )
            row = await cur.fetchone()
            return _row_to_session(row) if row else None

    async def list(self, limit: int = 50) -> list[Session]:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cur = await db.execute(
                "SELECT * FROM sessions ORDER BY last_used_at DESC LIMIT ?", (limit,)
            )
            rows = await cur.fetchall()
            return [_row_to_session(r) for r in rows]

    async def touch(self, session_id: str, *, increment_messages: bool = True) -> None:
        now = time.time()
        delta = 1 if increment_messages else 0
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "UPDATE sessions SET last_used_at = ?, message_count = message_count + ? "
                "WHERE id = ?",
                (now, delta, session_id),
            )
            await db.commit()

    async def set_summary(self, session_id: str, summary: str) -> None:
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "UPDATE sessions SET summary = ? WHERE id = ?", (summary, session_id)
            )
            await db.commit()

    async def delete(self, session_id: str) -> bool:
        async with aiosqlite.connect(self._db_path) as db:
            cur = await db.execute(
                "DELETE FROM sessions WHERE id = ?", (session_id,)
            )
            await db.commit()
            return cur.rowcount > 0


def _row_to_session(row: aiosqlite.Row) -> Session:
    return Session(
        id=row["id"],
        name=row["name"],
        hermes_session_id=row["hermes_session_id"],
        created_at=row["created_at"],
        last_used_at=row["last_used_at"],
        message_count=row["message_count"],
        summary=row["summary"],
    )
