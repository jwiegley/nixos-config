from conftest import load_report_module

m = load_report_module()


def test_prometheus_query_returns_value(monkeypatch):
    import json as _json

    class FakeResp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

        def read(self):
            return _json.dumps({
                "status": "success",
                "data": {"resultType": "vector",
                         "result": [{"metric": {}, "value": [1747800000, "0.97"]}]},
            }).encode()

    monkeypatch.setattr(m.urllib.request, "urlopen", lambda *a, **kw: FakeResp())
    assert m.prometheus_query("avg_over_time(openclaw_hermes_smoke_ok[24h])") == 0.97


def test_prometheus_query_returns_none_on_error(monkeypatch):
    def boom(*a, **kw):
        raise OSError("connection refused")

    monkeypatch.setattr(m.urllib.request, "urlopen", boom)
    assert m.prometheus_query("any") is None


def test_probe_summary_uses_three_queries(monkeypatch):
    calls = []
    monkeypatch.setattr(m, "prometheus_query",
                        lambda q, base_url=None: (calls.append(q), 0.5)[1])
    summary = m.probe_summary_24h("openclaw_hermes_smoke_ok",
                                  "openclaw_hermes_smoke_duration_seconds")
    assert len(calls) == 3
    assert any("avg_over_time" in c for c in calls)
    assert any("quantile_over_time(0.5" in c for c in calls)
    assert any("quantile_over_time(0.95" in c for c in calls)
    assert summary["success_ratio"] == 0.5
    assert summary["available"] is True


def test_probe_summary_unavailable_when_query_none(monkeypatch):
    monkeypatch.setattr(m, "prometheus_query", lambda q, base_url=None: None)
    summary = m.probe_summary_24h("x_ok", "x_dur")
    assert summary["available"] is False
