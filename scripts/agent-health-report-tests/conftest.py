"""Test fixtures for the unified agent_health_report engine."""
from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))


def load_report_module():
    """Underscore filename → a plain import works (no importlib needed)."""
    import agent_health_report
    return agent_health_report
