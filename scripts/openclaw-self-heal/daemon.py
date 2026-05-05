#!/usr/bin/env python3
"""openclaw-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-05-openclaw-self-heal-design.md.
"""
__version__ = "0.1.0"

ACTION_ALLOWLIST = ("restart_microvm", "doctor_fix", "prune_stale_plugin_deps")
WEBHOOK_PORT = 9092


class ActionRejectedError(ValueError):
    """Raised when a proposed action is not in the allowlist."""


def validate_action(name: str) -> str:
    """Return name if it's in the allowlist, else raise ActionRejectedError.

    Defense-in-depth: even if the AI returns garbage, the runner will reject.
    """
    if name in ACTION_ALLOWLIST:
        return name
    raise ActionRejectedError(f"action not allowlisted: {name!r}")
