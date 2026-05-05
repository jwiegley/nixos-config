import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import daemon
import pytest

def test_allowlist_is_exactly_the_three_authorized_actions():
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm", "doctor_fix", "prune_stale_plugin_deps"
    )

def test_validate_action_accepts_allowlisted():
    for a in daemon.ACTION_ALLOWLIST:
        assert daemon.validate_action(a) == a

def test_validate_action_rejects_unknown():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("rm_rf_slash")

def test_validate_action_rejects_with_args():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("restart_microvm; rm -rf /")

def test_validate_action_rejects_path_traversal():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("../../bin/sh")


import time

def test_correlation_key_groups_by_vm_boot():
    a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "OpenClawDiscordPluginMissing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)

def test_correlation_key_differs_after_vm_restart():
    a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 2000, "starts_at": 5000}
    assert daemon.correlation_key(a) != daemon.correlation_key(b)

def test_attempt_n_starts_at_one_for_new_incident():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    assert daemon.next_attempt_n(inc) == 1

def test_attempt_n_increments_with_recorded_attempts():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    inc["attempts"].append({"action": "restart_microvm", "result": "ok"})
    assert daemon.next_attempt_n(inc) == 2

def test_should_escalate_after_three_attempts():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    inc["attempts"] = [{"x": 1}, {"x": 2}, {"x": 3}]
    assert daemon.should_escalate(inc) is True

def test_should_not_escalate_at_attempt_three():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    inc["attempts"] = [{"x": 1}, {"x": 2}]
    assert daemon.should_escalate(inc) is False

def test_correlation_separates_after_five_minutes_even_with_same_vm_ts():
    a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000,
         "starts_at": 5000}
    b = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000,
         "starts_at": 5400}  # 400 s later, well past 5-min window
    assert daemon.correlation_key(a, window_s=300) != daemon.correlation_key(b, window_s=300)


import json

def test_state_load_returns_default_on_missing_file(tmp_path):
    path = tmp_path / "incidents.json"
    state = daemon.load_state(path)
    assert state == {"active": {}, "history": []}

def test_state_roundtrip(tmp_path):
    path = tmp_path / "incidents.json"
    state = {"active": {"k": {"x": 1}}, "history": [{"y": 2}]}
    daemon.save_state(path, state)
    assert daemon.load_state(path) == state


def test_action_map_each_alert_maps_to_known_action_or_wait():
    for action in daemon.ACTION_MAP.values():
        assert action in daemon.ACTION_ALLOWLIST or action == "wait_60s"

def test_action_map_covers_expected_alerts():
    for a in (
        "OpenClawDiscordWsDown", "OpenClawHttpHealthDown",
        "OpenClawGatewayReadyStale", "OpenClawDiscordPluginMissing",
        "OpenClawPluginInitFailuresPresent", "OpenClawMicroVMDown",
    ):
        assert a in daemon.ACTION_MAP


def test_run_action_invokes_sudo_with_exact_path(monkeypatch):
    calls = []
    def fake_run(cmd, capture_output, text, timeout):
        calls.append(cmd)
        class R: returncode = 0; stdout = '{"ok": true}'; stderr = ""
        return R()
    monkeypatch.setattr(daemon.subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert calls == [[
        "sudo", "-n",
        "/etc/nixos/scripts/openclaw-self-heal/actions/restart_microvm",
    ]]
    assert result["ok"] is True

def test_run_action_rejects_non_allowlisted(monkeypatch):
    monkeypatch.setattr(daemon.subprocess, "run",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not call")))
    with pytest.raises(daemon.ActionRejectedError):
        daemon.run_action("rm_rf_slash")

def test_run_action_handles_nonjson_output(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        class R: returncode = 0; stdout = "not json"; stderr = ""
        return R()
    monkeypatch.setattr(daemon.subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert result["ok"] is False
    assert "non-json" in result["notes"].lower()


def test_render_prompt_includes_alert_and_attempts():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000,
                               "starts_at": 5000})
    inc["alerts"] = ["OpenClawDiscordWsDown"]
    inc["attempts"] = [{"action": "restart_microvm", "by": "deterministic",
                        "result": "ok"}]
    msgs = daemon.render_prompt(inc, metrics={"x": 1}, err_log_tail="oops",
                                out_log_tail="hi")
    assert any("restart_microvm" in m["content"] for m in msgs)
    assert any("OpenClawDiscordWsDown" in m["content"] for m in msgs)
    assert msgs[0]["role"] == "system"

def test_render_prompt_redacts_discord_token_pattern():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1, "starts_at": 1})
    tok = "DISCORD_TOKEN_REDACTED"
    msgs = daemon.render_prompt(inc, metrics={}, err_log_tail=f"got token={tok}",
                                out_log_tail="")
    joined = " ".join(m["content"] for m in msgs)
    assert tok not in joined
    assert "[REDACTED]" in joined


def test_call_litellm_returns_parsed_action(monkeypatch):
    def fake_post(url, headers, data, timeout):
        class R:
            status = 200
            def read(self): return json.dumps({"choices":[{"message":{"content":'{"action": "doctor_fix", "reason": "stale"}'}}]}).encode()
        return R()
    monkeypatch.setattr(daemon, "_http_post_json", fake_post)
    monkeypatch.setenv("LITELLM_KEY", "x")
    out = daemon.call_litellm([{"role":"system","content":"x"}], model="hera/Qwen3.6-27B")
    assert out == {"action": "doctor_fix", "reason": "stale"}
