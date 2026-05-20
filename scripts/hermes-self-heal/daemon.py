#!/usr/bin/env python3
"""hermes-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md.
Ported from scripts/openclaw-self-heal/daemon.py with Hermes-specific
action set, alert mapping, metric prefix, and the explicit-ignore behavior
on unknown alerts (NO default fallback — diverges from OpenClaw).
"""
__version__ = "0.1.0"

ACTION_ALLOWLIST = (
    "restart_microvm",
    "restart_mcp",
    "restage_secrets",
    "reset_credential_pool",
    "restart_health_check",
)
WEBHOOK_PORT = 9098
