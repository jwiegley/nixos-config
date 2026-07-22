from oss_secretary.gitea import GiteaCollector
from oss_secretary.models import Repo
from tests.test_github import FakeClient, _cfg


def test_gitea_repos_bare_array_and_issue_ids_stringified():
    fc = FakeClient({"/users/johnw/repos": [
        {"id": 11, "full_name": "johnw/bar", "name": "bar",
         "owner": {"login": "johnw"}, "private": False, "html_url": "h"}]})
    gt = GiteaCollector(fc, _cfg())
    repos = gt.list_repos()
    assert repos[0].platform == "gitea" and repos[0].node_id == "11"


def test_gitea_skips_mirror_repos():
    fc = FakeClient({"/users/johnw/repos": [
        {"id": 1, "full_name": "johnw/real", "name": "real",
         "owner": {"login": "johnw"}, "private": False, "html_url": "h", "mirror": False},
        {"id": 2, "full_name": "johnw/backup", "name": "backup",
         "owner": {"login": "johnw"}, "private": False, "html_url": "h", "mirror": True}]})
    gt = GiteaCollector(fc, _cfg())
    assert [r.full_name for r in gt.list_repos()] == ["johnw/real"]   # mirror skipped


def test_gitea_pull_request_field_classifies_pr():
    pages = {"/repos/johnw/bar/issues": [
        {"id": 5, "number": 5, "title": "q", "html_url": "h", "state": "open",
         "closed_at": None, "comments": 1, "updated_at": "2026-07-20T00:00:00Z",
         "user": {"login": "bob"}, "pull_request": {"merged": False}}]}
    gt = GiteaCollector(FakeClient(pages), _cfg())
    repo = Repo("gitea", "johnw/bar", "johnw", "bar", "11", False, "h")
    ts = gt.list_threads(repo, since=None)
    assert ts[0].kind == "pr" and ts[0].node_id == "5"
