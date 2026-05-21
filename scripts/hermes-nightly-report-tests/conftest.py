"""Test fixtures for the hermes nightly report parser tests."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))


def load_report_module():
    """Load the script as `hermes_nightly_report` despite hyphenated filename."""
    spec_path = SCRIPT_DIR / "hermes-nightly-report.py"
    spec = importlib.util.spec_from_file_location(
        "hermes_nightly_report", spec_path
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
