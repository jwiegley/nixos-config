from __future__ import annotations
import fcntl
import os
import sqlite3

SCHEMA_VERSION = 1
_THREAD_COLS = [
    "platform", "node_id", "repo_full_name", "number", "kind", "title",
    "html_url", "state", "closed_at", "comment_count", "last_comment_id",
    "last_comment_at", "last_commenter", "author_association", "updated_at",
    "first_seen_run", "last_seen_run",
]


class State:
    def __init__(self, db_path):
        self.db_path = db_path
        self._db = None
        self._lock_fd = None

    def open(self):
        d = os.path.dirname(self.db_path)
        if d:
            os.makedirs(d, exist_ok=True)
        os.umask(0o077)
        self._db = sqlite3.connect(self.db_path)
        self._db.row_factory = sqlite3.Row
        self._db.executescript(f"""
        CREATE TABLE IF NOT EXISTS threads (
          platform TEXT NOT NULL CHECK(platform IN ('github','gitea')),
          node_id TEXT NOT NULL, repo_full_name TEXT NOT NULL, number INTEGER NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('issue','pr')), title TEXT, html_url TEXT,
          state TEXT NOT NULL, closed_at TEXT, comment_count INTEGER NOT NULL DEFAULT 0,
          last_comment_id TEXT, last_comment_at TEXT, last_commenter TEXT,
          author_association TEXT, updated_at TEXT,
          first_seen_run INTEGER NOT NULL, last_seen_run INTEGER NOT NULL,
          PRIMARY KEY (platform, node_id));
        CREATE TABLE IF NOT EXISTS http_cache (
          url TEXT PRIMARY KEY, etag TEXT, last_modified TEXT, fetched_at TEXT);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS run_summaries (
          run_id INTEGER PRIMARY KEY, created_at TEXT, summary TEXT);
        """)
        if self.get_meta("schema_version") is None:
            self.set_meta("schema_version", str(SCHEMA_VERSION))
        self.commit()

    def acquire_lock(self):
        self._lock_fd = open(self.db_path + ".lock", "w")
        try:
            fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def baseline_established(self):
        return self.get_meta("baseline_established_at") is not None

    def mark_baseline(self, ts):
        self.set_meta("baseline_established_at", ts)

    def get_thread(self, platform, node_id):
        r = self._db.execute(
            "SELECT * FROM threads WHERE platform=? AND node_id=?",
            (platform, node_id)).fetchone()
        return dict(r) if r else None

    def upsert_thread(self, row):
        cols = ",".join(_THREAD_COLS)
        ph = ",".join("?" for _ in _THREAD_COLS)
        upd = ",".join(f"{c}=excluded.{c}" for c in _THREAD_COLS
                       if c not in ("platform", "node_id", "first_seen_run"))
        self._db.execute(
            f"INSERT INTO threads ({cols}) VALUES ({ph}) "
            f"ON CONFLICT(platform,node_id) DO UPDATE SET {upd}",
            [row[c] for c in _THREAD_COLS])

    def open_threads(self):
        return [dict(r) for r in self._db.execute(
            "SELECT * FROM threads WHERE state='open'")]

    def cache_get(self, url):
        r = self._db.execute(
            "SELECT etag,last_modified FROM http_cache WHERE url=?", (url,)).fetchone()
        return (r["etag"], r["last_modified"]) if r else (None, None)

    def cache_set(self, url, etag, lm):
        self._db.execute(
            "INSERT INTO http_cache(url,etag,last_modified,fetched_at) "
            "VALUES(?,?,?,datetime('now')) ON CONFLICT(url) DO UPDATE SET "
            "etag=excluded.etag,last_modified=excluded.last_modified,"
            "fetched_at=excluded.fetched_at", (url, etag, lm))

    def get_meta(self, key):
        r = self._db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return r["value"] if r else None

    def set_meta(self, key, value):
        self._db.execute(
            "INSERT INTO meta(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))

    def next_run_id(self):
        cur = int(self.get_meta("last_run_id") or "0") + 1
        self.set_meta("last_run_id", cur)
        return cur

    def save_run_summary(self, run_id, summary):
        self._db.execute(
            "INSERT OR REPLACE INTO run_summaries(run_id,created_at,summary) "
            "VALUES(?,datetime('now'),?)", (run_id, summary))

    def commit(self):
        self._db.commit()

    def rollback(self):
        self._db.rollback()

    def close(self):
        if self._db:
            self._db.close()
        if self._lock_fd:
            self._lock_fd.close()
