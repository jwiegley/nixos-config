import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import daemon

def test_allowlist_is_exactly_the_three_authorized_actions():
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm", "doctor_fix", "prune_stale_plugin_deps"
    )
