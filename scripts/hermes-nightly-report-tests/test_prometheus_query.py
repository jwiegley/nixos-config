from conftest import load_report_module


def test_prometheus_query_returns_value(monkeypatch):
    import json as _json
    mod = load_report_module()

    class FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): pass
        def read(self):
            return _json.dumps({
                "status": "success",
                "data": {
                    "resultType": "vector",
                    "result": [{"metric": {}, "value": [1747800000, "0.97"]}],
                },
            }).encode()

    monkeypatch.setattr(mod.urllib.request, "urlopen",
                        lambda *a, **kw: FakeResp())
    result = mod.prometheus_query("avg_over_time(openclaw_hermes_smoke_ok[24h])")
    assert result == 0.97


def test_prometheus_query_returns_none_on_error(monkeypatch):
    mod = load_report_module()

    def fake_urlopen(*a, **kw):
        raise OSError("connection refused")

    monkeypatch.setattr(mod.urllib.request, "urlopen", fake_urlopen)
    assert mod.prometheus_query("any") is None


def test_smoke_summary_uses_three_queries(monkeypatch):
    mod = load_report_module()
    calls = []
    monkeypatch.setattr(mod, "prometheus_query",
                        lambda q: (calls.append(q), 0.5)[1])
    summary = mod.smoke_summary_24h()
    assert len(calls) == 3
    assert any("avg_over_time" in c for c in calls)
    assert any("quantile_over_time(0.5" in c for c in calls)
    assert any("quantile_over_time(0.95" in c for c in calls)
    assert summary["success_ratio"] == 0.5
