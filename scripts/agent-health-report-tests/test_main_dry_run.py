import datetime as dt

from conftest import load_report_module

m = load_report_module()

NOW = dt.datetime(2026, 6, 1, 6, 0, 0)


def _fake_data(profile):
    return {
        "host": "vulcan",
        "now": NOW,
        "live": {},
        "live_selfheal": {},
        "servers": {},
        "uptime": {u: {"active": "active", "since": "Sat", "n_restarts": 0}
                   for u in profile["units"]},
        "probes": [{**f, "success_ratio": None, "p50_seconds": None,
                    "p95_seconds": None, "available": False}
                   for f in profile["probe_families"]],
        "discord": {"counts": {t: 0 for t in m.EVENT_KEYWORDS}, "latest": {}},
        "errors": {"total": 0, "patterns": []},
        "incidents": {"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        "invm": {"skipped": True, "reason": "test", "results": {}},
    }


def _run(monkeypatch, capsys, agent):
    prefix = m.PROFILES[agent]["env_prefix"]
    monkeypatch.setenv(f"{prefix}_DRY_RUN", "1")
    # collect must NOT touch the network/subprocess in a dry run.
    monkeypatch.setattr(m, "collect", lambda p: _fake_data(p))
    rc = m.main(["--agent", agent])
    out = capsys.readouterr().out
    assert rc == 0
    return out


def test_main_dry_run_openclaw(monkeypatch, capsys):
    out = _run(monkeypatch, capsys, "openclaw")
    assert "Subject: [openclaw-nightly]" in out
    assert "OpenClaw health report" in out
    assert "Headline" in out
    for h in ("Live metrics", "MCP servers", "In-VM corroboration"):
        assert h in out


def test_main_dry_run_hermes(monkeypatch, capsys):
    out = _run(monkeypatch, capsys, "hermes")
    assert "Subject: [hermes-nightly]" in out
    assert "Hermes health report" in out
    assert "Headline" in out
    for h in ("Live metrics", "MCP servers", "In-VM corroboration"):
        assert h in out


def test_main_rejects_unknown_agent(monkeypatch):
    import pytest
    with pytest.raises(SystemExit):
        m.main(["--agent", "nope"])
