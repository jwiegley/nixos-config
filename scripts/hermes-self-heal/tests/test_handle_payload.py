"""Integration tests for handle_alertmanager_payload.

These tests monkeypatch run_action, call_litellm, _kick_health_check,
emit_synthetic_alert, and the textfile so that no I/O escapes the test.
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import daemon
import pytest
from datetime import datetime, timezone


@pytest.fixture(autouse=True)
def no_sleep(monkeypatch):
    monkeypatch.setattr("time.sleep", lambda s: None)


@pytest.fixture(autouse=True)
def stub_microvm_ts(monkeypatch):
    """Avoid subprocess calls to systemctl in tests."""
    monkeypatch.setattr(daemon, "microvm_active_enter_ts", lambda *a, **kw: 1000)


def _payload(alertname):
    return {
        "alerts": [{
            "status": "firing",
            "labels": {"alertname": alertname},
            "startsAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }]
    }


def test_unknown_alert_is_ignored(monkeypatch, tmp_path):
    """Spec §6.2 — no default fallback."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)

    actions_called = []
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: actions_called.append(a) or {"ok": True})

    daemon.handle_alertmanager_payload(_payload("HermesApiKeyMissing"))
    assert actions_called == []


def test_first_attempt_uses_deterministic_action(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "emit_synthetic_alert", lambda *a, **kw: None)

    actions = []
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: actions.append(a) or {"ok": True})

    daemon.handle_alertmanager_payload(_payload("HermesMcpBridgeDown"))
    assert actions == ["restart_mcp"]


def test_third_attempt_calls_ai(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "emit_synthetic_alert", lambda *a, **kw: None)
    monkeypatch.setattr(daemon, "_err_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "_out_tail", lambda *a, **kw: "")

    ai_calls = []

    def fake_ai(messages, **kw):
        ai_calls.append(messages)
        return {"action": "restart_mcp", "reason": "fake"}

    monkeypatch.setattr(daemon, "call_litellm", fake_ai)
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: {"ok": False, "notes": "stub"})

    # Simulate three fires of the same alert
    import time as _time
    for _ in range(3):
        daemon.handle_alertmanager_payload(_payload("HermesAskFailing"))
        _time.sleep(0.01)  # nudge starts_at; sleep stub makes this a no-op anyway

    # First attempt is deterministic, attempts 2-3 use AI
    assert len(ai_calls) >= 1


def test_fourth_attempt_marks_stuck(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "_err_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "_out_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "call_litellm", lambda *a, **kw: {"action": "restart_mcp", "reason": "fake"})
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: {"ok": False})

    synth_alerts = []
    monkeypatch.setattr(daemon, "emit_synthetic_alert",
                        lambda name, ann, **kw: synth_alerts.append((name, ann)))

    # Reset state and drive 4 calls
    state = {"active": {}, "history": []}
    daemon.save_state(state_path, state)
    for _ in range(4):
        daemon.handle_alertmanager_payload(_payload("HermesAskFailing"))

    stuck_names = [n for n, _ in synth_alerts]
    assert "HermesSelfHealStuck" in stuck_names


def test_gateway_unreachable_marks_stuck(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "_err_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "_out_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: {"ok": False})

    def fake_ai(*a, **kw):
        raise daemon.GatewayUnreachable("connection refused")

    monkeypatch.setattr(daemon, "call_litellm", fake_ai)

    synth = []
    monkeypatch.setattr(daemon, "emit_synthetic_alert",
                        lambda name, ann, **kw: synth.append(name))

    # Two attempts: 1st deterministic, 2nd AI (which fails)
    for _ in range(2):
        daemon.handle_alertmanager_payload(_payload("HermesAskFailing"))

    assert "HermesSelfHealGatewayUnreachable" in synth


# ---- circuit breaker (recent_action_count) ----
# Regression guard for the same unbounded-restart class OpenClaw hit
# 2026-07-22: restart_microvm resets the alert, so each episode is a fresh
# single-attempt incident and the per-incident stuck check never trips. The
# breaker bounds real actions in a rolling window regardless of correlation.


def test_recent_action_count_sums_real_actions_in_window():
    now = 1_000_000
    state = {
        "active": {"a": {"attempts": [{"ts": now - 10, "action": "restart_microvm"},
                                      {"ts": now - 20, "action": "restart_mcp"}]}},
        "history": [{"attempts": [{"ts": now - 30, "action": "restart_microvm"}]}],
    }
    assert daemon.recent_action_count(state, now=now) == 3


def test_recent_action_count_ignores_aged_out_and_placeholder():
    now = 1_000_000
    state = {
        "active": {
            "old":         {"attempts": [{"ts": now - daemon.CIRCUIT_WINDOW_S - 1,
                                          "action": "restart_microvm"}]},
            "placeholder": {"attempts": [{"ts": now - 5, "action": "none"}]},
            "recent":      {"attempts": [{"ts": now - 5, "action": "restart_microvm"}]},
        },
        "history": [],
    }
    assert daemon.recent_action_count(state, now=now) == 1


def test_circuit_breaker_stops_after_budget(monkeypatch, tmp_path):
    """Once CIRCUIT_MAX_ATTEMPTS real remediations have happened in the window,
    a further firing alert is NOT acted on — it is marked stuck and pages
    HermesSelfHealStuck instead of restarting the VM again."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)

    import time as _time
    now = int(_time.time())
    seed = {
        "active": {
            f"ep{i}": {"status": "in_progress", "first_seen_ts": now - 100,
                       "vm_active_enter_ts": 1000 + i,
                       "alerts": ["HermesApiServerDown"],
                       "attempts": [{"ts": now - 10 * (i + 1),
                                     "action": "restart_microvm",
                                     "by": "deterministic", "ok": True}]}
            for i in range(daemon.CIRCUIT_MAX_ATTEMPTS)
        },
        "history": [],
    }
    daemon.save_state(state_path, seed)

    ran = []
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: ran.append(a) or {"ok": True})
    synth = []
    monkeypatch.setattr(daemon, "emit_synthetic_alert",
                        lambda name, ann, **kw: synth.append(name))

    daemon.handle_alertmanager_payload(_payload("HermesApiServerDown"))
    assert ran == []
    assert "HermesSelfHealStuck" in synth
    persisted = daemon.load_state(str(state_path))
    assert any(i.get("stuck_reason") == "circuit_breaker"
               for i in persisted["active"].values())
