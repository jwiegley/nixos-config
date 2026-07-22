from __future__ import annotations
from .models import Repo, Thread, NotificationItem
from .redact import redact
from .github import _is_bot


class GiteaCollector:
    def __init__(self, client, cfg):
        self.c = client
        self.cfg = cfg

    def list_repos(self):
        out = []
        # conditional=False: enumeration must always return the full set.
        # Skip MIRRORS: johnw's Gitea mirrors his GitHub repos (which are scanned
        # comprehensively on the GitHub side), so their trackers carry no unique
        # issues. Scanning all ~190 (160 mirrors) also bursts gitea.vulcan.lan
        # into rate-limiting; the ~30 canonical (non-mirror) repos are his actual
        # Gitea projects and scan cleanly.
        for r in self.c.paginate(f"/users/{self.cfg.gitea_user}/repos",
                                 {"limit": 50}, conditional=False):
            if r.get("mirror"):
                continue
            out.append(Repo("gitea", r["full_name"], r["owner"]["login"], r["name"],
                            str(r["id"]), r.get("private", False), r.get("html_url", "")))
        return out

    def list_threads(self, repo, since):
        # state=all so close→reopen transitions are visible (see github.py).
        params = {"state": "all", "type": "issues", "limit": 50}
        if since:
            params["since"] = since
        out = []
        for typ in ("issues", "pulls"):
            params["type"] = typ
            for it in self.c.paginate(f"/repos/{repo.full_name}/issues", dict(params)):
                kind = "pr" if it.get("pull_request") else ("pr" if typ == "pulls" else "issue")
                login = (it.get("user") or {}).get("login", "")
                out.append(Thread(
                    platform="gitea", node_id=str(it["id"]),
                    repo_full_name=repo.full_name, number=it["number"], kind=kind,
                    title=redact(it.get("title", "")), html_url=it.get("html_url", ""),
                    state=it.get("state", "open"), closed_at=it.get("closed_at"),
                    comment_count=int(it.get("comments", 0)),
                    last_comment_id=None, last_comment_at=it.get("updated_at"),
                    last_commenter=login, last_commenter_is_bot=_is_bot(login),
                    author_association=None, updated_at=it.get("updated_at"),
                    body_excerpt=redact((it.get("body") or "")[:600])))
        # de-dup by node_id (an item can appear under both type filters)
        seen, uniq = set(), []
        for t in out:
            if t.node_id in seen:
                continue
            seen.add(t.node_id)
            uniq.append(t)
        return uniq

    def thread_signals(self, repo_full_name, number, owners):
        """Newest comment + owner-response for one Gitea thread (None on error/empty)."""
        try:
            comments = self.c.paginate(
                f"/repos/{repo_full_name}/issues/{number}/comments",
                {"limit": 50}, conditional=False)
        except Exception:
            return None
        if not comments:
            return None
        last = comments[-1]
        login = (last.get("user") or {}).get("login", "")
        has_owner = any(
            (((c.get("user") or {}).get("login", "") or "").lower() in owners)
            for c in comments)
        return {
            "last_commenter": login,
            "last_commenter_is_bot": _is_bot(login),
            "last_comment_id": str(last.get("id")),
            "last_comment_at": last.get("created_at"),
            "body_excerpt": redact((last.get("body") or "")[:600]),
            "has_owner_response": has_owner,
        }

    def list_notifications(self, since):
        params = {"limit": 50}
        if since:
            params["since"] = since
        out = []
        for n in self.c.paginate("/notifications", params):
            subj = n.get("subject", {})
            out.append(NotificationItem(
                platform="gitea", repo_full_name=n.get("repository", {}).get("full_name", ""),
                subject_type=subj.get("type", ""), subject_title=redact(subj.get("title", "")),
                reason="", html_url=subj.get("html_url"),
                updated_at=n.get("updated_at"), unread=bool(n.get("unread"))))
        return out
