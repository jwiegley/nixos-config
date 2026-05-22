"""Shared fixtures for flume-autofill tests."""
from __future__ import annotations

import sys
from pathlib import Path

# Make flume_autofill importable when running pytest from the repo root.
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
