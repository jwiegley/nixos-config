import daemon
import pytest


def test_allowlist_is_exactly_the_authorized_actions():
    """Guard test: ACTION_ALLOWLIST must exactly match the spec.

    If this ever fails, the sudoers entries in
    modules/services/hermes-self-heal.nix likely need to be updated in
    lockstep — and so does the Hermes self-heal spec.
    """
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm",
        "restart_mcp",
        "restage_secrets",
        "reset_credential_pool",
        "restart_health_check",
    )


def test_webhook_port_is_9098():
    assert daemon.WEBHOOK_PORT == 9098


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


def test_correlation_key_groups_by_vm_boot():
    a = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "HermesApiServerDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)


def test_correlation_key_differs_after_vm_restart():
    a = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 2000, "starts_at": 5000}
    assert daemon.correlation_key(a) != daemon.correlation_key(b)


def test_new_incident_starts_in_progress():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing",
                               "vm_active_enter_ts": 1000})
    assert inc["status"] == "in_progress"
    assert inc["attempts"] == []
    assert inc["alerts"] == ["HermesAskFailing"]


def test_next_attempt_n_starts_at_one():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    assert daemon.next_attempt_n(inc) == 1


def test_next_attempt_n_increments():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    inc["attempts"].append({"action": "restart_microvm", "by": "deterministic"})
    assert daemon.next_attempt_n(inc) == 2


def test_should_escalate_after_three_attempts():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    assert not daemon.should_escalate(inc)
    inc["attempts"].extend([{}, {}, {}])
    assert daemon.should_escalate(inc)


def test_state_round_trip(tmp_path):
    state = {"active": {"k": {"status": "in_progress", "attempts": []}}, "history": []}
    p = tmp_path / "incidents.json"
    daemon.save_state(p, state)
    assert daemon.load_state(p) == state


def test_load_state_returns_empty_when_file_missing(tmp_path):
    p = tmp_path / "does-not-exist.json"
    assert daemon.load_state(p) == {"active": {}, "history": []}


def test_action_map_deterministic_first_attempts():
    """Spec §6.2 — verify the deterministic-first-attempt map exactly."""
    assert daemon.ACTION_MAP == {
        "HermesAskFailing":             "restart_microvm",
        "HermesApiServerDown":          "restart_microvm",
        "HermesDiscordZombieSuspected": "restart_microvm",
        "HermesMcpBridgeDown":          "restart_mcp",
        "HermesHealthCheckStale":       "restart_health_check",
    }


def test_first_attempt_action_returns_none_for_unknown_alert():
    """Divergence from OpenClaw: NO default fallback. Spec §6.2 explicit decision."""
    assert daemon.first_attempt_action("SomeNewAlertNobodyMapped") is None


def test_first_attempt_action_returns_action_for_known_alert():
    assert daemon.first_attempt_action("HermesAskFailing") == "restart_microvm"


def test_first_attempt_action_does_NOT_default_for_HermesApiKeyMissing():
    """HermesApiKeyMissing routes here because it has service=hermes-mcp,
    but no allowlisted action can fix a SOPS plumbing failure — defaulting
    would consume the AI tier and end at stuck."""
    assert daemon.first_attempt_action("HermesApiKeyMissing") is None


def test_redact_discord_token():
    s = "Bot is online with token DISCORD_TOKEN_REDACTED OK"
    out = daemon.redact(s)
    assert "NTk5MTYzMTM1OTUwNDMyNTc3" not in out
    assert "[REDACTED]" in out


def test_redact_anthropic_key():
    out = daemon.redact("loaded sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz1234567890")
    assert "sk-ant" not in out
    assert "[REDACTED]" in out


def test_redact_bearer():
    out = daemon.redact("Authorization: Bearer eyJhbGciOiJIUzI1NiIs.abc.def")
    assert "eyJhbGc" not in out
    assert "[REDACTED]" in out


def test_redact_generic_token_assignment():
    out = daemon.redact("config: api_key=sk-proj-xxxxxxxxxxx, password=hunter2")
    assert "sk-proj" not in out
    assert "hunter2" not in out


def test_redact_preserves_non_secret_text():
    s = "Discord WS connected, 12 events received in last 60s"
    assert daemon.redact(s) == s


def test_run_action_rejects_non_allowlisted(monkeypatch):
    with pytest.raises(daemon.ActionRejectedError):
        daemon.run_action("rm_rf_slash")


def test_run_action_parses_last_line_as_json(monkeypatch):
    import subprocess

    class FakeResult:
        returncode = 0
        stdout = 'some chatter\n{"ok": true, "notes": "did it"}\n'
        stderr = ""

    def fake_run(*a, **kw):
        return FakeResult()

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert result == {"ok": True, "notes": "did it"}


def test_run_action_handles_timeout(monkeypatch):
    import subprocess

    def fake_run(*a, **kw):
        raise subprocess.TimeoutExpired(cmd="x", timeout=240)

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm", timeout_s=240)
    assert result == {"ok": False, "notes": "action timed out", "duration_s": 240}


def test_run_action_handles_non_json_output(monkeypatch):
    import subprocess

    class FakeResult:
        returncode = 1
        stdout = "raw error text not json\n"
        stderr = "bad stuff happened"

    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: FakeResult())
    result = daemon.run_action("restart_microvm")
    assert result["ok"] is False
    assert "non-json" in result["notes"]
