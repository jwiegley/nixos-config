from oss_secretary.github import GitHubCollector
from oss_secretary.models import Repo


class FakeClient:
    def __init__(self, pages): self.pages = pages; self.calls = []
    def paginate(self, path, params=None, conditional=True):
        self.calls.append((path, params)); return self.pages.get(path, [])
    def get(self, path, params=None, conditional=True): return self.pages.get(path), {}


def _cfg(**kw):
    from oss_secretary.config import Config
    base = dict(recipient="j", sender="s", sendmail="/x", dry_run=True,
        github_user="jwiegley", github_org="ledger", github_token="t",
        gitea_url="u", gitea_user="johnw", gitea_token="t",
        hermes_url="h", hermes_model="m", hermes_key="k", state_db=":memory:",
        include_private=False, llm_token_budget=12000, stale_days=30)
    base.update(kw); return Config(**base)


def test_issues_and_prs_split_by_pull_request_key():
    pages = {"/repos/jwiegley/foo/issues": [
        {"id": 1, "node_id": "I_1", "number": 3, "title": "bug", "html_url": "h1",
         "state": "open", "closed_at": None, "comments": 2,
         "updated_at": "2026-07-20T00:00:00Z", "author_association": "NONE",
         "user": {"login": "alice"}},
        {"id": 2, "node_id": "PR_2", "number": 4, "title": "fix", "html_url": "h2",
         "state": "open", "closed_at": None, "comments": 0,
         "updated_at": "2026-07-20T00:00:00Z", "author_association": "OWNER",
         "user": {"login": "jwiegley"}, "pull_request": {"url": "x"}},
    ]}
    gh = GitHubCollector(FakeClient(pages), _cfg())
    repo = Repo("github", "jwiegley/foo", "jwiegley", "foo", "R_1", False, "h")
    threads = gh.list_threads(repo, since=None)
    kinds = {t.node_id: t.kind for t in threads}
    assert kinds == {"I_1": "issue", "PR_2": "pr"}


def test_thread_signals_extracts_last_comment_and_owner_response():
    pages = {"/repos/jwiegley/foo/issues/3/comments": [
        {"id": 10, "user": {"login": "alice"}, "created_at": "2026-07-20T00:00:00Z", "body": "first"},
        {"id": 11, "user": {"login": "jwiegley"}, "created_at": "2026-07-21T00:00:00Z", "body": "reply"},
        {"id": 12, "user": {"login": "bob"}, "created_at": "2026-07-22T00:00:00Z", "body": "still broken?"}]}
    gh = GitHubCollector(FakeClient(pages), _cfg())
    sig = gh.thread_signals("jwiegley/foo", 3, {"jwiegley", "johnw"})
    assert sig["last_commenter"] == "bob"          # newest comment, not the opener
    assert sig["last_comment_id"] == "12"
    assert sig["has_owner_response"] is True        # jwiegley commented in-thread


def test_thread_signals_none_when_no_comments():
    gh = GitHubCollector(FakeClient({}), _cfg())
    assert gh.thread_signals("jwiegley/foo", 9, {"jwiegley"}) is None


def test_repo_enumeration_public_default_uses_user_public_endpoint():
    fc = FakeClient({"/users/jwiegley/repos": [
        {"full_name": "jwiegley/foo", "name": "foo",
         "owner": {"login": "jwiegley"}, "node_id": "R_1", "private": False,
         "html_url": "h"}], "/orgs/ledger/repos": []})
    gh = GitHubCollector(fc, _cfg(include_private=False))
    repos = gh.list_repos()
    assert any(r.full_name == "jwiegley/foo" for r in repos)
    assert ("/users/jwiegley/repos", {"per_page": 100}) in fc.calls
