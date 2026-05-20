import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

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
