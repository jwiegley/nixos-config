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
