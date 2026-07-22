from __future__ import annotations
from datetime import datetime
from .models import Thread, ThreadDelta, AwaitingBundle


def item_id(t: Thread) -> str:
    sep = "#" if t.kind == "issue" else ("!" if t.platform == "gitea" else "#")
    prefix = "gh" if t.platform == "github" else "gitea"
    return f"{prefix}:{t.repo_full_name}{sep}{t.number}"


def owner_logins(cfg) -> set[str]:
    return {cfg.github_user.lower(), cfg.gitea_user.lower()}


def _hours_since(iso, now_iso):
    if not iso or not now_iso:
        return None
    try:
        a = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        b = datetime.fromisoformat(now_iso.replace("Z", "+00:00"))
        return (b - a).total_seconds() / 3600.0
    except ValueError:
        return None


def build_awaiting(t: Thread, owners: set[str], now_iso: str | None = None) -> AwaitingBundle:
    last = (t.last_commenter or "").lower()
    is_owner = last in owners
    return AwaitingBundle(
        is_last_commenter_owner=is_owner,
        last_actor_is_bot=t.last_commenter_is_bot,
        has_owner_response=is_owner,     # coarse: refined only if comment history fetched
        hours_since_last_human_comment=(None if t.last_commenter_is_bot
                                        else _hours_since(t.last_comment_at, now_iso)),
        author_association=t.author_association,
    )


def _row(t: Thread, run_id, first_seen):
    return dict(platform=t.platform, node_id=t.node_id, repo_full_name=t.repo_full_name,
                number=t.number, kind=t.kind, title=t.title, html_url=t.html_url,
                state=t.state, closed_at=t.closed_at, comment_count=t.comment_count,
                last_comment_id=t.last_comment_id, last_comment_at=t.last_comment_at,
                last_commenter=t.last_commenter, author_association=t.author_association,
                updated_at=t.updated_at, first_seen_run=first_seen, last_seen_run=run_id)


def compute_deltas(state, threads, run_id, baseline, stale_days, owners, now_iso):
    deltas = []
    for t in threads:
        prior = state.get_thread(t.platform, t.node_id)
        first_seen = prior["first_seen_run"] if prior else run_id
        change = None
        if baseline:
            change = None
        elif prior is None:
            change = "new"
        else:
            if prior["state"] == "closed" and t.state == "open":
                change = "reopened"
            elif t.comment_count > prior["comment_count"]:
                change = "new_comment"
            else:
                hrs = _hours_since(t.last_comment_at, now_iso)
                if (not t.last_commenter_is_bot and hrs is not None
                        and hrs > stale_days * 24):
                    change = "stale"
        state.upsert_thread(_row(t, run_id, first_seen))
        if change:
            deltas.append(ThreadDelta(t, change, build_awaiting(t, owners, now_iso)))
    return deltas
