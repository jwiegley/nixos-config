#!/usr/bin/env python3
"""openclaw-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-05-openclaw-self-heal-design.md.
"""
__version__ = "0.1.0"

ACTION_ALLOWLIST = ("restart_microvm", "doctor_fix", "prune_stale_plugin_deps")
WEBHOOK_PORT = 9092
