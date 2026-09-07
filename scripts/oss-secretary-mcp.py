"""Read-only MCP access to the open-source-secretary triage database.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add
one here or flake8 flags it as E265.

WHY THIS EXISTS. open-source-secretary already maintains a materialised,
deduplicated, mirror-filtered view of ~270 GitHub and Gitea repositories, refreshed
daily at 07:00 and carrying the domain rules (which repos count, what "awaiting
reply" means, what is stale). Answering "what is awaiting my reply on ledger?" from
that table costs one local SQLite query. Answering it from the forges costs a token
inside the VM, two API dialects, pagination, rate-limit backoff -- and the context
that got the GitHub/Gitea MCP servers deleted on 2026-08-05 (3af2dabfb, "the
GitHub/Gitea MCP servers cost too much context").

So the daily email stays deterministic and this exposes only the RESULT of that work
for ad-hoc questions.

WHAT THIS DELIBERATELY IS NOT.

  * Not free-form SQL. Every tool below is a fixed parameterised query. A model that
    can compose arbitrary SQL against a database can exfiltrate every column in it,
    and the point of a read-only view is that its shape is decided here, not by the
    model.
  * Not live. It reads a SNAPSHOT taken after each secretary run, so answers are "as
    of this morning". Querying the live file across virtiofs while the host writes it
    risks a torn read; sqlite3 .backup against a running database does not.
  * Not the whole schema. `http_cache` (10k rows of ETag bookkeeping) and `meta` are
    never exposed -- they answer no question a person would ask and only widen what
    the model can see.

DATA EXPOSED, stated plainly because it becomes model-reachable: repository names,
issue/PR numbers, titles, URLs, open/closed state, comment counts, the last
commenter's username, author_association, and timestamps. Issue and comment BODIES
are not stored by the secretary and so cannot leak here -- titles are the only
third-party free text in the table.
"""

import json
import os
import sqlite3
import sys

DB = os.environ.get(
    "OSS_SECRETARY_SNAPSHOT",
    "/var/lib/hermes/oss-secretary/state.db",
)

# The secretary's own notion of "me", used to decide whether the last comment was
# somebody else's. Kept as env-overridable rather than hardcoded so it tracks the
# service's config instead of drifting from it.
SELF_LOGINS = {
    s.strip().lower()
    for s in os.environ.get("OSS_SECRETARY_SELF_LOGINS", "jwiegley,johnw").split(",")
    if s.strip()
}


def _connect():
    """Open the snapshot strictly read-only.

    mode=ro makes SQLite refuse writes at the VFS layer rather than trusting the
    caller, so a bug here cannot corrupt the snapshot the host maintains.
    """
    if not os.path.exists(DB):
        raise FileNotFoundError(
            f"snapshot not found at {DB}; the host writes it after each "
            "open-source-secretary run"
        )
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True)


def _rows(sql, params=()):
    con = _connect()
    try:
        con.row_factory = sqlite3.Row
        return [dict(r) for r in con.execute(sql, params).fetchall()]
    finally:
        con.close()


_OPEN = "state = 'open'"


def snapshot_age():
    """How stale the data is, so an answer can be qualified rather than implied fresh."""
    con = _connect()
    try:
        row = con.execute(
            "SELECT created_at FROM run_summaries ORDER BY run_id DESC LIMIT 1"
        ).fetchone()
    finally:
        con.close()
    return {
        "snapshot_path": DB,
        "snapshot_mtime": os.path.getmtime(DB),
        "last_run_at": row[0] if row else None,
    }


def awaiting_reply(repo=None, limit=50):
    """Open threads whose last comment came from someone else."""
    sql = (
        "SELECT platform, repo_full_name, number, kind, title, html_url, "
        "comment_count, last_commenter, last_comment_at, updated_at "
        f"FROM threads WHERE {_OPEN} AND last_commenter IS NOT NULL"
    )
    params = []
    if repo:
        sql += " AND repo_full_name LIKE ?"
        params.append(f"%{repo}%")
    sql += " ORDER BY last_comment_at DESC LIMIT ?"
    params.append(min(int(limit), 200))
    return [r for r in _rows(sql, tuple(params))
            if (r.get("last_commenter") or "").lower() not in SELF_LOGINS]


def open_threads(repo=None, kind=None, limit=50):
    """Open issues and/or PRs, most recently updated first."""
    sql = (
        "SELECT platform, repo_full_name, number, kind, title, html_url, "
        f"comment_count, updated_at FROM threads WHERE {_OPEN}"
    )
    params = []
    if repo:
        sql += " AND repo_full_name LIKE ?"
        params.append(f"%{repo}%")
    if kind in ("issue", "pr"):
        sql += " AND kind = ?"
        params.append(kind)
    sql += " ORDER BY updated_at DESC LIMIT ?"
    params.append(min(int(limit), 200))
    return _rows(sql, tuple(params))


def stale_threads(days=30, limit=50):
    """Open threads untouched for N days -- the dropped balls."""
    return _rows(
        "SELECT platform, repo_full_name, number, kind, title, html_url, "
        f"comment_count, updated_at FROM threads WHERE {_OPEN} "
        "AND updated_at IS NOT NULL "
        "AND julianday('now') - julianday(updated_at) > ? "
        "ORDER BY updated_at ASC LIMIT ?",
        (float(days), min(int(limit), 200)),
    )


def repo_summary(limit=100):
    """Per-repository open counts, busiest first."""
    return _rows(
        "SELECT platform, repo_full_name, "
        "SUM(kind = 'issue') AS open_issues, SUM(kind = 'pr') AS open_prs, "
        "COUNT(*) AS open_total, MAX(updated_at) AS last_activity "
        f"FROM threads WHERE {_OPEN} "
        "GROUP BY platform, repo_full_name ORDER BY open_total DESC LIMIT ?",
        (min(int(limit), 300),),
    )


def search_titles(query, include_closed=False, limit=50):
    """Substring search over titles. Titles only -- bodies are not stored."""
    sql = (
        "SELECT platform, repo_full_name, number, kind, title, html_url, state, "
        "updated_at FROM threads WHERE title LIKE ?"
    )
    params = [f"%{query}%"]
    if not include_closed:
        sql += f" AND {_OPEN}"
    sql += " ORDER BY updated_at DESC LIMIT ?"
    params.append(min(int(limit), 200))
    return _rows(sql, tuple(params))


TOOLS = {
    "oss_snapshot_age": (snapshot_age, "How fresh the triage snapshot is."),
    "oss_awaiting_reply": (awaiting_reply, "Open threads whose last comment was someone else's."),
    "oss_open_threads": (open_threads, "Open issues/PRs, newest activity first."),
    "oss_stale_threads": (stale_threads, "Open threads untouched for N days."),
    "oss_repo_summary": (repo_summary, "Per-repo open issue/PR counts."),
    "oss_search_titles": (search_titles, "Substring search over issue/PR titles."),
}


def main():
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        print("mcp package unavailable", file=sys.stderr)
        return 1

    mcp = FastMCP("oss-secretary")
    for name, (fn, doc) in TOOLS.items():
        fn.__doc__ = (fn.__doc__ or doc) + (
            "\n\nReads a daily snapshot of the open-source-secretary triage "
            "database; answers are as of the last run, not live."
        )
        mcp.add_tool(fn, name=name)
    mcp.run()
    return 0


if __name__ == "__main__":
    # Also usable as a CLI for verification without an MCP client:
    #   oss-secretary-mcp --selftest
    if "--selftest" in sys.argv:
        out = {
            "age": snapshot_age(),
            "repo_summary_top3": repo_summary(limit=3),
            "awaiting_reply_count": len(awaiting_reply(limit=200)),
            "stale_30d_count": len(stale_threads(days=30, limit=200)),
        }
        print(json.dumps(out, indent=2, default=str))
        raise SystemExit(0)
    raise SystemExit(main())
