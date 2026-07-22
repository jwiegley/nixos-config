import oss_secretary.report as report
from tests.test_delta import _t


def _patch(monkeypatch, tmp_path, sendmail_rc=0, threads=None):
    monkeypatch.setenv("OSS_SECRETARY_STATE_DB", str(tmp_path / "s.db"))
    for v in ("GITHUB_TOKEN_FILE", "GITEA_TOKEN_FILE", "HERMES_ENV_FILE"):
        f = tmp_path / v
        f.write_text("API_SERVER_KEY=k\n")
        monkeypatch.setenv(f"OSS_SECRETARY_{v}", str(f))
    monkeypatch.setenv("OSS_SECRETARY_DRY_RUN", "")   # exercise deliver()
    monkeypatch.setattr(report, "_collect",
                        lambda cfg, state, cov, gh, gt: (threads or [], []))
    # keep hermetic: no real comment-fetch HTTP during enrichment
    monkeypatch.setattr(report, "_enrich",
                        lambda deltas, gh, gt, owners, now_iso: None)
    monkeypatch.setattr(report, "call_hermes",
                        lambda cfg, p: '{"attention":[],"notes":""}')
    monkeypatch.setattr(report, "_sendmail", lambda raw, cfg: sendmail_rc)


def test_first_run_is_baseline_no_error(monkeypatch, tmp_path):
    _patch(monkeypatch, tmp_path, threads=[_t()])
    assert report.main() == 0
    from oss_secretary.state import State
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.baseline_established() is True
    assert st.get_thread("github", "I_1") is not None
    st.close()


def test_state_rolled_back_when_sendmail_fails(monkeypatch, tmp_path):
    # baseline first
    _patch(monkeypatch, tmp_path, threads=[_t()]); report.main()
    # second run: sendmail fails -> new thread must NOT persist
    _patch(monkeypatch, tmp_path, sendmail_rc=1, threads=[_t(), _t(node="I_9", n=9)])
    assert report.main() != 0
    from oss_secretary.state import State
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.get_thread("github", "I_9") is None    # rolled back
    st.close()


def test_second_run_commits_and_advances_watermark(monkeypatch, tmp_path):
    _patch(monkeypatch, tmp_path, threads=[_t()]); report.main()   # baseline
    _patch(monkeypatch, tmp_path, threads=[_t(), _t(node="I_9", n=9)])
    assert report.main() == 0
    from oss_secretary.state import State
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.get_thread("github", "I_9") is not None            # committed
    assert st.get_meta("github_last_poll_utc") is not None       # watermark set
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
    assert "ghp_SUPERSECRETTOKEN" not in caplog.text   # redacted
