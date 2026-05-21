from conftest import load_report_module


def test_main_dry_run_returns_zero(monkeypatch, capsys, tmp_path):
    mod = load_report_module()
    monkeypatch.setattr(mod, "DRY_RUN", True)
    monkeypatch.setattr(mod, "TEXTFILE", tmp_path / "missing.prom")
    monkeypatch.setattr(mod, "GATEWAY_LOG", tmp_path / "missing.log")
    monkeypatch.setattr(mod, "ERRORS_LOG", tmp_path / "missing.log")
    monkeypatch.setattr(mod, "INCIDENTS_JSON", tmp_path / "missing.json")
    monkeypatch.setattr(mod, "prometheus_query", lambda q: None)
    monkeypatch.setattr(mod, "systemd_uptime", lambda u: {"active": "unknown", "since": None, "n_restarts": None})
    monkeypatch.setattr(mod, "in_vm_probe", lambda: {"skipped": True, "reason": "test", "http_code": None})

    rc = mod.main()
    captured = capsys.readouterr()
    assert rc == 0
    assert "Hermes nightly report" in captured.out
    assert "Headline" in captured.out
