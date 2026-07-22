from __future__ import annotations
from .models import Repo, Thread, NotificationItem
from .redact import redact


def _is_bot(login):
    return bool(login) and (login.endswith("[bot]") or login in {"dependabot", "github-actions"})


class GitHubCollector:
    def __init__(self, client, cfg):
        self.c = client
        self.cfg = cfg

    def list_repos(self):
        repos = []
        if self.cfg.include_private:
            user_path, user_params = "/user/repos", {"affiliation": "owner", "per_page": 100}
            org_params = {"type": "all", "per_page": 100}
        else:
            user_path, user_params = f"/users/{self.cfg.github_user}/repos", {"per_page": 100}
            org_params = {"type": "public", "per_page": 100}
        # conditional=False: enumeration uses static params, so a conditional
        # request could 304 and silently return no repos (skipping the whole
        # scan). Always fetch the full list.
        for r in self.c.paginate(user_path, user_params, conditional=False):
            if r["owner"]["login"].lower() != self.cfg.github_user.lower():
                continue
            repos.append(self._repo(r))
        for r in self.c.paginate(f"/orgs/{self.cfg.github_org}/repos", org_params,
                                 conditional=False):
            repos.append(self._repo(r))
        return repos

    @staticmethod
    def _repo(r):
        return Repo("github", r["full_name"], r["owner"]["login"], r["name"],
                    r["node_id"], r.get("private", False), r["html_url"])

    def list_threads(self, repo, since):
        # state=all so a close→reopen transition is visible (a reopened item
        # comes back as state=open with a stored prior state=closed). The delta
        # layer records closed items and only reports open ones.
        params = {"state": "all", "sort": "updated", "direction": "desc", "per_page": 100}
        if since:
            params["since"] = since
        out = []
        for it in self.c.paginate(f"/repos/{repo.full_name}/issues", params):
            kind = "pr" if it.get("pull_request") else "issue"
            login = (it.get("user") or {}).get("login", "")
            out.append(Thread(
                platform="github", node_id=it["node_id"],
                repo_full_name=repo.full_name, number=it["number"], kind=kind,
                title=redact(it.get("title", "")), html_url=it.get("html_url", ""),
                state=it.get("state", "open"), closed_at=it.get("closed_at"),
                comment_count=int(it.get("comments", 0)),
                # last_* here reflect the opener/updated_at from the list; the
                # real last commenter is filled in by thread_signals() for the
                # small set of changed threads (report._enrich).
                last_comment_id=None, last_comment_at=it.get("updated_at"),
                last_commenter=login, last_commenter_is_bot=_is_bot(login),
                author_association=it.get("author_association"),
                updated_at=it.get("updated_at"),
                body_excerpt=redact((it.get("body") or "")[:600])))
        return out

    def thread_signals(self, repo_full_name, number, owners):
        """Fetch the newest comment + owner-response signal for one thread.

        Returns None on error or no comments (caller keeps the opener-derived
        coarse data). One-off fetch, conditional=False (not cached)."""
        try:
            comments = self.c.paginate(
                f"/repos/{repo_full_name}/issues/{number}/comments",
                {"per_page": 100}, conditional=False)
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
        params = {"all": "false", "per_page": 50}
        if since:
            params["since"] = since
        out = []
        for n in self.c.paginate("/notifications", params):
            subj = n.get("subject", {})
            out.append(NotificationItem(
                platform="github", repo_full_name=n.get("repository", {}).get("full_name", ""),
                subject_type=subj.get("type", ""), subject_title=redact(subj.get("title", "")),
                reason=n.get("reason", ""), html_url=self._html_url(subj.get("url")),
                updated_at=n.get("updated_at"), unread=bool(n.get("unread"))))
        return out

    def _html_url(self, api_url):
        if not api_url:
            return None
        try:
            body, _ = self.c.get(api_url, conditional=False)
            return (body or {}).get("html_url")
        except Exception:
            return None
