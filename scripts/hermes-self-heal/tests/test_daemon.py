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
