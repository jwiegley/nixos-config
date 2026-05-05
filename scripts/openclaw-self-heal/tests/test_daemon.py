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
