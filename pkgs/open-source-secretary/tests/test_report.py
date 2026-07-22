import oss_secretary.report as report
from oss_secretary.delta import build_awaiting
from oss_secretary.models import ThreadDelta
from tests.test_delta import _t, OWNERS


def _env(monkeypatch, tmp_path, dry_run=True, bootstrap=False):
    monkeypatch.setenv("OSS_SECRETARY_STATE_DB", str(tmp_path / "s.db"))
    for v in ("GITHUB_TOKEN_FILE", "GITEA_TOKEN_FILE", "HERMES_ENV_FILE"):
        f = tmp_path / v
        f.write_text("API_SERVER_KEY=k\n")
        monkeypatch.setenv(f"OSS_SECRETARY_{v}", str(f))
    monkeypatch.setenv("OSS_SECRETARY_DRY_RUN", "1" if dry_run else "")
    monkeypatch.setenv("OSS_SECRETARY_BOOTSTRAP", "1" if bootstrap else "")


def _patch(monkeypatch, tmp_path, sendmail_rc=0, threads=None, dry_run=False,
           bootstrap=False):
    _env(monkeypatch, tmp_path, dry_run=dry_run, bootstrap=bootstrap)
    monkeypatch.setattr(report, "_collect",
                        lambda cfg, state, cov, gh, gt: (threads or [], []))
    monkeypatch.setattr(report, "_enrich",
                        lambda deltas, gh, gt, owners, now_iso: None)
    monkeypatch.setattr(report, "call_hermes",
                        lambda cfg, p: '{"attention":[],"notes":""}')
    if not dry_run:
        monkeypatch.setattr(report, "_sendmail", lambda raw, cfg: sendmail_rc)


def test_first_run_reports_everything_comprehensively(monkeypatch, tmp_path, capsys):
    # Default first run is a FULL inventory summary (every open thread is "new"),
    # NOT a silent baseline — and it establishes the baseline for future deltas.
    _patch(monkeypatch, tmp_path, threads=[_t()], dry_run=True)
    assert report.main() == 0
    out = capsys.readouterr().out
    assert "New issues" in out and "#3" in out       # the open thread is listed
    assert "baseline established" not in out.lower()
    from oss_secretary.state import State
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.baseline_established() is True         # baseline recorded
    assert st.get_thread("github", "I_1") is not None
    st.close()


def test_bootstrap_is_silent_seed(monkeypatch, tmp_path, capsys):
    _patch(monkeypatch, tmp_path, threads=[_t()], dry_run=True, bootstrap=True)
    assert report.main() == 0
    assert "baseline established" in capsys.readouterr().out.lower()


def test_state_rolled_back_when_sendmail_fails(monkeypatch, tmp_path):
    _patch(monkeypatch, tmp_path, threads=[_t()]); report.main()   # first run
    # next run: sendmail fails -> a newly-appearing thread must NOT persist
    _patch(monkeypatch, tmp_path, sendmail_rc=1, threads=[_t(), _t(node="I_9", n=9)])
    assert report.main() != 0
    from oss_secretary.state import State
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.get_thread("github", "I_9") is None    # rolled back
    st.close()


def test_second_run_commits_and_advances_watermark(monkeypatch, tmp_path):
    _patch(monkeypatch, tmp_path, threads=[_t()]); report.main()
    _patch(monkeypatch, tmp_path, threads=[_t(), _t(node="I_9", n=9)])
    assert report.main() == 0
    from oss_secretary.state import State
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.get_thread("github", "I_9") is not None
    assert st.get_meta("github_last_poll_utc") is not None
    st.close()


def test_token_never_logged(monkeypatch, tmp_path, caplog):
    _patch(monkeypatch, tmp_path, threads=[_t()])
    tmp = tmp_path / "GITHUB_TOKEN_FILE"
    tmp.write_text("ghp_SUPERSECRETTOKEN\n")
    monkeypatch.setenv("OSS_SECRETARY_GITHUB_TOKEN_FILE", str(tmp))

    def boom(cfg, state, cov, gh, gt):
        raise report.HttpError("boom ghp_SUPERSECRETTOKEN in url")
    monkeypatch.setattr(report, "_collect", boom)
    with caplog.at_level("ERROR"):
        report.main()
    assert "ghp_SUPERSECRETTOKEN" not in caplog.text


def test_enrich_overwrites_opener_derived_awaiting():
    # Locks in the core fix: after enrichment the awaiting bundle reflects the
    # REAL last commenter + owner-response, not the issue opener.
    d = ThreadDelta(_t(last="alice"), "new_comment",
                    build_awaiting(_t(last="alice"), OWNERS))
    assert d.awaiting.has_owner_response is False        # coarse, pre-enrich

    class FakeColl:
        def thread_signals(self, repo, number, owners):
            return {"last_commenter": "jwiegley", "last_commenter_is_bot": False,
                    "last_comment_id": "99", "last_comment_at": "2026-07-22T00:00:00Z",
                    "body_excerpt": "ok", "has_owner_response": True}

    report._enrich([d], FakeColl(), FakeColl(), OWNERS, "2026-07-23T00:00:00Z")
    assert d.thread.last_commenter == "jwiegley"
    assert d.thread.last_comment_id == "99"
    assert d.awaiting.is_last_commenter_owner is True
    assert d.awaiting.has_owner_response is True
