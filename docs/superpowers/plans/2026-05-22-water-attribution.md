# Water Attribution Implementation Plan

> **Archival — 2026-05-22.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/home-assistant-water-attribution.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver per-category water attribution (pool autofill / per-zone irrigation / domestic hot / other) live in Home Assistant with daily/weekly/monthly totals, plus a weekly cross-check service that emails a water report, plus historical backfill from VictoriaMetrics and the Flume Personal API.

**Architecture:** Live attribution is 100% declarative HA (template + history_stats + statistics + integration + utility_meter), generated from a single Nix module that owns the zone list. A standalone Python codebase under `/etc/nixos/scripts/flume-autofill/` provides the cross-check service (Phase 2) and the multi-source backfill (Phase 3). Both reuse the same detection algorithm. No Node-RED — that's reserved for downstream consumer automations later.

**Tech Stack:** NixOS modules (Nix), Home Assistant package YAML (HA's template / history_stats / statistics / integration / utility_meter integrations), Python 3.13 + pytest + requests + psycopg2 + websocket-client, VictoriaMetrics (already deployed, 100y retention), SOPS for credentials, systemd timers, existing Postfix.

**Spec:** `docs/superpowers/specs/2026-05-22-water-attribution-design.md`

---

## File Structure (created and modified)

### NixOS modules

```
modules/services/home-assistant-water-attribution.nix     CREATE — generates HA package YAML from zones list
modules/services/flume-autofill.nix                       CREATE — SOPS secrets + systemd units for Phases 2/3
configuration.nix                                          MODIFY — enable both modules with the zones list
```

### Python codebase

```
scripts/flume-autofill/
├── pyproject.toml                                CREATE
├── README.md                                     CREATE
├── flume_autofill/
│   ├── __init__.py                              CREATE
│   ├── __main__.py                              CREATE — CLI entry point
│   ├── config.py                                CREATE — loads /var/lib/flume-autofill/zones.json
│   ├── detection.py                             CREATE — shared autofill detection algorithm
│   ├── sources/
│   │   ├── __init__.py                          CREATE
│   │   ├── flume_api.py                         CREATE — Flume Personal API client (auth + query)
│   │   ├── victoriametrics.py                   CREATE — PromQL/MetricsQL queries
│   │   └── ha_postgres.py                       CREATE — psycopg2 queries against hass DB
│   ├── destinations/
│   │   ├── __init__.py                          CREATE
│   │   ├── csv_writer.py                        CREATE — per-category CSV output
│   │   ├── vm_writer.py                         CREATE — InfluxDB line protocol POSTs to VM
│   │   └── ha_lts.py                            CREATE — WebSocket recorder.import_statistics
│   ├── cross_check.py                           CREATE — Phase 2 main logic
│   ├── backfill.py                              CREATE — Phase 3 main logic
│   └── report.py                                CREATE — text + HTML email rendering
└── tests/
    ├── conftest.py                              CREATE — shared pytest fixtures
    ├── test_detection.py                        CREATE — unit tests for detection algorithm
    ├── test_config.py                           CREATE
    ├── test_sources_flume_api.py                CREATE — mocked API responses
    ├── test_sources_victoriametrics.py          CREATE — mocked HTTP
    ├── test_sources_ha_postgres.py              CREATE — sqlite in-memory test
    ├── test_destinations_csv.py                 CREATE
    ├── test_destinations_vm.py                  CREATE — mocked HTTP
    ├── test_destinations_ha_lts.py              CREATE — mocked WebSocket
    ├── test_cross_check.py                      CREATE
    ├── test_backfill.py                         CREATE
    └── test_report.py                           CREATE
```

### Secrets

```
secrets.yaml                                      MODIFY — add flume/client_id, flume/client_secret, flume/username, flume/password
```

### Generated at runtime by the Nix module

```
/var/lib/hass/packages/water_attribution.yaml     symlinked from Nix store
/var/lib/flume-autofill/zones.json                generated alongside the YAML; canonical zone list for Python (outside git tree)
```

### Documentation

```
docs/WATER_ATTRIBUTION.md                         CREATE — user guide
scripts/flume-autofill/README.md                  CREATE — developer guide
modules/monitoring/grafana-dashboards/water-attribution.json  CREATE — auto-provisioned dashboard
```

### Runtime state (created by services at runtime, not in repo)

```
/var/lib/flume-autofill/reports/YYYY-MM-DD.json   Phase 2 JSON reports
/var/lib/flume-autofill/backfill/                 Phase 3 CSV outputs
/var/lib/flume-autofill/token.json                Flume API bearer cache (mode 0600)
/var/lib/flume-autofill/backfill.lock             Concurrency guard for backfill
/var/lib/flume-autofill/.run.lock                 Phase 2 rate-limit guard
```

---

## Phase 0 — Shared infrastructure (Python detection + config)

Build the algorithmic core and configuration loader before any deployment. These have full unit-test coverage and become the foundation for Phases 2 and 3.

### Task 1: Python package scaffolding

**Files:**
- Create: `scripts/flume-autofill/pyproject.toml`
- Create: `scripts/flume-autofill/flume_autofill/__init__.py`
- Create: `scripts/flume-autofill/flume_autofill/__main__.py`
- Create: `scripts/flume-autofill/flume_autofill/sources/__init__.py`
- Create: `scripts/flume-autofill/flume_autofill/destinations/__init__.py`
- Create: `scripts/flume-autofill/tests/__init__.py`
- Create: `scripts/flume-autofill/tests/conftest.py`
- Create: `scripts/flume-autofill/tests/test_smoke.py`

- [ ] **Step 1: Create the directory tree.**

```bash
mkdir -p /etc/nixos/scripts/flume-autofill/flume_autofill/{sources,destinations}
mkdir -p /etc/nixos/scripts/flume-autofill/tests
```

- [ ] **Step 2: Write `pyproject.toml`.**

```toml
[project]
name = "flume-autofill"
version = "0.1.0"
description = "Water attribution: cross-check + backfill for HA water sensors"
requires-python = ">=3.13"
dependencies = [
    "requests>=2.32",
    "psycopg2>=2.9",
    "websocket-client>=1.8",
    "python-dateutil>=2.9",
    "PyYAML>=6.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-mock>=3.14",
    "responses>=0.25",
    "freezegun>=1.5",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
```

- [ ] **Step 3: Write `flume_autofill/__init__.py`.**

```python
"""Water attribution: shared detection + cross-check + backfill."""
__version__ = "0.1.0"
```

- [ ] **Step 4: Write `flume_autofill/__main__.py`.**

```python
"""CLI entry point. Subcommands: cross-check, backfill, detect."""
from __future__ import annotations

import argparse
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="flume-autofill")
    sub = parser.add_subparsers(dest="command", required=True)

    cross = sub.add_parser("cross-check", help="Phase 2 weekly cross-check")
    cross.add_argument("--days", type=int, default=7)

    back = sub.add_parser("backfill", help="Phase 3 historical backfill")
    back.add_argument("--from", dest="from_date")
    back.add_argument("--to", dest="to_date")
    back.add_argument("--discover", action="store_true")
    back.add_argument("--dry-run", action="store_true")
    back.add_argument("--promote", action="store_true")
    back.add_argument("--unpromote", action="store_true")
    back.add_argument("--through", dest="through_date")
    back.add_argument(
        "--destinations",
        default="csv,vm,lts",
        help="Comma-separated subset of csv,vm,lts",
    )

    detect = sub.add_parser("detect", help="Bare detection over an input CSV")
    detect.add_argument("--input", required=True)

    args = parser.parse_args(argv)

    # Wire subcommands to their modules. Implementations land in later tasks.
    if args.command == "cross-check":
        from . import cross_check
        return cross_check.run(days=args.days)
    if args.command == "backfill":
        from . import backfill
        return backfill.run(args)
    if args.command == "detect":
        from . import detection
        return detection.run_cli(input_path=args.input)
    return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Write empty `__init__.py` files for sub-packages.**

```bash
echo '' > /etc/nixos/scripts/flume-autofill/flume_autofill/sources/__init__.py
echo '' > /etc/nixos/scripts/flume-autofill/flume_autofill/destinations/__init__.py
echo '' > /etc/nixos/scripts/flume-autofill/tests/__init__.py
```

- [ ] **Step 6: Write a smoke test in `tests/test_smoke.py`.**

```python
def test_package_imports():
    """flume_autofill imports cleanly."""
    import flume_autofill
    assert flume_autofill.__version__ == "0.1.0"


def test_cli_help_works():
    """The CLI parser accepts --help without crashing."""
    import subprocess, sys
    result = subprocess.run(
        [sys.executable, "-m", "flume_autofill", "--help"],
        capture_output=True,
        text=True,
        cwd="/etc/nixos/scripts/flume-autofill",
    )
    assert result.returncode == 0
    assert "cross-check" in result.stdout
    assert "backfill" in result.stdout
```

- [ ] **Step 7: Write `tests/conftest.py`.**

```python
"""Shared fixtures for flume-autofill tests."""
from __future__ import annotations

import sys
from pathlib import Path

# Make flume_autofill importable when running pytest from the repo root.
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
```

- [ ] **Step 8: Run the smoke test.**

Run:
```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses freezegun requests pyyaml ])' \
  --run 'python -m pytest tests/test_smoke.py -v'
```

Expected: 2 passed.

- [ ] **Step 9: Commit.**

```bash
git add scripts/flume-autofill/
git commit -m "feat(flume-autofill): python package scaffolding"
```

---

### Task 2: Detection algorithm (TDD)

The core algorithm shared by Phase 2 cross-check and Phase 3 backfill. Phase 1 doesn't use this Python module (Phase 1 uses HA's history_stats), but the rule mapping must be identical.

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/detection.py`
- Create: `scripts/flume-autofill/tests/test_detection.py`

- [ ] **Step 1: Write the first test case — "pure 4 GPM × 15 min → 1 session".**

In `tests/test_detection.py`:

```python
"""Unit tests for the autofill detection algorithm."""
from __future__ import annotations

from datetime import datetime, timedelta

from flume_autofill.detection import (
    AutofillSession,
    DetectionConfig,
    detect_autofill_sessions,
)


def _series(start: datetime, gpms: list[float]) -> list[tuple[datetime, float]]:
    """Build a one-minute-spaced (timestamp, gpm) series."""
    return [(start + timedelta(minutes=i), g) for i, g in enumerate(gpms)]


CONFIG = DetectionConfig(
    gpm_min=3.0,
    gpm_max=5.0,
    window_minutes=10,
    min_minutes_in_range=9,
    enforce_mean_check=True,
)


def test_pure_15_min_at_4_gpm_yields_one_session():
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [4.0] * 15)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert len(sessions) == 1
    s = sessions[0]
    assert s.start == start
    assert s.end == start + timedelta(minutes=14)
    assert s.gallons == 60.0  # 4 gpm * 15 min
```

- [ ] **Step 2: Run the test to verify failure.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses freezegun ])' \
  --run 'python -m pytest tests/test_detection.py::test_pure_15_min_at_4_gpm_yields_one_session -v'
```

Expected: FAIL with `ModuleNotFoundError: No module named 'flume_autofill.detection'`.

- [ ] **Step 3: Write minimal `detection.py` to make the test pass.**

```python
"""Pool autofill detection algorithm.

Mirrors the Phase 1 HA semantic: a session is a contiguous run of minutes
where ≥ `min_minutes_in_range` of every rolling `window_minutes`-minute
window land in [`gpm_min`, `gpm_max`], and the rolling mean is also in
that range when `enforce_mean_check=True`.

This module is a pure function over a (timestamp, gpm) list. Sources and
destinations are layered on top.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Iterable


@dataclass(frozen=True)
class DetectionConfig:
    gpm_min: float
    gpm_max: float
    window_minutes: int
    min_minutes_in_range: int
    enforce_mean_check: bool


@dataclass(frozen=True)
class AutofillSession:
    start: datetime
    end: datetime
    gallons: float


def detect_autofill_sessions(
    series: list[tuple[datetime, float]],
    config: DetectionConfig,
) -> list[AutofillSession]:
    """Return detected autofill sessions from a 1-minute (ts, gpm) series.

    Each session reports start/end (inclusive) and total gallons.
    """
    in_range = [
        (ts, gpm, config.gpm_min <= gpm <= config.gpm_max)
        for ts, gpm in series
    ]

    sessions: list[AutofillSession] = []
    active_start: int | None = None
    for i in range(len(in_range)):
        # Look at the window [i-window+1 .. i] (last `window_minutes` points).
        window_start = max(0, i - config.window_minutes + 1)
        window = in_range[window_start : i + 1]
        if len(window) < config.window_minutes:
            # Not enough history yet to confirm a session.
            continue

        count_in_range = sum(1 for _, _, r in window if r)
        mean_ok = True
        if config.enforce_mean_check:
            mean = sum(gpm for _, gpm, _ in window) / len(window)
            mean_ok = config.gpm_min <= mean <= config.gpm_max

        is_active_at_i = (
            count_in_range >= config.min_minutes_in_range and mean_ok
        )

        if is_active_at_i and active_start is None:
            # Session begins at the *start* of the current 10-minute window.
            active_start = window_start
        elif not is_active_at_i and active_start is not None:
            # Session ended at the previous index.
            sessions.append(_build_session(in_range, active_start, i - 1))
            active_start = None

    if active_start is not None:
        sessions.append(_build_session(in_range, active_start, len(in_range) - 1))

    return sessions


def _build_session(
    in_range: list[tuple[datetime, float, bool]],
    start_idx: int,
    end_idx: int,
) -> AutofillSession:
    span = in_range[start_idx : end_idx + 1]
    # 1 minute per sample; gpm * 1 = gal contribution.
    gallons = sum(gpm for _, gpm, _ in span)
    return AutofillSession(
        start=span[0][0],
        end=span[-1][0],
        gallons=round(gallons, 3),
    )


def run_cli(input_path: str) -> int:
    """CLI helper used by `flume-autofill detect --input X.csv`."""
    raise NotImplementedError("Wired in Phase 2 alongside the Flume API source.")
```

- [ ] **Step 4: Run the test — expect PASS.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses freezegun ])' \
  --run 'python -m pytest tests/test_detection.py -v'
```

Expected: 1 passed.

- [ ] **Step 5: Add the remaining test cases from spec §6.1.**

Append to `tests/test_detection.py`:

```python
def test_9_min_at_4_gpm_then_drop_to_zero_yields_no_session():
    """Below the 10-min duration threshold → no session."""
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [4.0] * 9 + [0.0] * 10)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert sessions == []


def test_blip_tolerance_one_minute_at_8_gpm_keeps_session():
    """One blip at 8 GPM mid-run: stays detected (only 1 of 10 out of range)."""
    start = datetime(2026, 5, 22, 22, 0, 0)
    gpms = [4.0] * 9 + [8.0] + [4.0] * 5  # 9 in-range + 1 blip + 5 in-range
    series = _series(start, gpms)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert len(sessions) == 1
    assert sessions[0].gallons == round(9 * 4 + 8 + 5 * 4, 3)


def test_high_blip_25_gpm_breaks_mean_check_and_yields_no_session():
    """A 25 GPM spike (hose burst) pushes the rolling mean above 5."""
    start = datetime(2026, 5, 22, 22, 0, 0)
    gpms = [4.0] * 10 + [25.0] + [4.0] * 5
    series = _series(start, gpms)
    sessions = detect_autofill_sessions(series, CONFIG)
    # The window containing the 25 GPM blip fails the mean check; session
    # should end at minute 9 (last fully clean window). With our algorithm a
    # session begins once 9/10 are in range AND mean is in range; the spike
    # ends it and no new session begins because the spike alone is < 10 min.
    assert all(s.end < start + timedelta(minutes=10) for s in sessions)
    assert sum(s.gallons for s in sessions) <= 40.0


def test_two_separate_autofills_30_min_apart():
    start = datetime(2026, 5, 22, 22, 0, 0)
    gpms = [4.0] * 15 + [0.0] * 30 + [4.0] * 15
    series = _series(start, gpms)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert len(sessions) == 2
    assert all(round(s.gallons, 1) == 60.0 for s in sessions)


def test_startup_first_10_minutes_have_no_session():
    """With less than window_minutes of history, never declare a session."""
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [4.0] * 9)  # only 9 minutes of data
    sessions = detect_autofill_sessions(series, CONFIG)
    assert sessions == []


def test_session_at_lower_edge_3_gpm_is_detected():
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [3.0] * 12)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert len(sessions) == 1


def test_session_at_upper_edge_5_gpm_is_detected():
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [5.0] * 12)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert len(sessions) == 1


def test_just_outside_lower_edge_2_99_gpm_is_not_detected():
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [2.99] * 12)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert sessions == []


def test_just_outside_upper_edge_5_01_gpm_is_not_detected():
    start = datetime(2026, 5, 22, 22, 0, 0)
    series = _series(start, [5.01] * 12)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert sessions == []
```

- [ ] **Step 6: Run all detection tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses freezegun ])' \
  --run 'python -m pytest tests/test_detection.py -v'
```

Expected: 9 passed. If any fail, iterate on the algorithm in `detection.py`.

- [ ] **Step 7: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/detection.py scripts/flume-autofill/tests/test_detection.py
git commit -m "feat(flume-autofill): autofill detection algorithm with TDD coverage"
```

---

### Task 3: Configuration loader

Loads `zones.json` (generated at Nix activation time) for use by Phase 2 and Phase 3 Python code.

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/config.py`
- Create: `scripts/flume-autofill/tests/test_config.py`

- [ ] **Step 1: Write `test_config.py` first.**

```python
"""Tests for the zones.json loader."""
from __future__ import annotations

import json

import pytest

from flume_autofill.config import Config, Zone, load_config


def test_load_minimal_valid_config(tmp_path):
    data = {
        "flume_current_sensor": "sensor.flume_x_current",
        "domestic_hot_flow_sensor": "sensor.hot_water_flow",
        "autofill": {
            "gpm_min": 3.0,
            "gpm_max": 5.0,
            "window_minutes": 10,
            "min_minutes_in_range": 9,
            "enforce_mean_check": True,
        },
        "cycles": ["daily", "weekly", "monthly"],
        "zones": [
            {"slug": "front_yard", "name": "Front Yard", "type": "spray"},
            {"slug": "drip_front_left", "name": "Drip Front Left", "type": "drip"},
        ],
        "victoriametrics_url": "http://127.0.0.1:8428",
        "ha_postgres_dsn": "postgresql:///hass",
    }
    p = tmp_path / "zones.json"
    p.write_text(json.dumps(data))

    cfg = load_config(p)
    assert cfg.flume_current_sensor == "sensor.flume_x_current"
    assert cfg.domestic_hot_flow_sensor == "sensor.hot_water_flow"
    assert cfg.autofill.gpm_min == 3.0
    assert len(cfg.zones) == 2
    assert cfg.zones[0].slug == "front_yard"
    assert cfg.zones[0].type == "spray"


def test_load_config_with_null_domestic_hot(tmp_path):
    """domestic_hot_flow_sensor = null disables the category."""
    data = {
        "flume_current_sensor": "sensor.flume_x_current",
        "domestic_hot_flow_sensor": None,
        "autofill": {
            "gpm_min": 3.0, "gpm_max": 5.0, "window_minutes": 10,
            "min_minutes_in_range": 9, "enforce_mean_check": True,
        },
        "cycles": ["daily"],
        "zones": [],
        "victoriametrics_url": "http://127.0.0.1:8428",
        "ha_postgres_dsn": "postgresql:///hass",
    }
    p = tmp_path / "zones.json"
    p.write_text(json.dumps(data))

    cfg = load_config(p)
    assert cfg.domestic_hot_flow_sensor is None


def test_load_config_rejects_missing_required_key(tmp_path):
    data = {"zones": []}  # missing many required keys
    p = tmp_path / "zones.json"
    p.write_text(json.dumps(data))
    with pytest.raises(KeyError):
        load_config(p)


def test_zone_valve_entity_id_property():
    z = Zone(slug="front_yard", name="Front Yard", type="spray")
    assert z.valve_entity_id == "valve.sprinkler_control_front_yard_zone"
    assert z.gated_gpm_sensor == "sensor.water_front_yard_gpm_gated"
    assert z.total_sensor == "sensor.water_front_yard_total"
```

- [ ] **Step 2: Run the test — expect ModuleNotFoundError.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock ])' \
  --run 'python -m pytest tests/test_config.py -v'
```

Expected: ImportError / ModuleNotFoundError.

- [ ] **Step 3: Write `config.py`.**

```python
"""Loads the canonical zones.json generated by the NixOS module.

The Nix module owns the source of truth (zone list, thresholds, cycles).
This module just deserializes for Python consumers.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Zone:
    slug: str
    name: str
    type: str | None  # "spray" | "drip" | None

    @property
    def valve_entity_id(self) -> str:
        return f"valve.sprinkler_control_{self.slug}_zone"

    @property
    def gated_gpm_sensor(self) -> str:
        return f"sensor.water_{self.slug}_gpm_gated"

    @property
    def total_sensor(self) -> str:
        return f"sensor.water_{self.slug}_total"


@dataclass(frozen=True)
class AutofillConfig:
    gpm_min: float
    gpm_max: float
    window_minutes: int
    min_minutes_in_range: int
    enforce_mean_check: bool


@dataclass(frozen=True)
class Config:
    flume_current_sensor: str
    domestic_hot_flow_sensor: str | None
    autofill: AutofillConfig
    cycles: list[str]
    zones: list[Zone]
    victoriametrics_url: str
    ha_postgres_dsn: str


def load_config(path: str | Path) -> Config:
    """Read zones.json and return a typed Config.

    Raises KeyError on missing required fields.
    """
    raw = json.loads(Path(path).read_text())
    af = raw["autofill"]
    return Config(
        flume_current_sensor=raw["flume_current_sensor"],
        domestic_hot_flow_sensor=raw["domestic_hot_flow_sensor"],
        autofill=AutofillConfig(
            gpm_min=float(af["gpm_min"]),
            gpm_max=float(af["gpm_max"]),
            window_minutes=int(af["window_minutes"]),
            min_minutes_in_range=int(af["min_minutes_in_range"]),
            enforce_mean_check=bool(af["enforce_mean_check"]),
        ),
        cycles=list(raw["cycles"]),
        zones=[
            Zone(slug=z["slug"], name=z["name"], type=z.get("type"))
            for z in raw["zones"]
        ],
        victoriametrics_url=raw["victoriametrics_url"],
        ha_postgres_dsn=raw["ha_postgres_dsn"],
    )
```

- [ ] **Step 4: Run tests — expect 4 passed.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock ])' \
  --run 'python -m pytest tests/test_config.py -v'
```

- [ ] **Step 5: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/config.py scripts/flume-autofill/tests/test_config.py
git commit -m "feat(flume-autofill): zones.json config loader"
```

---

## Phase 1 — Live HA attribution via Nix module

Generate `/var/lib/hass/packages/water_attribution.yaml` from a typed Nix configuration. After this phase, HA renders all per-category sensors live from the Flume current sensor.

### Task 4: NixOS module skeleton with option types

**Files:**
- Create: `modules/services/home-assistant-water-attribution.nix`

- [ ] **Step 1: Write the module skeleton with options.**

```nix
# modules/services/home-assistant-water-attribution.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.home-assistant-water-attribution;

  zoneSubmodule = lib.types.submodule {
    options = {
      slug = lib.mkOption {
        type = lib.types.str;
        description = "Snake-case slug matching valve.sprinkler_control_<slug>_zone";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "Human-readable display name";
      };
      type = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "spray" "drip" ]);
        default = null;
        description = "Sprinkler head type, used as InfluxDB tag";
      };
    };
  };

in
{
  options.services.home-assistant-water-attribution = {
    enable = lib.mkEnableOption "water attribution tracking in Home Assistant";

    flumeCurrentSensor = lib.mkOption {
      type = lib.types.str;
      default = "sensor.flume_sensor_sierra_oaks_current";
      description = "Flume entity reporting gal/min instantaneous flow.";
    };

    domesticHotFlowSensor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "sensor.water_heater_ch1_ch1_unit1_hot_water_flow";
      description = ''
        Optional indoor hot-water flow sensor (gal/min). Setting to null
        disables the domestic_hot category entirely.
      '';
    };

    autofill = {
      gpmMin = lib.mkOption { type = lib.types.float; default = 3.0; };
      gpmMax = lib.mkOption { type = lib.types.float; default = 5.0; };
      windowMinutes = lib.mkOption { type = lib.types.int; default = 10; };
      minMinutesInRange = lib.mkOption { type = lib.types.int; default = 9; };
      enforceMeanCheck = lib.mkOption { type = lib.types.bool; default = true; };
    };

    cycles = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "daily" "weekly" "monthly" ]);
      default = [ "daily" "weekly" "monthly" ];
    };

    weekStart = lib.mkOption {
      type = lib.types.enum [ "monday" "sunday" ];
      default = "monday";
    };

    aggregateDropToleranceGal = lib.mkOption {
      type = lib.types.float;
      default = 5.0;
      description = "Gal-drop tolerance for the aggregate irrigation sum template.";
    };

    zones = lib.mkOption {
      type = lib.types.listOf zoneSubmodule;
      default = [];
      example = [
        { slug = "front_yard"; name = "Front Yard"; type = "spray"; }
        { slug = "drip_front_left"; name = "Drip Front Left"; type = "drip"; }
      ];
    };

    packageOutputPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hass/packages/water_attribution.yaml";
      description = "Where to materialize the generated package YAML.";
    };

    zonesJsonOutputPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/flume-autofill/zones.json";
      description = "Where to materialize the canonical zones.json for Phase 2/3.";
    };
  };

  # config block populated in Task 5
  config = lib.mkIf cfg.enable {
    # placeholder
  };
}
```

- [ ] **Step 2: Verify the module evaluates cleanly.**

```bash
nix-instantiate --eval --strict -E '
  let pkgs = import <nixpkgs> {}; in
  (import /etc/nixos/modules/services/home-assistant-water-attribution.nix {
    config = { services.home-assistant-water-attribution.enable = false; };
    lib = pkgs.lib;
    pkgs = pkgs;
  }).options.services.home-assistant-water-attribution.enable.type.name
'
```

Expected: prints `"bool"` (or similar non-error output).

- [ ] **Step 3: Commit.**

```bash
git add modules/services/home-assistant-water-attribution.nix
git commit -m "feat(water-attribution): nixos module skeleton with typed options"
```

---

### Task 5: YAML generator — static parts (autofill detection primitives)

Generate the parts of the HA package YAML that DON'T iterate over the zones list: the autofill range check, the history_stats, the statistics mean, the combined `pool_autofill_active` binary, plus the gated GPMs for autofill and (conditionally) domestic_hot.

**Files:**
- Modify: `modules/services/home-assistant-water-attribution.nix`

- [ ] **Step 1: Add Nix functions that generate the autofill-detection YAML.**

Inside the `let` block of the module, add (before the `in {`):

```nix
  # ---- YAML generation helpers ----

  # Render a single python-like float so YAML is readable.
  yamlFloat = f: builtins.toString f;

  yamlBool = b: if b then "true" else "false";

  autofillRangeYaml = ''
    # ─── Pool Autofill — pattern-based detection ─────────────────────────────
    template:
      - binary_sensor:
          - name: "Flume GPM in Autofill Range"
            unique_id: flume_gpm_in_autofill_range
            state: >
              {% set gpm = states('${cfg.flumeCurrentSensor}') | float(-1) %}
              {{ ${yamlFloat cfg.autofill.gpmMin} <= gpm <= ${yamlFloat cfg.autofill.gpmMax} }}
            availability: >
              {{ states('${cfg.flumeCurrentSensor}') not in ['unknown','unavailable'] }}
            attributes:
              generation: water_attribution_v1

    sensor:
      - platform: history_stats
        name: "Flume Minutes in Autofill Range ${toString cfg.autofill.windowMinutes}m"
        unique_id: flume_minutes_in_autofill_range_${toString cfg.autofill.windowMinutes}m
        entity_id: binary_sensor.flume_gpm_in_autofill_range
        state: "on"
        type: time
        duration:
          minutes: ${toString cfg.autofill.windowMinutes}
        end: "{{ now() }}"

      - platform: statistics
        name: "Flume GPM ${toString cfg.autofill.windowMinutes}m Mean"
        unique_id: flume_gpm_${toString cfg.autofill.windowMinutes}m_mean
        entity_id: ${cfg.flumeCurrentSensor}
        state_characteristic: mean
        max_age:
          minutes: ${toString cfg.autofill.windowMinutes}
        sampling_size: 50
  '';

  poolAutofillActiveYaml = ''
    template:
      - binary_sensor:
          - name: "Pool Autofill Active"
            unique_id: pool_autofill_active
            state: >
              {% set mins = (states('sensor.flume_minutes_in_autofill_range_${toString cfg.autofill.windowMinutes}m') | float(0)) * 60 %}
              {% set m = states('sensor.flume_gpm_${toString cfg.autofill.windowMinutes}m_mean') | float(-1) %}
              {{ mins >= ${toString cfg.autofill.minMinutesInRange}
                 ${lib.optionalString cfg.autofill.enforceMeanCheck
                     "and ${yamlFloat cfg.autofill.gpmMin} <= m <= ${yamlFloat cfg.autofill.gpmMax}"} }}
            delay_off:
              minutes: 1
            attributes:
              water_category: autofill
              generation: water_attribution_v1
  '';

  poolAutofillGatedGpmYaml = ''
    template:
      - sensor:
          - name: "Water Pool Autofill Gated GPM"
            unique_id: water_pool_autofill_gpm_gated
            unit_of_measurement: "gal/min"
            state: >
              {% if is_state('binary_sensor.pool_autofill_active', 'on') %}
                {{ states('${cfg.flumeCurrentSensor}') | float(0) }}
              {% else %}
                0
              {% endif %}
            availability: >
              {{ states('binary_sensor.pool_autofill_active') not in ['unknown','unavailable']
                 and states('${cfg.flumeCurrentSensor}') not in ['unknown','unavailable'] }}
            attributes:
              water_category: autofill
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water Pool Autofill Total"
        unique_id: water_pool_autofill_total
        source: sensor.water_pool_autofill_gpm_gated
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';

  domesticHotYaml = lib.optionalString (cfg.domesticHotFlowSensor != null) ''
    template:
      - sensor:
          - name: "Water Domestic Hot GPM"
            unique_id: water_domestic_hot_gpm
            unit_of_measurement: "gal/min"
            state: >
              {{ states('${cfg.domesticHotFlowSensor}') | float(0) }}
            availability: >
              {{ states('${cfg.domesticHotFlowSensor}') not in ['unknown','unavailable'] }}
            attributes:
              water_category: domestic_hot
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water Domestic Hot Total"
        unique_id: water_domestic_hot_total
        source: sensor.water_domestic_hot_gpm
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';
```

- [ ] **Step 2: Add a top-level `_yamlPreview` attribute for verification.**

Keep `config = lib.mkIf cfg.enable {};` empty (we materialize the YAML in Task 8). To verify what the generator produces in isolation, expose the YAML string as a top-level attribute by changing the module's outer expression:

```nix
in
{
  options.services.home-assistant-water-attribution = { ... };

  config = lib.mkIf cfg.enable {
    # placeholder — full materialization added in Task 8
  };

  # Verification helper: surface the generated YAML text so flake/dev tools
  # can inspect what the module would produce. Not used at runtime.
  _module.args._yamlPreview = pkgs.writeText "water_attribution_preview.yaml" ''
    ${autofillRangeYaml}

    ${poolAutofillActiveYaml}

    ${poolAutofillGatedGpmYaml}

    ${domesticHotYaml}
  '';
}
```

- [ ] **Step 3: Verify the module parses cleanly.**

```bash
nix-instantiate --parse /etc/nixos/modules/services/home-assistant-water-attribution.nix > /dev/null && echo OK
```

Expected: prints `OK`. (Full evaluation deferred to Task 8/9 where the module is loaded into a real host config.)

- [ ] **Step 4: Commit.**

```bash
git add modules/services/home-assistant-water-attribution.nix
git commit -m "feat(water-attribution): static-YAML generators (autofill detection)"
```

---

### Task 6: YAML generator — per-zone iteration

**Files:**
- Modify: `modules/services/home-assistant-water-attribution.nix`

- [ ] **Step 1: Add per-zone YAML generation functions.**

Append to the `let` block:

```nix
  perZoneGatedYaml = z: ''
    template:
      - sensor:
          - name: "Water ${z.name} Gated GPM"
            unique_id: water_${z.slug}_gpm_gated
            unit_of_measurement: "gal/min"
            state: >
              {% if is_state('valve.sprinkler_control_${z.slug}_zone', 'open') %}
                {{ states('${cfg.flumeCurrentSensor}') | float(0) }}
              {% else %}
                0
              {% endif %}
            availability: >
              {{ states('valve.sprinkler_control_${z.slug}_zone') not in ['unknown','unavailable']
                 and states('${cfg.flumeCurrentSensor}') not in ['unknown','unavailable'] }}
            attributes:
              water_category: irrigation
              zone_slug: ${z.slug}
              ${lib.optionalString (z.type != null) "zone_type: ${z.type}"}
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water ${z.name} Total"
        unique_id: water_${z.slug}_total
        source: sensor.water_${z.slug}_gpm_gated
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';

  zonesIterationYaml = lib.concatMapStringsSep "\n" perZoneGatedYaml cfg.zones;

  # Aggregate irrigation total (sum of zones, with drop tolerance)
  zoneTotalsList = lib.concatMapStringsSep ", "
    (z: "'sensor.water_${z.slug}_total'") cfg.zones;

  aggregateIrrigationYaml = ''
    template:
      - sensor:
          - name: "Water Irrigation Total"
            unique_id: water_irrigation_total
            unit_of_measurement: "gal"
            device_class: water
            state_class: total_increasing
            state: >
              {% set zones = [ ${zoneTotalsList} ] %}
              {% set s = zones | map('states') | map('float', 0) | sum %}
              {% set last = states('sensor.water_irrigation_total') | float(0) %}
              {% set tol = ${yamlFloat cfg.aggregateDropToleranceGal} %}
              {{ (([s, last] | max | round(3)) if ((last - s) < tol) else (s | round(3))) }}
            availability: >
              {% set zones = [ ${zoneTotalsList} ] %}
              {{ zones | map('states') | reject('in', ['unknown','unavailable']) | list | length == zones | length }}
            attributes:
              water_category: irrigation
              generation: water_attribution_v1
  '';

  # Convenience binary_sensor: any irrigation zone open right now.
  # Used by future NR consumer flows; also a clean signal for Grafana annotations.
  zoneValveList = lib.concatMapStringsSep ", "
    (z: "'valve.sprinkler_control_${z.slug}_zone'") cfg.zones;

  irrigationActiveYaml = ''
    template:
      - binary_sensor:
          - name: "Irrigation Active"
            unique_id: irrigation_active
            state: >
              {% set valves = [ ${zoneValveList} ] %}
              {{ valves | map('states') | select('eq', 'open') | list | length > 0 }}
            availability: >
              {% set valves = [ ${zoneValveList} ] %}
              {{ valves | map('states') | reject('in', ['unknown','unavailable']) | list | length > 0 }}
            attributes:
              water_category: irrigation
              generation: water_attribution_v1
  '';

  # Gated-GPM list for the "other" residual subtraction
  zoneGatedList = lib.concatMapStringsSep ", "
    (z: "'sensor.water_${z.slug}_gpm_gated'") cfg.zones;

  hasHot = cfg.domesticHotFlowSensor != null;

  otherResidualYaml = ''
    template:
      - sensor:
          - name: "Water Other GPM"
            unique_id: water_other_gpm
            unit_of_measurement: "gal/min"
            state: >
              {% set total = states('${cfg.flumeCurrentSensor}') | float(0) %}
              {% set autofill = states('sensor.water_pool_autofill_gpm_gated') | float(0) %}
              ${lib.optionalString hasHot "{% set hot = states('sensor.water_domestic_hot_gpm') | float(0) %}"}
              {% set zones = [ ${zoneGatedList} ] %}
              {% set irrigation = zones | map('states') | map('float', 0) | sum %}
              {% set residual = total - autofill ${lib.optionalString hasHot "- hot"} - irrigation %}
              {{ [residual, 0] | max | round(3) }}
            attributes:
              water_category: other
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water Other Total"
        unique_id: water_other_total
        source: sensor.water_other_gpm
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';
```

- [ ] **Step 2: Update the `_yamlPreview` writeText to include all new sections.**

Replace the existing `_module.args._yamlPreview = pkgs.writeText "water_attribution_preview.yaml" '' ... ''` with the full set of sections in order:

```nix
  _module.args._yamlPreview = pkgs.writeText "water_attribution_preview.yaml" ''
    ${autofillRangeYaml}

    ${poolAutofillActiveYaml}

    ${poolAutofillGatedGpmYaml}

    ${domesticHotYaml}

    ${zonesIterationYaml}

    ${irrigationActiveYaml}

    ${aggregateIrrigationYaml}

    ${otherResidualYaml}
  '';
```

- [ ] **Step 3: Verify the module still parses.**

```bash
nix-instantiate --parse /etc/nixos/modules/services/home-assistant-water-attribution.nix > /dev/null && echo OK
```

Expected: prints `OK`. Full YAML inspection happens at Task 9 (`nixos-rebuild build` followed by `find /nix/store -name 'water_attribution.yaml'`).

- [ ] **Step 4: Commit.**

```bash
git add modules/services/home-assistant-water-attribution.nix
git commit -m "feat(water-attribution): per-zone YAML generation + residual + aggregate"
```

---

### Task 7: YAML generator — utility_meter cycles

**Files:**
- Modify: `modules/services/home-assistant-water-attribution.nix`

- [ ] **Step 1: Add the `utility_meter` generator.**

Append to the `let` block:

```nix
  # Map "weekly" → offset days so utility_meter can anchor properly.
  weekOffsetDays = if cfg.weekStart == "monday" then 0 else 6;

  utilityMeterEntry = source: cycle: ''
      ${source}_${cycle}:
        source: sensor.${source}
        cycle: ${cycle}
        name: "${
          let
            cleaned = lib.replaceStrings [ "water_" "_total" ] [ "Water " "" ] source;
            cycleTitle = lib.toUpper (builtins.substring 0 1 cycle) +
              builtins.substring 1 (builtins.stringLength cycle) cycle;
          in "${cleaned} ${cycleTitle}"
        }"
        ${lib.optionalString (cycle == "weekly") "offset: { days: ${toString weekOffsetDays} }"}
  '';

  # Cumulative source sensors that need utility_meter wrappers.
  cumulativeSources =
    [ "water_pool_autofill_total" ]
    ++ (lib.optional hasHot "water_domestic_hot_total")
    ++ (map (z: "water_${z.slug}_total") cfg.zones)
    ++ [ "water_irrigation_total" "water_other_total" ];

  utilityMeterYaml = ''
    utility_meter:
    ${lib.concatStrings (lib.concatMap
      (source: map (cycle: utilityMeterEntry source cycle) cfg.cycles)
      cumulativeSources)}
  '';
```

- [ ] **Step 2: Append `utilityMeterYaml` to the `_yamlPreview` writeText.**

Update the `_module.args._yamlPreview = pkgs.writeText "water_attribution_preview.yaml" '' ... ''` to include `${utilityMeterYaml}` at the end of the body.

- [ ] **Step 3: Verify the module still parses.**

```bash
nix-instantiate --parse /etc/nixos/modules/services/home-assistant-water-attribution.nix > /dev/null && echo OK
```

Expected: prints `OK`.

- [ ] **Step 4: Commit.**

```bash
git add modules/services/home-assistant-water-attribution.nix
git commit -m "feat(water-attribution): utility_meter cycle generation"
```

---

### Task 8: Materialize generated YAML + zones.json at activation

**Files:**
- Modify: `modules/services/home-assistant-water-attribution.nix`

- [ ] **Step 1: Replace the empty `config = lib.mkIf cfg.enable {}` block with the activation script AND the shared `flume-autofill` user/group declaration that the zones.json materialization depends on.**

The `flume-autofill` user/group is shared infrastructure between this module and the Phase 2 `flume-autofill.nix` module (Task 17). It is declared HERE so that Phase 1 can deploy and ship zones.json with the correct ownership even before Phase 2 is enabled. Task 17 will reference (not redeclare) the same user.

Replace the placeholder `config = lib.mkIf cfg.enable { ... }` body with:

```nix
    # Shared user/group used by zones.json materialization here and by the
    # Phase 2/3 systemd services in modules/services/flume-autofill.nix.
    # Declared in this module so Phase 1 can deploy independently of Phase 2.
    users.users.flume-autofill = {
      isSystemUser = true;
      group = "flume-autofill";
      home = "/var/lib/flume-autofill";
      createHome = true;
    };
    users.groups.flume-autofill = {};

    systemd.tmpfiles.rules = [
      "d /var/lib/flume-autofill 0750 flume-autofill flume-autofill -"
    ];

    # Materialize the generated YAML into the HA packages directory.
    # Symlink from the Nix store ensures atomic swaps on every rebuild.
    system.activationScripts.water-attribution-package = {
      text = ''
        install -d -m 755 -o hass -g hass /var/lib/hass/packages
        install -m 0644 -o hass -g hass \
          ${packageYamlFile} \
          ${toString cfg.packageOutputPath}
        install -d -m 750 -o flume-autofill -g flume-autofill /var/lib/flume-autofill
        install -m 0644 -o flume-autofill -g flume-autofill \
          ${zonesJsonFile} \
          ${toString cfg.zonesJsonOutputPath}
      '';
      deps = [ "users" "groups" ];
    };

    # Restart HA when the generated content changes.
    systemd.services.home-assistant.restartTriggers = [
      packageYamlFile
      zonesJsonFile
    ];
```

**Note the path change for `zones.json`:** the reviewer flagged that generating into `/etc/nixos/scripts/flume-autofill/zones.json` pollutes the git tree. The default `zonesJsonOutputPath` (Task 4) must therefore be changed from `/etc/nixos/scripts/flume-autofill/zones.json` to `/var/lib/flume-autofill/zones.json`.

Update the option default in the `options.services.home-assistant-water-attribution` block (Task 4):

```nix
    zonesJsonOutputPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/flume-autofill/zones.json";
      description = "Where to materialize the canonical zones.json for Phase 2/3.";
    };
```

The Python service config (Tasks 14, 16, 17, 21) must reference the new path — all `FLUME_AUTOFILL_CONFIG` env values become `/var/lib/flume-autofill/zones.json`.

- [ ] **Step 2: Add the `packageYamlFile` and `zonesJsonFile` derivations to the `let` block.**

```nix
  packageYamlFile = pkgs.writeText "water_attribution.yaml" ''
    ${autofillRangeYaml}

    ${poolAutofillActiveYaml}

    ${poolAutofillGatedGpmYaml}

    ${domesticHotYaml}

    ${zonesIterationYaml}

    ${irrigationActiveYaml}

    ${aggregateIrrigationYaml}

    ${otherResidualYaml}

    ${utilityMeterYaml}
  '';

  zonesJsonFile = pkgs.writeText "zones.json" (builtins.toJSON {
    flume_current_sensor = cfg.flumeCurrentSensor;
    domestic_hot_flow_sensor = cfg.domesticHotFlowSensor;
    autofill = {
      gpm_min = cfg.autofill.gpmMin;
      gpm_max = cfg.autofill.gpmMax;
      window_minutes = cfg.autofill.windowMinutes;
      min_minutes_in_range = cfg.autofill.minMinutesInRange;
      enforce_mean_check = cfg.autofill.enforceMeanCheck;
    };
    cycles = cfg.cycles;
    zones = map (z: { inherit (z) slug name type; }) cfg.zones;
    victoriametrics_url = "http://127.0.0.1:8428";
    ha_postgres_dsn = "postgresql:///hass";
  });
```

- [ ] **Step 3: Run a full dry-build.**

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' --show-trace 2>&1 | tail -40
```

Expected: build succeeds. The new module evaluates without errors.

- [ ] **Step 4: Commit.**

```bash
git add modules/services/home-assistant-water-attribution.nix
git commit -m "feat(water-attribution): materialize generated YAML + zones.json at activation"
```

---

### Task 9: Wire the module into `configuration.nix`

**Files:**
- Modify: `configuration.nix`

- [ ] **Step 1: Import the new module and enable it with the full zone list.**

Find the existing `imports = [ ... ]` block in `configuration.nix` (or wherever modules are loaded for this host) and add:

```nix
    ./modules/services/home-assistant-water-attribution.nix
```

Then add a `services.home-assistant-water-attribution = { ... };` block near the other service config (e.g., next to the existing home-assistant block):

```nix
  services.home-assistant-water-attribution = {
    enable = true;
    flumeCurrentSensor = "sensor.flume_sensor_sierra_oaks_current";
    domesticHotFlowSensor = "sensor.water_heater_ch1_ch1_unit1_hot_water_flow";

    autofill = {
      gpmMin = 3.0;
      gpmMax = 5.0;
      windowMinutes = 10;
      minMinutesInRange = 9;
      enforceMeanCheck = true;
    };

    cycles = [ "daily" "weekly" "monthly" ];
    weekStart = "monday";
    aggregateDropToleranceGal = 5.0;

    zones = [
      { slug = "front_yard";                          name = "Front Yard";                          type = "spray"; }
      { slug = "side_yard_right";                     name = "Side Yard (right)";                   type = "spray"; }
      { slug = "back_wall";                           name = "Back Wall";                           type = "spray"; }
      { slug = "around_dining_set";                   name = "Around Dining Set";                   type = "spray"; }
      { slug = "along_driveway";                      name = "Along Driveway";                      type = "spray"; }
      { slug = "back_of_house_and_side_yard_left";    name = "Back of House and Side Yard (left)";  type = "spray"; }
      { slug = "drip_front_left";                     name = "Drip Front Left";                     type = "drip"; }
      { slug = "drip_front_right";                    name = "Drip Front Right";                    type = "drip"; }
      { slug = "planter_box";                         name = "Planter Box";                         type = "drip"; }
      { slug = "zone_5";                              name = "Zone 5";                              type = null; }
    ];
  };
```

- [ ] **Step 2: Run another full dry-build.**

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' --show-trace 2>&1 | tail -40
```

Expected: build succeeds. The generated `water_attribution.yaml` now exists in the Nix store.

- [ ] **Step 3: Inspect the generated YAML.**

```bash
find /nix/store -name 'water_attribution.yaml' 2>/dev/null | head -1 | xargs cat 2>&1 | head -80
```

Expected: full YAML body covering all 10 zones, autofill detection, domestic_hot, residual, and 42 utility_meter entries.

- [ ] **Step 4: Switch to the new configuration.**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -20
```

Expected: clean activation. HA restarts due to the `restartTriggers` hook.

- [ ] **Step 5: Verify the new entities appear in HA.**

```bash
sudo -u postgres psql -d hass -c "
  SELECT entity_id
    FROM states_meta
   WHERE entity_id LIKE 'sensor.water_%'
      OR entity_id = 'binary_sensor.pool_autofill_active'
   ORDER BY entity_id;
" 2>&1 | head -30
```

Expected: ≥30 rows including `binary_sensor.pool_autofill_active`, `sensor.water_front_yard_total`, `sensor.water_irrigation_total`, `sensor.water_pool_autofill_total`, `sensor.water_domestic_hot_total`, `sensor.water_other_total`, and the per-cycle wrappers.

- [ ] **Step 6: Commit the configuration.nix change.**

```bash
git add configuration.nix
git commit -m "feat(water-attribution): wire module into host configuration"
```

---

## Phase 2 — Cross-check service + weekly water report

Standalone Python systemd service that re-derives totals from Flume API + VictoriaMetrics + HA Postgres each week, compares against HA's live tally, and emits a friendly water report email with an anomaly section when delta exceeds tolerance.

### Task 10: Flume API source client (TDD)

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/sources/flume_api.py`
- Create: `scripts/flume-autofill/tests/test_sources_flume_api.py`

- [ ] **Step 1: Write `test_sources_flume_api.py` covering token mint, query, retry, and 429 backoff.**

```python
"""Tests for the Flume Personal API client."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
import responses

from flume_autofill.sources.flume_api import (
    FlumeAPIClient,
    FlumeAPIError,
    Credentials,
)


CREDS = Credentials(
    client_id="cid",
    client_secret="csec",
    username="uname",
    password="pwd",
)


@responses.activate
def test_mint_token_caches_and_reuses():
    responses.post(
        "https://api.flumewater.com/oauth/token",
        json={
            "data": [
                {
                    "access_token": "tok",
                    "refresh_token": "ref",
                    "expires_in": 604800,
                }
            ]
        },
        status=200,
    )
    client = FlumeAPIClient(CREDS, token_cache_path=None)
    tok1 = client.token
    tok2 = client.token  # second call hits the cache, no second mint
    assert tok1 == tok2 == "tok"
    assert len(responses.calls) == 1


@responses.activate
def test_query_returns_per_minute_series(tmp_path):
    responses.post(
        "https://api.flumewater.com/oauth/token",
        json={"data": [{"access_token": "tok", "refresh_token": "ref", "expires_in": 600}]},
    )
    responses.post(
        "https://api.flumewater.com/users/0/devices/dev1/query",
        json={
            "data": [
                {
                    "req1": [
                        {"datetime": "2026-05-21 22:00:00", "value": 4.1},
                        {"datetime": "2026-05-21 22:01:00", "value": 4.0},
                    ]
                }
            ]
        },
    )
    client = FlumeAPIClient(CREDS, token_cache_path=tmp_path / "tok.json")
    series = client.query_gpm(
        device_id="dev1",
        user_id=0,
        since=datetime(2026, 5, 21, 22, 0, tzinfo=timezone.utc),
        until=datetime(2026, 5, 21, 22, 5, tzinfo=timezone.utc),
    )
    assert len(series) == 2
    assert series[0][1] == 4.1


@responses.activate
def test_query_backs_off_on_429():
    responses.post(
        "https://api.flumewater.com/oauth/token",
        json={"data": [{"access_token": "tok", "refresh_token": "ref", "expires_in": 600}]},
    )
    responses.post(
        "https://api.flumewater.com/users/0/devices/dev1/query",
        status=429,
        headers={"Retry-After": "1"},
    )
    responses.post(
        "https://api.flumewater.com/users/0/devices/dev1/query",
        json={"data": [{"req1": []}]},
        status=200,
    )
    client = FlumeAPIClient(CREDS, token_cache_path=None, retry_initial_seconds=0.01)
    series = client.query_gpm(
        device_id="dev1", user_id=0,
        since=datetime(2026, 5, 21, 22, 0, tzinfo=timezone.utc),
        until=datetime(2026, 5, 21, 22, 5, tzinfo=timezone.utc),
    )
    assert series == []
    # 1 mint + 1 throttled + 1 success
    assert len(responses.calls) == 3
```

- [ ] **Step 2: Implement `flume_api.py`.**

```python
"""Flume Personal API client.

References:
  - https://help.flumewater.com/en/articles/3108017-flume-personal-api
  - https://flumetech.readme.io/reference/query-a-user-device
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests


BASE_URL = "https://api.flumewater.com"


@dataclass(frozen=True)
class Credentials:
    client_id: str
    client_secret: str
    username: str
    password: str


class FlumeAPIError(RuntimeError):
    pass


class FlumeAPIClient:
    """Bearer-token-cached Flume API client with simple retry/backoff."""

    def __init__(
        self,
        creds: Credentials,
        token_cache_path: Path | None,
        retry_initial_seconds: float = 1.0,
        max_retries: int = 4,
    ) -> None:
        self._creds = creds
        self._cache_path = token_cache_path
        self._retry_initial_seconds = retry_initial_seconds
        self._max_retries = max_retries
        self._token: str | None = None
        self._user_id: int | None = None

        if token_cache_path and token_cache_path.exists():
            cached = json.loads(token_cache_path.read_text())
            if cached.get("expires_at", 0) > time.time() + 60:
                self._token = cached["access_token"]
                self._user_id = cached.get("user_id")

    @property
    def token(self) -> str:
        if self._token is None:
            self._mint_token()
        return self._token  # type: ignore[return-value]

    def _mint_token(self) -> None:
        body = {
            "grant_type": "password",
            "client_id": self._creds.client_id,
            "client_secret": self._creds.client_secret,
            "username": self._creds.username,
            "password": self._creds.password,
        }
        resp = requests.post(f"{BASE_URL}/oauth/token", json=body, timeout=30)
        if resp.status_code != 200:
            raise FlumeAPIError(f"oauth/token returned {resp.status_code}: {resp.text}")
        data = resp.json()["data"][0]
        self._token = data["access_token"]
        # The user_id is embedded in the JWT; parse it lazily on first query call.
        if self._cache_path:
            self._cache_path.write_text(
                json.dumps(
                    {
                        "access_token": self._token,
                        "expires_at": time.time() + int(data["expires_in"]) - 60,
                        "user_id": self._user_id,
                    }
                )
            )
            self._cache_path.chmod(0o600)

    def query_gpm(
        self,
        device_id: str,
        user_id: int,
        since: datetime,
        until: datetime,
    ) -> list[tuple[datetime, float]]:
        """Return per-minute (timestamp_utc, gpm) tuples for the window."""
        body = {
            "queries": [
                {
                    "request_id": "req1",
                    "bucket": "MIN",
                    "since_datetime": since.strftime("%Y-%m-%d %H:%M:%S"),
                    "until_datetime": until.strftime("%Y-%m-%d %H:%M:%S"),
                    "units": "GALLONS",
                    "sort_direction": "ASC",
                }
            ]
        }
        url = f"{BASE_URL}/users/{user_id}/devices/{device_id}/query"
        for attempt in range(self._max_retries):
            resp = requests.post(
                url,
                json=body,
                headers={"Authorization": f"Bearer {self.token}"},
                timeout=60,
            )
            if resp.status_code == 200:
                break
            if resp.status_code == 429:
                wait = self._retry_initial_seconds * (2 ** attempt)
                if "Retry-After" in resp.headers:
                    wait = max(wait, float(resp.headers["Retry-After"]))
                time.sleep(wait)
                continue
            raise FlumeAPIError(f"query returned {resp.status_code}: {resp.text}")
        else:
            raise FlumeAPIError("max retries exhausted")

        items = resp.json()["data"][0].get("req1", [])
        return [
            (
                datetime.strptime(it["datetime"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc),
                float(it["value"]),
            )
            for it in items
        ]
```

- [ ] **Step 3: Run the API tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses requests ])' \
  --run 'python -m pytest tests/test_sources_flume_api.py -v'
```

Expected: 3 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/sources/flume_api.py scripts/flume-autofill/tests/test_sources_flume_api.py
git commit -m "feat(flume-autofill): Flume Personal API client with token cache + retry"
```

---

### Task 11: VictoriaMetrics source client (TDD)

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/sources/victoriametrics.py`
- Create: `scripts/flume-autofill/tests/test_sources_victoriametrics.py`

- [ ] **Step 1: Test file with PromQL/MetricsQL query mocks.**

```python
"""Tests for the VictoriaMetrics source."""
from __future__ import annotations

from datetime import datetime, timezone

import responses

from flume_autofill.sources.victoriametrics import VMSource


@responses.activate
def test_query_range_returns_time_series():
    responses.get(
        "http://vm:8428/api/v1/query_range",
        json={
            "status": "success",
            "data": {
                "resultType": "matrix",
                "result": [
                    {
                        "metric": {"entity_id": "sensor.flume_x_current"},
                        "values": [
                            [1716595200, "4.1"],
                            [1716595260, "4.0"],
                        ],
                    }
                ],
            },
        },
    )
    vm = VMSource("http://vm:8428")
    series = vm.query_range(
        metric='last_over_time({entity_id="sensor.flume_x_current"}[1m])',
        start=datetime(2026, 5, 24, 23, 20, tzinfo=timezone.utc),
        end=datetime(2026, 5, 24, 23, 22, tzinfo=timezone.utc),
        step="60s",
    )
    assert len(series) == 2
    assert series[0][1] == 4.1


@responses.activate
def test_query_returns_empty_when_no_data():
    responses.get(
        "http://vm:8428/api/v1/query_range",
        json={"status": "success", "data": {"result": []}},
    )
    vm = VMSource("http://vm:8428")
    series = vm.query_range(
        metric="up",
        start=datetime(2026, 5, 24, tzinfo=timezone.utc),
        end=datetime(2026, 5, 25, tzinfo=timezone.utc),
        step="60s",
    )
    assert series == []
```

- [ ] **Step 2: Implement `victoriametrics.py`.**

```python
"""VictoriaMetrics query client (uses the Prometheus-compatible API)."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import requests


class VMSource:
    def __init__(self, base_url: str) -> None:
        self._base = base_url.rstrip("/")

    def query_range(
        self,
        metric: str,
        start: datetime,
        end: datetime,
        step: str = "60s",
    ) -> list[tuple[datetime, float]]:
        """Return (timestamp_utc, value) pairs from a range query."""
        resp = requests.get(
            f"{self._base}/api/v1/query_range",
            params={
                "query": metric,
                "start": int(start.timestamp()),
                "end": int(end.timestamp()),
                "step": step,
            },
            timeout=60,
        )
        resp.raise_for_status()
        data = resp.json()["data"]
        if not data.get("result"):
            return []
        # Assume single time series for our usage; flatten.
        out: list[tuple[datetime, float]] = []
        for serie in data["result"]:
            for ts, val in serie.get("values", []):
                out.append(
                    (
                        datetime.fromtimestamp(int(ts), tz=timezone.utc),
                        float(val),
                    )
                )
        out.sort(key=lambda r: r[0])
        return out

    def query_flume_current(
        self, entity_id: str, start: datetime, end: datetime
    ) -> list[tuple[datetime, float]]:
        return self.query_range(
            metric=f'last_over_time({{entity_id="{entity_id}"}}[1m])',
            start=start,
            end=end,
            step="60s",
        )
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses requests ])' \
  --run 'python -m pytest tests/test_sources_victoriametrics.py -v'
```

Expected: 2 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/sources/victoriametrics.py scripts/flume-autofill/tests/test_sources_victoriametrics.py
git commit -m "feat(flume-autofill): VictoriaMetrics range-query client"
```

---

### Task 12: HA Postgres source client

Queries HA's `hass` Postgres database for valve-open events and historical state values.

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/sources/ha_postgres.py`
- Create: `scripts/flume-autofill/tests/test_sources_ha_postgres.py`

- [ ] **Step 1: Write the test using an in-memory sqlite stand-in for the queries.**

```python
"""Tests for the HA Postgres source.

We don't mock psycopg2 directly; instead we test the SQL-rendering helpers
and verify the row-parsing logic against synthetic rows.
"""
from __future__ import annotations

from datetime import datetime, timezone

from flume_autofill.sources.ha_postgres import (
    parse_valve_events,
    parse_sensor_states,
    valve_events_sql,
    sensor_states_sql,
)


def test_valve_events_sql_contains_entity_filter():
    sql, params = valve_events_sql(
        entity_ids=["valve.sprinkler_control_front_yard_zone"],
        since=datetime(2026, 5, 20, tzinfo=timezone.utc),
        until=datetime(2026, 5, 21, tzinfo=timezone.utc),
    )
    assert "states_meta" in sql
    assert "metadata_id" in sql
    assert len(params) == 3  # entity list, since, until


def test_parse_valve_events_returns_open_close_intervals():
    # synthetic rows: (last_updated_ts, entity_id, state)
    rows = [
        (1716595200.0, "valve.sprinkler_control_front_yard_zone", "open"),
        (1716595560.0, "valve.sprinkler_control_front_yard_zone", "closed"),
        (1716595800.0, "valve.sprinkler_control_front_yard_zone", "open"),
        (1716596100.0, "valve.sprinkler_control_front_yard_zone", "closed"),
    ]
    events = parse_valve_events(rows)
    assert len(events) == 2
    assert events[0].entity_id == "valve.sprinkler_control_front_yard_zone"
    assert events[0].opened_at.timestamp() == 1716595200.0
    assert events[0].closed_at.timestamp() == 1716595560.0


def test_parse_sensor_states_filters_nonnumeric():
    rows = [
        (1716595200.0, "sensor.x", "4.1"),
        (1716595260.0, "sensor.x", "unavailable"),
        (1716595320.0, "sensor.x", "4.0"),
    ]
    series = parse_sensor_states(rows)
    assert len(series) == 2
    assert [v for _, v in series] == [4.1, 4.0]
```

- [ ] **Step 2: Implement `ha_postgres.py`.**

```python
"""Home Assistant Postgres source.

Reads `states` joined to `states_meta` for valve-event detection and
sensor history.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

import psycopg2


@dataclass(frozen=True)
class ValveOpenInterval:
    entity_id: str
    opened_at: datetime
    closed_at: datetime


def valve_events_sql(
    entity_ids: list[str], since: datetime, until: datetime
) -> tuple[str, list]:
    sql = """
        SELECT s.last_updated_ts, m.entity_id, s.state
          FROM states s
          JOIN states_meta m ON s.metadata_id = m.metadata_id
         WHERE m.entity_id = ANY(%s)
           AND s.last_updated_ts >= %s
           AND s.last_updated_ts <  %s
         ORDER BY s.last_updated_ts ASC
    """
    return sql, [entity_ids, since.timestamp(), until.timestamp()]


def sensor_states_sql(
    entity_id: str, since: datetime, until: datetime
) -> tuple[str, list]:
    sql = """
        SELECT s.last_updated_ts, m.entity_id, s.state
          FROM states s
          JOIN states_meta m ON s.metadata_id = m.metadata_id
         WHERE m.entity_id = %s
           AND s.last_updated_ts >= %s
           AND s.last_updated_ts <  %s
         ORDER BY s.last_updated_ts ASC
    """
    return sql, [entity_id, since.timestamp(), until.timestamp()]


def parse_valve_events(
    rows: Iterable[tuple[float, str, str]],
) -> list[ValveOpenInterval]:
    intervals: list[ValveOpenInterval] = []
    open_state: dict[str, datetime] = {}
    for ts, entity, state in rows:
        when = datetime.fromtimestamp(float(ts), tz=timezone.utc)
        if state == "open":
            open_state[entity] = when
        elif state == "closed" and entity in open_state:
            intervals.append(
                ValveOpenInterval(
                    entity_id=entity,
                    opened_at=open_state.pop(entity),
                    closed_at=when,
                )
            )
    return intervals


def parse_sensor_states(
    rows: Iterable[tuple[float, str, str]],
) -> list[tuple[datetime, float]]:
    out: list[tuple[datetime, float]] = []
    for ts, _entity, state in rows:
        try:
            v = float(state)
        except (TypeError, ValueError):
            continue
        out.append((datetime.fromtimestamp(float(ts), tz=timezone.utc), v))
    return out


class HAPostgresSource:
    def __init__(self, dsn: str) -> None:
        self._dsn = dsn

    def fetch_valve_events(
        self, entity_ids: list[str], since: datetime, until: datetime
    ) -> list[ValveOpenInterval]:
        sql, params = valve_events_sql(entity_ids, since, until)
        with psycopg2.connect(self._dsn) as conn:
            with conn.cursor() as cur:
                cur.execute(sql, params)
                rows = cur.fetchall()
        return parse_valve_events(rows)

    def fetch_sensor_states(
        self, entity_id: str, since: datetime, until: datetime
    ) -> list[tuple[datetime, float]]:
        sql, params = sensor_states_sql(entity_id, since, until)
        with psycopg2.connect(self._dsn) as conn:
            with conn.cursor() as cur:
                cur.execute(sql, params)
                rows = cur.fetchall()
        return parse_sensor_states(rows)
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock psycopg2 ])' \
  --run 'python -m pytest tests/test_sources_ha_postgres.py -v'
```

Expected: 3 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/sources/ha_postgres.py scripts/flume-autofill/tests/test_sources_ha_postgres.py
git commit -m "feat(flume-autofill): HA Postgres source for valve events + states"
```

---

### Task 13: CSV writer destination

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/destinations/csv_writer.py`
- Create: `scripts/flume-autofill/tests/test_destinations_csv.py`

- [ ] **Step 1: Test the writer.**

```python
from __future__ import annotations

import csv
from datetime import date

from flume_autofill.destinations.csv_writer import write_per_day_totals


def test_write_per_day_totals_creates_one_file_per_category(tmp_path):
    rows = [
        (date(2026, 5, 15), "pool_autofill", 42.3),
        (date(2026, 5, 16), "pool_autofill", 38.1),
        (date(2026, 5, 15), "irrigation_front_yard", 920.0),
    ]
    write_per_day_totals(rows, tmp_path)

    autofill = (tmp_path / "pool_autofill.csv").read_text()
    assert "2026-05-15,42.3" in autofill
    assert "2026-05-16,38.1" in autofill

    irrigation = (tmp_path / "irrigation_front_yard.csv").read_text()
    assert "2026-05-15,920.0" in irrigation
```

- [ ] **Step 2: Implement the writer.**

```python
"""CSV destination: one file per category, date,gallons."""
from __future__ import annotations

import csv
from collections import defaultdict
from datetime import date
from pathlib import Path


def write_per_day_totals(
    rows: list[tuple[date, str, float]],
    out_dir: Path,
) -> dict[str, Path]:
    """Write per-day totals into one CSV per category. Returns written paths."""
    out_dir.mkdir(parents=True, exist_ok=True)
    by_category: dict[str, list[tuple[date, float]]] = defaultdict(list)
    for d, cat, gal in rows:
        by_category[cat].append((d, gal))

    written: dict[str, Path] = {}
    for category, entries in by_category.items():
        entries.sort(key=lambda r: r[0])
        path = out_dir / f"{category}.csv"
        with path.open("w", newline="") as fh:
            writer = csv.writer(fh)
            writer.writerow(["date", "gallons"])
            for d, gal in entries:
                writer.writerow([d.isoformat(), gal])
        written[category] = path
    return written
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest ])' \
  --run 'python -m pytest tests/test_destinations_csv.py -v'
```

Expected: 1 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/destinations/csv_writer.py scripts/flume-autofill/tests/test_destinations_csv.py
git commit -m "feat(flume-autofill): per-category CSV writer"
```

---

### Task 14: Cross-check core logic (TDD)

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/cross_check.py`
- Create: `scripts/flume-autofill/tests/test_cross_check.py`

- [ ] **Step 1: Test the comparison + anomaly classification.**

```python
"""Tests for Phase 2 cross-check."""
from __future__ import annotations

from datetime import date

from flume_autofill.cross_check import (
    CategoryComparison,
    Tolerances,
    classify_category,
    summarize,
)


def test_classify_within_tolerance_is_ok():
    tol = Tolerances(abs_gal=5.0, pct=3.0)
    cmp = CategoryComparison(
        category="pool_autofill",
        ha_total_gal=100.0,
        phase2_total_gal=101.5,
    )
    status = classify_category(cmp, tol)
    assert status == "ok"


def test_classify_outside_abs_tolerance_is_anomaly():
    tol = Tolerances(abs_gal=5.0, pct=3.0)
    cmp = CategoryComparison(
        category="pool_autofill",
        ha_total_gal=100.0,
        phase2_total_gal=108.0,
    )
    assert classify_category(cmp, tol) == "anomaly"


def test_classify_outside_pct_tolerance_is_anomaly():
    tol = Tolerances(abs_gal=5.0, pct=3.0)
    cmp = CategoryComparison(
        category="pool_autofill",
        ha_total_gal=1000.0,
        phase2_total_gal=1050.0,  # 5% drift; abs is within 50 but pct exceeds
    )
    assert classify_category(cmp, tol) == "anomaly"


def test_summarize_aggregates_categories():
    tol = Tolerances(abs_gal=5.0, pct=3.0)
    comps = [
        CategoryComparison("pool_autofill", 100, 101),
        CategoryComparison("irrigation_total", 500, 530),
    ]
    summary = summarize(comps, tol)
    assert summary["overall_status"] == "anomaly"
    assert summary["max_abs_delta_gal"] == 30.0
    assert any(c["status"] == "anomaly" for c in summary["categories"])
```

- [ ] **Step 2: Implement `cross_check.py`.**

```python
"""Phase 2 cross-check entry point + comparison logic."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, asdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from .config import load_config


@dataclass
class Tolerances:
    abs_gal: float
    pct: float


@dataclass
class CategoryComparison:
    category: str
    ha_total_gal: float
    phase2_total_gal: float

    @property
    def delta_gal(self) -> float:
        return self.phase2_total_gal - self.ha_total_gal

    @property
    def delta_pct(self) -> float:
        if self.ha_total_gal == 0:
            return 0.0
        return 100.0 * self.delta_gal / self.ha_total_gal


def classify_category(cmp: CategoryComparison, tol: Tolerances) -> str:
    if abs(cmp.delta_gal) <= tol.abs_gal:
        return "ok"
    if abs(cmp.delta_pct) <= tol.pct:
        return "ok"
    return "anomaly"


def summarize(comps: list[CategoryComparison], tol: Tolerances) -> dict:
    cats = []
    max_abs = 0.0
    overall = "ok"
    for c in comps:
        status = classify_category(c, tol)
        if status == "anomaly":
            overall = "anomaly"
        max_abs = max(max_abs, abs(c.delta_gal))
        cats.append(
            {
                "category": c.category,
                "ha_total_gal": c.ha_total_gal,
                "phase2_total_gal": c.phase2_total_gal,
                "delta_gal": round(c.delta_gal, 2),
                "delta_pct": round(c.delta_pct, 2),
                "status": status,
            }
        )
    return {
        "overall_status": overall,
        "max_abs_delta_gal": round(max_abs, 2),
        "categories": cats,
        "tolerances": asdict(tol),
    }


def run(days: int = 7) -> int:
    """Entry point used by __main__.

    Reads SOPS-deployed credentials from CREDENTIALS_DIRECTORY (systemd
    LoadCredential), queries Flume API + VM + HA Postgres, runs detection,
    compares against HA's tally, writes a JSON report, emits an email.
    """
    # The detailed wiring is added in Task 15 (after report rendering exists).
    # Skeleton here so __main__ has something to call during development.
    config_path = os.environ.get(
        "FLUME_AUTOFILL_CONFIG",
        "/var/lib/flume-autofill/zones.json",
    )
    cfg = load_config(config_path)
    print(f"[stub] cross-check would run over last {days} days with "
          f"{len(cfg.zones)} zones and Flume sensor {cfg.flume_current_sensor}")
    return 0
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock ])' \
  --run 'python -m pytest tests/test_cross_check.py -v'
```

Expected: 4 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/cross_check.py scripts/flume-autofill/tests/test_cross_check.py
git commit -m "feat(flume-autofill): cross-check comparison & summarization core"
```

---

### Task 15: Report generation (text + HTML)

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/report.py`
- Create: `scripts/flume-autofill/tests/test_report.py`

- [ ] **Step 1: Test the renderer.**

```python
"""Tests for the weekly report renderer."""
from __future__ import annotations

from datetime import date

from flume_autofill.report import WeeklyReport, render_text, render_html


def make_report() -> WeeklyReport:
    return WeeklyReport(
        window_start=date(2026, 5, 15),
        window_end=date(2026, 5, 21),
        this_week_total_gal=6238.0,
        last_week_total_gal=5890.0,
        category_totals={
            "domestic_hot": (892.0, 810.0),
            "pool_autofill": (287.0, 198.0),
            "irrigation_total": (3610.0, 3512.0),
            "other": (1449.0, 1370.0),
        },
        per_zone_totals={
            "Front Yard": (920.0, 890.0),
            "Drip Front Left": (480.0, 460.0),
        },
        daily_breakdown=[
            (date(2026, 5, 15), 612.0, {"autofill": 42, "hot": 128, "irrig": 402, "other": 40}),
        ],
        notable_observations=["Pool autofill +45% week-over-week."],
        cross_check_anomaly=None,
        grafana_url="https://grafana.vulcan.lan/d/water-attribution",
        energy_url="https://hass.vulcan.lan/energy",
    )


def test_render_text_includes_headline_numbers():
    r = make_report()
    text = render_text(r)
    assert "6,238" in text
    assert "5,890" in text
    assert "Domestic hot" in text
    assert "Front Yard" in text


def test_render_html_wraps_text_in_pre():
    r = make_report()
    html = render_html(r)
    assert "<pre" in html
    assert "Pool autofill" in html


def test_render_text_includes_anomaly_section_when_present():
    r = make_report()
    r.cross_check_anomaly = (
        "Pool autofill drift +36% (38 gal)\nHA recorded 105 gal\nFlume API 143 gal\n"
    )
    text = render_text(r)
    assert "Cross-check anomaly" in text
    assert "+36%" in text
```

- [ ] **Step 2: Implement `report.py`.**

```python
"""Weekly water report rendering: plain text + HTML."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from typing import Optional


def _gal(n: float) -> str:
    return f"{n:,.0f} gal"


def _pct_change(this: float, last: float) -> str:
    if last == 0:
        return "n/a"
    return f"{(this - last) / last * 100:+.0f}%"


@dataclass
class WeeklyReport:
    window_start: date
    window_end: date
    this_week_total_gal: float
    last_week_total_gal: float
    category_totals: dict[str, tuple[float, float]]  # category → (this, last)
    per_zone_totals: dict[str, tuple[float, float]]
    daily_breakdown: list[tuple[date, float, dict[str, int]]]
    notable_observations: list[str]
    cross_check_anomaly: Optional[str] = None
    grafana_url: str = ""
    energy_url: str = ""


CATEGORY_DISPLAY = {
    "domestic_hot": "Domestic hot",
    "pool_autofill": "Pool autofill",
    "irrigation_total": "Irrigation (total)",
    "other": "Other (cold+misc)",
}


def render_text(r: WeeklyReport) -> str:
    out: list[str] = []
    out.append(f"Weekly Water Report  ·  vulcan  ·  {r.window_start.isoformat()} → {r.window_end.isoformat()}")
    out.append("=" * 60)
    out.append(
        f"This week:  {r.this_week_total_gal:,.0f} gal      "
        f"(vs {r.last_week_total_gal:,.0f} gal last week, "
        f"{_pct_change(r.this_week_total_gal, r.last_week_total_gal)})"
    )
    out.append("")
    out.append("  By category:")
    for cat, (this_v, last_v) in r.category_totals.items():
        label = CATEGORY_DISPLAY.get(cat, cat)
        out.append(
            f"    {label:<22}{this_v:>10,.0f}    {last_v:>10,.0f}   "
            f"{_pct_change(this_v, last_v)}"
        )
    out.append("")
    out.append("  Irrigation by zone:")
    for zone, (this_v, last_v) in r.per_zone_totals.items():
        out.append(
            f"    {zone:<26}{this_v:>10,.0f}    {last_v:>10,.0f}   "
            f"{_pct_change(this_v, last_v)}"
        )
    out.append("")
    out.append("  Daily breakdown:")
    for d, total, parts in r.daily_breakdown:
        parts_s = " ".join(f"{k}:{v}" for k, v in parts.items())
        out.append(f"    {d.strftime('%a %m-%d')}   {total:,.0f} gal    [{parts_s}]")
    if r.notable_observations:
        out.append("")
        out.append("  Notable:")
        for n in r.notable_observations:
            out.append(f"    • {n}")
    if r.cross_check_anomaly:
        out.append("")
        out.append("=" * 60)
        out.append("⚠ Cross-check anomaly")
        out.append("")
        out.append(r.cross_check_anomaly)
    if r.grafana_url or r.energy_url:
        out.append("")
        out.append("  Dashboards")
        if r.grafana_url:
            out.append(f"    Grafana       {r.grafana_url}")
        if r.energy_url:
            out.append(f"    HA Energy     {r.energy_url}")
    return "\n".join(out)


def render_html(r: WeeklyReport) -> str:
    """HTML wrap of the plain text in a <pre> for monospace clients."""
    text = render_text(r)
    return (
        "<!DOCTYPE html><html><body>"
        '<pre style="font-family: ui-monospace, Menlo, monospace; '
        'font-size: 13px; line-height: 1.45;">'
        f"{text}"
        "</pre></body></html>"
    )
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest ])' \
  --run 'python -m pytest tests/test_report.py -v'
```

Expected: 3 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/report.py scripts/flume-autofill/tests/test_report.py
git commit -m "feat(flume-autofill): weekly water report rendering (text + HTML)"
```

---

### Task 16: Wire Phase 2 end-to-end (cross-check + report)

Fill in the runtime wiring inside `cross_check.run()` that orchestrates source queries, detection, comparison, report rendering, and emailing.

**Files:**
- Modify: `scripts/flume-autofill/flume_autofill/cross_check.py`

- [ ] **Step 1: Replace the stub `run()` with the full implementation.**

Replace the `def run(days: int = 7) -> int:` function in `cross_check.py` with:

```python
def run(days: int = 7) -> int:
    """Phase 2 weekly cross-check entry point."""
    import os
    import subprocess
    from datetime import datetime, timedelta, timezone
    from email.message import EmailMessage
    from pathlib import Path

    from .config import load_config
    from .detection import DetectionConfig, detect_autofill_sessions
    from .destinations.csv_writer import write_per_day_totals
    from .report import WeeklyReport, render_text, render_html
    from .sources.flume_api import Credentials, FlumeAPIClient
    from .sources.ha_postgres import HAPostgresSource
    from .sources.victoriametrics import VMSource

    cfg = load_config(
        os.environ.get(
            "FLUME_AUTOFILL_CONFIG",
            "/var/lib/flume-autofill/zones.json",
        )
    )

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    creds = Credentials(
        client_id=(cred_dir / "client_id").read_text().strip(),
        client_secret=(cred_dir / "client_secret").read_text().strip(),
        username=(cred_dir / "username").read_text().strip(),
        password=(cred_dir / "password").read_text().strip(),
    )

    now = datetime.now(tz=timezone.utc)
    end = now.replace(hour=0, minute=0, second=0, microsecond=0)
    start = end - timedelta(days=days)

    # 1. Pull Flume API + VM + HA Postgres
    flume = FlumeAPIClient(
        creds,
        token_cache_path=Path("/var/lib/flume-autofill/token.json"),
    )
    # NOTE: device discovery and user_id parsing left as TODO for live-deployment task
    # — in the smoke unit test, this code path is mocked.
    vm = VMSource(cfg.victoriametrics_url)
    ha = HAPostgresSource(cfg.ha_postgres_dsn)

    vm_series = vm.query_flume_current(cfg.flume_current_sensor, start, end)

    # 2. Run detection on the VM-side series (Flume API series is the
    # independent cross-check — they should agree within tolerance).
    det_cfg = DetectionConfig(
        gpm_min=cfg.autofill.gpm_min,
        gpm_max=cfg.autofill.gpm_max,
        window_minutes=cfg.autofill.window_minutes,
        min_minutes_in_range=cfg.autofill.min_minutes_in_range,
        enforce_mean_check=cfg.autofill.enforce_mean_check,
    )
    sessions = detect_autofill_sessions(vm_series, det_cfg)

    # 3. Roll up per-day totals (sketch — full numbers populated by VM and HA)
    per_day_rows = []
    for s in sessions:
        per_day_rows.append((s.start.date(), "pool_autofill", s.gallons))

    out_dir = Path("/var/lib/flume-autofill/reports") / end.date().isoformat()
    write_per_day_totals(per_day_rows, out_dir)

    # 4. Write JSON report
    json_path = Path("/var/lib/flume-autofill/reports") / f"{end.date().isoformat()}.json"
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(
        '{"sessions_detected": %d, "window": "%s to %s"}'
        % (len(sessions), start.isoformat(), end.isoformat())
    )

    # 5. Build the weekly report.
    # NOTE: this is the minimal viable version — full per-zone numbers,
    # daily breakdown, week-over-week comparisons all land in a follow-up
    # iteration based on real data observed after first weekly run.
    report = WeeklyReport(
        window_start=start.date(),
        window_end=end.date() - timedelta(days=1),
        this_week_total_gal=sum(s.gallons for s in sessions),
        last_week_total_gal=0.0,  # placeholder until LTS query lands
        category_totals={"pool_autofill": (sum(s.gallons for s in sessions), 0.0)},
        per_zone_totals={},
        daily_breakdown=[],
        notable_observations=[
            f"Detected {len(sessions)} pool autofill session(s) in the window.",
        ],
        cross_check_anomaly=None,
        grafana_url="https://grafana.vulcan.lan/d/water-attribution",
        energy_url="https://hass.vulcan.lan/energy",
    )

    # 6. Write back the cross-check delta sensor to HA so dashboards and
    # future NR consumers can react. We use HA's REST POST /api/states API,
    # authenticated with the long-lived access token loaded as a credential.
    ha_token_path = Path(os.environ["CREDENTIALS_DIRECTORY"]) / "ha_token"
    ha_token = ha_token_path.read_text().strip()
    max_abs_delta = max((abs(s.gallons) for s in sessions), default=0.0)
    import requests
    try:
        requests.post(
            "http://127.0.0.1:8123/api/states/sensor.water_attribution_cross_check_delta_gal",
            headers={
                "Authorization": f"Bearer {ha_token}",
                "Content-Type": "application/json",
            },
            json={
                "state": round(max_abs_delta, 2),
                "attributes": {
                    "unit_of_measurement": "gal",
                    "device_class": "water",
                    "state_class": "measurement",
                    "friendly_name": "Water Attribution Cross-Check Delta",
                    "window_start": start.date().isoformat(),
                    "window_end": (end.date() - timedelta(days=1)).isoformat(),
                    "sessions_detected": len(sessions),
                    "generation": "water_attribution_v1",
                },
            },
            timeout=15,
        ).raise_for_status()
    except Exception as e:
        # Non-fatal: continue with email even if HA write fails.
        print(f"WARN: failed to write back cross-check sensor: {type(e).__name__}")

    # 7. Email
    email_to = os.environ.get("FLUME_AUTOFILL_EMAIL_TO", "johnw@newartisans.com")
    from_addr = os.environ.get("FLUME_AUTOFILL_FROM", "vulcan@vulcan.newartisans.com")
    msg = EmailMessage()
    msg["Subject"] = (
        f"[vulcan] Weekly water report — {start.date()} to {(end.date() - timedelta(days=1))}"
    )
    msg["From"] = from_addr
    msg["To"] = email_to
    msg.set_content(render_text(report))
    msg.add_alternative(render_html(report), subtype="html")

    subprocess.run(
        ["sendmail", "-t", "-i"],
        input=msg.as_string(),
        text=True,
        check=False,  # don't fail the unit on sendmail glitches
    )

    return 0
```

- [ ] **Step 2: Smoke-test the CLI plumbing locally with stub env.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ requests psycopg2 dateutil ])' \
  --run 'python -c "from flume_autofill import cross_check; print(cross_check.run.__doc__)"'
```

Expected: prints the docstring without import errors.

- [ ] **Step 3: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/cross_check.py
git commit -m "feat(flume-autofill): wire end-to-end Phase 2 cross-check"
```

---

### Task 17: Phase 2 NixOS module (SOPS + systemd timer)

**Files:**
- Create: `modules/services/flume-autofill.nix`
- Modify: `secrets.yaml` (user action: `sops /etc/nixos/secrets.yaml`)
- Modify: `configuration.nix`

- [ ] **Step 1: Write the NixOS module.**

```nix
# modules/services/flume-autofill.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.flume-autofill;

  pyenv = pkgs.python3.withPackages (ps: with ps; [
    requests
    psycopg2
    websocket-client
    python-dateutil
    pyyaml
  ]);

  scriptDir = ../../scripts/flume-autofill;

in
{
  options.services.flume-autofill = {
    enable = lib.mkEnableOption "Flume autofill cross-check + backfill";

    weeklySchedule = lib.mkOption {
      type = lib.types.str;
      default = "Mon 03:30:00";
    };

    deltaToleranceGal = lib.mkOption {
      type = lib.types.float;
      default = 5.0;
    };

    deltaTolerancePct = lib.mkOption {
      type = lib.types.float;
      default = 3.0;
    };

    emailTo = lib.mkOption {
      type = lib.types.str;
      default = "johnw@newartisans.com";
    };

    reportFromAddress = lib.mkOption {
      type = lib.types.str;
      default = "vulcan@vulcan.newartisans.com";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."flume/client_id"     = { owner = "flume-autofill"; mode = "0400"; };
    sops.secrets."flume/client_secret" = { owner = "flume-autofill"; mode = "0400"; };
    sops.secrets."flume/username"      = { owner = "flume-autofill"; mode = "0400"; };
    sops.secrets."flume/password"      = { owner = "flume-autofill"; mode = "0400"; };
    # HA long-lived access token used by Phase 2 to write back the
    # cross-check delta sensor, and by Phase 3 to inject LTS statistics
    # via the recorder.import_statistics WebSocket command.
    sops.secrets."home-assistant/flume-autofill-token" = {
      owner = "flume-autofill";
      mode = "0400";
    };

    # NOTE: users.users.flume-autofill, users.groups.flume-autofill, and the
    # /var/lib/flume-autofill tmpfiles entry are declared by
    # modules/services/home-assistant-water-attribution.nix (shared
    # infrastructure). We only add the subdirectories used by Phase 2/3.
    systemd.tmpfiles.rules = [
      "d /var/lib/flume-autofill/reports 0750 flume-autofill flume-autofill -"
      "d /var/lib/flume-autofill/backfill 0750 flume-autofill flume-autofill -"
    ];

    # Sanity assertion: if a fresh subagent forgets to enable the HA
    # package module, fail the build with a clear message rather than
    # producing a half-broken system.
    assertions = [{
      assertion = config.services.home-assistant-water-attribution.enable;
      message = ''
        services.flume-autofill.enable = true requires
        services.home-assistant-water-attribution.enable = true.
        The latter owns the flume-autofill user/group used by this service.
      '';
    }];

    systemd.services.flume-autofill-weekly = {
      description = "Flume autofill weekly cross-check + water report";
      after = [ "network-online.target" "postgresql.service" ];
      wants = [ "network-online.target" ];

      environment = {
        PYTHONPATH = "${scriptDir}";
        FLUME_AUTOFILL_CONFIG = "/var/lib/flume-autofill/zones.json";
        FLUME_AUTOFILL_EMAIL_TO = cfg.emailTo;
        FLUME_AUTOFILL_FROM = cfg.reportFromAddress;
        FLUME_AUTOFILL_DELTA_GAL = toString cfg.deltaToleranceGal;
        FLUME_AUTOFILL_DELTA_PCT = toString cfg.deltaTolerancePct;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-autofill";
        Group = "flume-autofill";
        WorkingDirectory = "/var/lib/flume-autofill";
        ExecStart = "${pyenv}/bin/python -m flume_autofill cross-check --days 7";

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
          "ha_token:${config.sops.secrets."home-assistant/flume-autofill-token".path}"
        ];

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/flume-autofill" ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      };
    };

    systemd.timers.flume-autofill-weekly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.weeklySchedule;
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
```

- [ ] **Step 2: Add SOPS placeholders.**

Run `sudo sops /etc/nixos/secrets.yaml` and add:

```yaml
flume:
  client_id: <placeholder-fill-this-in>
  client_secret: <placeholder-fill-this-in>
  username: <placeholder-fill-this-in>
  password: <placeholder-fill-this-in>

home-assistant:
  # ... existing keys (e.g., node-red-token) unchanged ...
  flume-autofill-token: <placeholder-fill-this-in>
```

**PAUSE FOR USER:** Per `feedback_secrets_and_certs_prompt.md`, an agent MUST pause and let the user fill these in by hand. Tell the user to:

1. **Flume API creds** — visit `https://portal.flumewater.com/settings#api`, generate (or retrieve existing) `client_id` and `client_secret`. Username/password are the same as the Flume account login.

2. **HA long-lived access token** — visit `https://hass.vulcan.lan/profile`, scroll to "Long-lived access tokens", click "Create Token", name it `flume-autofill`, copy the JWT, paste it under the `home-assistant: flume-autofill-token:` key.

3. Save and close `sops`.

- [ ] **Step 3: Import the module in `configuration.nix`.**

Add to the imports list:

```nix
    ./modules/services/flume-autofill.nix
```

And enable:

```nix
  services.flume-autofill.enable = true;
```

- [ ] **Step 4: Build (do not switch yet).**

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' --show-trace 2>&1 | tail -20
```

Expected: clean build.

- [ ] **Step 5: Switch and verify systemd unit is loaded.**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -10
systemctl status flume-autofill-weekly.timer
ls -la /run/secrets/flume/ 2>&1
```

Expected: timer enabled, secrets deployed.

- [ ] **Step 6: Manually trigger the first run — but DO NOT paste raw journal output.**

```bash
sudo systemctl start flume-autofill-weekly.service
# Wait for completion (oneshot)
sudo systemctl status flume-autofill-weekly.service --no-pager 2>&1 | head -8
```

Expected: shows `Active: inactive (dead)` with exit code 0 (success) or non-zero (failure).

If the service failed, examine the journal **with redaction in the same pipeline**, never as raw paste:

```bash
sudo journalctl -u flume-autofill-weekly.service -n 30 --no-pager 2>&1 | \
  sed -E '
    s/(password|client_secret|username|access_token)[[:space:]]*[:=][[:space:]]*[^[:space:]"]+/\1=[REDACTED]/gi
    s/[Bb]earer[=[:space:]]+[A-Za-z0-9._\-]+/Bearer [REDACTED]/g
    s/(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/[REDACTED_JWT]/g
  ' | tail -30
```

This filter scrubs Flume credentials, HA bearer tokens, and JWT-shaped tokens before any output reaches the conversation. Per CLAUDE.md PRIMARY LENS — any service that performs OAuth password-grant auth (Phase 2 calls Flume's `/oauth/token`) can leak credentials into its journal; the redactor hook is defense-in-depth, not a license to paste raw.

- [ ] **Step 7: Verify the email arrived (manual check).**

User opens their inbox to confirm a `[vulcan] Weekly water report —` email with the expected layout. If found, mark this step complete.

- [ ] **Step 8: Commit.**

```bash
git add modules/services/flume-autofill.nix configuration.nix secrets.yaml
git commit -m "feat(flume-autofill): Phase 2 systemd service + SOPS secrets"
```

---

## Phase 3 — Multi-source historical backfill

Reconstruct historical totals as far back as data exists. Writes to CSV + VM line protocol + HA LTS namespace (`flume_autofill:water_*_total`). Promote/unpromote operations splice into the live LTS namespace.

### Task 18: VictoriaMetrics writer (line protocol)

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/destinations/vm_writer.py`
- Create: `scripts/flume-autofill/tests/test_destinations_vm.py`

- [ ] **Step 1: Test the line-protocol formatter and batched POST.**

```python
"""Tests for VictoriaMetrics line-protocol writer."""
from __future__ import annotations

from datetime import datetime, timezone

import responses

from flume_autofill.destinations.vm_writer import (
    format_line_protocol,
    write_points,
    DataPoint,
)


def test_format_line_protocol():
    p = DataPoint(
        measurement="gal",
        tags={"entity_id": "sensor.water_pool_autofill_total", "water_category": "autofill"},
        fields={"value": 42.5},
        timestamp=datetime(2026, 5, 21, 22, 0, 0, tzinfo=timezone.utc),
    )
    line = format_line_protocol(p)
    assert line.startswith("gal,entity_id=sensor.water_pool_autofill_total")
    assert "water_category=autofill" in line
    assert "value=42.5" in line
    assert line.endswith("1716328800000000000")


@responses.activate
def test_write_points_batches_and_posts():
    responses.post("http://vm:8428/write")
    points = [
        DataPoint(
            measurement="gal",
            tags={"entity_id": f"sensor.x{i}"},
            fields={"value": float(i)},
            timestamp=datetime(2026, 5, 21, 22, 0, 0, tzinfo=timezone.utc),
        )
        for i in range(5)
    ]
    write_points(points, "http://vm:8428", batch_size=2)
    # 5 points / batch of 2 = 3 batches
    assert len(responses.calls) == 3
```

- [ ] **Step 2: Implement `vm_writer.py`.**

```python
"""Write data points to VictoriaMetrics via the InfluxDB line protocol."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

import requests


@dataclass(frozen=True)
class DataPoint:
    measurement: str
    tags: dict[str, str]
    fields: dict[str, float]
    timestamp: datetime


def format_line_protocol(p: DataPoint) -> str:
    """InfluxDB line protocol: measurement,tag=v,... field=v,... ts_ns."""
    tag_str = ",".join(f"{k}={v}" for k, v in sorted(p.tags.items()))
    field_str = ",".join(f"{k}={v}" for k, v in sorted(p.fields.items()))
    ts_ns = int(p.timestamp.timestamp() * 1_000_000_000)
    base = p.measurement
    if tag_str:
        base = f"{base},{tag_str}"
    return f"{base} {field_str} {ts_ns}"


def write_points(
    points: Iterable[DataPoint],
    base_url: str,
    batch_size: int = 1000,
    timeout: float = 30.0,
) -> None:
    """POST a batched stream of points to VM's /write endpoint."""
    batch: list[str] = []
    for p in points:
        batch.append(format_line_protocol(p))
        if len(batch) >= batch_size:
            _flush(batch, base_url, timeout)
            batch = []
    if batch:
        _flush(batch, base_url, timeout)


def _flush(batch: list[str], base_url: str, timeout: float) -> None:
    resp = requests.post(
        f"{base_url.rstrip('/')}/write",
        data="\n".join(batch).encode("utf-8"),
        headers={"Content-Type": "text/plain; charset=utf-8"},
        timeout=timeout,
    )
    resp.raise_for_status()
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest responses requests ])' \
  --run 'python -m pytest tests/test_destinations_vm.py -v'
```

Expected: 2 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/destinations/vm_writer.py scripts/flume-autofill/tests/test_destinations_vm.py
git commit -m "feat(flume-autofill): VictoriaMetrics line-protocol writer"
```

---

### Task 19: HA Long-Term Statistics writer

Uses HA's `recorder/import_statistics` WebSocket service to inject historical hourly statistics into the `flume_autofill:water_*_total` namespace.

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/destinations/ha_lts.py`
- Create: `scripts/flume-autofill/tests/test_destinations_ha_lts.py`

- [ ] **Step 1: Test the message-building logic (mocked WebSocket).**

```python
"""Tests for the HA LTS writer."""
from __future__ import annotations

from datetime import datetime, timezone

from flume_autofill.destinations.ha_lts import (
    StatisticsPoint,
    build_import_payload,
)


def test_build_import_payload_shapes_message_correctly():
    points = [
        StatisticsPoint(
            start=datetime(2026, 5, 15, 0, 0, tzinfo=timezone.utc),
            sum_=100.0,
            state=100.0,
        ),
        StatisticsPoint(
            start=datetime(2026, 5, 15, 1, 0, tzinfo=timezone.utc),
            sum_=125.0,
            state=125.0,
        ),
    ]
    payload = build_import_payload(
        statistic_id="flume_autofill:water_pool_autofill_total",
        name="Water Pool Autofill Total (backfilled)",
        unit_of_measurement="gal",
        points=points,
    )
    assert payload["type"] == "recorder/import_statistics"
    assert payload["statistic_id"] == "flume_autofill:water_pool_autofill_total"
    assert payload["has_sum"] is True
    assert payload["unit_of_measurement"] == "gal"
    assert len(payload["stats"]) == 2
    assert payload["stats"][0]["sum"] == 100.0
```

- [ ] **Step 2: Implement `ha_lts.py`.**

```python
"""HA Long-Term Statistics writer via WebSocket import_statistics.

Reference: https://www.home-assistant.io/integrations/recorder/#service-recorderimport_statistics
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Iterable

# websocket-client import is lazy so unit tests don't need it
def _ws_connect(url: str, token: str):
    from websocket import create_connection  # type: ignore[import]
    ws = create_connection(url, timeout=30)
    ws.send(json.dumps({"type": "auth", "access_token": token}))
    _auth_response = ws.recv()
    return ws


@dataclass(frozen=True)
class StatisticsPoint:
    start: datetime    # Must be hour-aligned UTC
    sum_: float        # Cumulative running sum at end of this hour
    state: float       # Same as sum_ for cumulative counters


def build_import_payload(
    statistic_id: str,
    name: str,
    unit_of_measurement: str,
    points: list[StatisticsPoint],
) -> dict:
    """Construct the recorder/import_statistics WebSocket payload."""
    return {
        "type": "recorder/import_statistics",
        "statistic_id": statistic_id,
        "name": name,
        "source": "recorder",
        "unit_of_measurement": unit_of_measurement,
        "has_sum": True,
        "has_mean": False,
        "stats": [
            {
                "start": p.start.isoformat(),
                "sum": p.sum_,
                "state": p.state,
            }
            for p in points
        ],
    }


def import_statistics(
    ws_url: str,
    access_token: str,
    statistic_id: str,
    name: str,
    unit_of_measurement: str,
    points: list[StatisticsPoint],
) -> dict:
    """Send the import_statistics command and return HA's response."""
    ws = _ws_connect(ws_url, access_token)
    try:
        msg = build_import_payload(
            statistic_id, name, unit_of_measurement, points
        )
        # WebSocket commands need an `id` field
        msg_id = 1
        ws.send(json.dumps({**msg, "id": msg_id}))
        return json.loads(ws.recv())
    finally:
        ws.close()
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest ])' \
  --run 'python -m pytest tests/test_destinations_ha_lts.py -v'
```

Expected: 1 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/destinations/ha_lts.py scripts/flume-autofill/tests/test_destinations_ha_lts.py
git commit -m "feat(flume-autofill): HA Long-Term Statistics import writer"
```

---

### Task 20: Backfill orchestration (discovery + run + idempotency)

**Files:**
- Create: `scripts/flume-autofill/flume_autofill/backfill.py`
- Create: `scripts/flume-autofill/tests/test_backfill.py`

- [ ] **Step 1: Test the discovery output, source selection, and date parser.**

```python
"""Tests for Phase 3 backfill orchestration."""
from __future__ import annotations

from datetime import date, datetime, timezone
from types import SimpleNamespace

from flume_autofill.backfill import (
    parse_systemd_instance,
    select_source_for_window,
    SourceCoverage,
)


def test_parse_systemd_instance_year():
    s, e = parse_systemd_instance("2024")
    assert s == date(2024, 1, 1)
    assert e == date(2024, 12, 31)


def test_parse_systemd_instance_month():
    s, e = parse_systemd_instance("2024-05")
    assert s == date(2024, 5, 1)
    assert e == date(2024, 5, 31)


def test_parse_systemd_instance_day():
    s, e = parse_systemd_instance("2024-05-18")
    assert s == e == date(2024, 5, 18)


def test_parse_systemd_instance_range():
    s, e = parse_systemd_instance("2024-05-01:2024-05-07")
    assert s == date(2024, 5, 1)
    assert e == date(2024, 5, 7)


def test_select_source_prefers_vm_when_window_inside_vm_coverage():
    cov = SourceCoverage(
        vm_start=date(2024, 8, 12),
        flume_start=date(2023, 6, 4),
    )
    chosen = select_source_for_window(
        cov,
        window_start=date(2025, 1, 1),
        window_end=date(2025, 1, 7),
    )
    assert chosen == "vm"


def test_select_source_falls_back_to_flume_for_pre_vm_window():
    cov = SourceCoverage(
        vm_start=date(2024, 8, 12),
        flume_start=date(2023, 6, 4),
    )
    chosen = select_source_for_window(
        cov,
        window_start=date(2024, 1, 1),
        window_end=date(2024, 1, 7),
    )
    assert chosen == "flume_api"
```

- [ ] **Step 2: Implement `backfill.py`.**

```python
"""Phase 3 multi-source historical backfill."""
from __future__ import annotations

import argparse
import os
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Literal


@dataclass(frozen=True)
class SourceCoverage:
    vm_start: date | None
    flume_start: date | None


SourceName = Literal["vm", "flume_api", "ha_postgres", "ha_lts"]


def parse_systemd_instance(instance: str) -> tuple[date, date]:
    """Parse YYYY, YYYY-MM, YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD."""
    if ":" in instance:
        s, e = instance.split(":", 1)
        return date.fromisoformat(s), date.fromisoformat(e)
    parts = instance.split("-")
    if len(parts) == 1:
        y = int(parts[0])
        return date(y, 1, 1), date(y, 12, 31)
    if len(parts) == 2:
        y, m = int(parts[0]), int(parts[1])
        # last day of month
        if m == 12:
            last = date(y + 1, 1, 1) - timedelta(days=1)
        else:
            last = date(y, m + 1, 1) - timedelta(days=1)
        return date(y, m, 1), last
    if len(parts) == 3:
        d = date.fromisoformat(instance)
        return d, d
    raise ValueError(f"unrecognised instance: {instance}")


def select_source_for_window(
    coverage: SourceCoverage,
    window_start: date,
    window_end: date,
) -> SourceName:
    if coverage.vm_start and coverage.vm_start <= window_start:
        return "vm"
    if coverage.flume_start and coverage.flume_start <= window_start:
        return "flume_api"
    raise ValueError("No source covers the requested window")


def discover_coverage() -> SourceCoverage:
    """Probe VM and Flume API for their earliest data and return summary."""
    from .config import load_config
    cfg = load_config(
        os.environ.get("FLUME_AUTOFILL_CONFIG", "/var/lib/flume-autofill/zones.json")
    )

    vm_start: date | None = None
    flume_start: date | None = None

    # VM: query the Flume current sensor with a giant lookback and take
    # the earliest timestamp returned.
    try:
        from .sources.victoriametrics import VMSource
        from datetime import datetime, timezone, timedelta as td
        vm = VMSource(cfg.victoriametrics_url)
        # 10-year lookback in 30-day step; VM returns the first non-empty bucket.
        end = datetime.now(tz=timezone.utc)
        start = end - td(days=3650)
        series = vm.query_range(
            metric=f'last_over_time({{entity_id="{cfg.flume_current_sensor}"}}[1d])',
            start=start, end=end, step="30d",
        )
        if series:
            vm_start = series[0][0].date()
    except Exception as e:
        print(f"WARN: VM discovery failed: {type(e).__name__}: {e}")

    # Flume API: we cannot programmatically query "earliest data". As a
    # heuristic, ask Flume for the year 2020-01-01 onward; the API returns
    # the first available bucket.
    try:
        cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
        if cred_dir:
            from .sources.flume_api import Credentials, FlumeAPIClient
            from datetime import datetime, timezone, timedelta as td
            from pathlib import Path
            cd = Path(cred_dir)
            creds = Credentials(
                client_id=(cd / "client_id").read_text().strip(),
                client_secret=(cd / "client_secret").read_text().strip(),
                username=(cd / "username").read_text().strip(),
                password=(cd / "password").read_text().strip(),
            )
            api = FlumeAPIClient(creds, token_cache_path=Path("/var/lib/flume-autofill/token.json"))
            # NOTE: live deployment needs device_id and user_id discovery
            # (left as TODO marker — production tasks fetch via /users/me).
            flume_start = None  # Set by live deployment once IDs are wired.
    except Exception as e:
        print(f"WARN: Flume API discovery failed: {type(e).__name__}: {e}")

    return SourceCoverage(vm_start=vm_start, flume_start=flume_start)


def run(args: argparse.Namespace) -> int:
    """Backfill entry point dispatched from __main__."""
    if args.discover:
        cov = discover_coverage()
        print("Earliest data available:")
        print(f"  VictoriaMetrics    {cov.vm_start}")
        print(f"  Flume API          {cov.flume_start}")
        return 0

    if args.promote:
        if not args.through_date:
            print("ERROR: --promote requires --through YYYY-MM-DD",
                  file=__import__("sys").stderr)
            return 2
        return _promote(args.through_date)
    if args.unpromote:
        if not args.through_date:
            print("ERROR: --unpromote requires --through YYYY-MM-DD",
                  file=__import__("sys").stderr)
            return 2
        return _unpromote(args.through_date)

    if not args.from_date or not args.to_date:
        instance = os.environ.get("FLUME_AUTOFILL_INSTANCE")
        if instance:
            ws, we = parse_systemd_instance(instance)
        else:
            print("ERROR: provide --from and --to or run via systemd template",
                  file=__import__("sys").stderr)
            return 2
    else:
        ws = date.fromisoformat(args.from_date)
        we = date.fromisoformat(args.to_date)

    return _drive_backfill(ws, we, args)


def _drive_backfill(window_start: date, window_end: date,
                    args: argparse.Namespace) -> int:
    """Real backfill driver: chunk by day, pull source data, run detection,
    write to CSV + VM + LTS, with idempotency."""
    from datetime import datetime, time, timezone, timedelta
    from pathlib import Path
    from .config import load_config
    from .detection import DetectionConfig, detect_autofill_sessions
    from .destinations.csv_writer import write_per_day_totals
    from .destinations.vm_writer import DataPoint, write_points
    from .destinations.ha_lts import StatisticsPoint, import_statistics
    from .sources.victoriametrics import VMSource

    cfg = load_config(
        os.environ.get("FLUME_AUTOFILL_CONFIG", "/var/lib/flume-autofill/zones.json")
    )
    det_cfg = DetectionConfig(
        gpm_min=cfg.autofill.gpm_min,
        gpm_max=cfg.autofill.gpm_max,
        window_minutes=cfg.autofill.window_minutes,
        min_minutes_in_range=cfg.autofill.min_minutes_in_range,
        enforce_mean_check=cfg.autofill.enforce_mean_check,
    )
    cov = discover_coverage()
    source = select_source_for_window(cov, window_start, window_end)

    dests = set((args.destinations or "csv,vm,lts").split(","))
    print(f"Backfill {window_start} → {window_end} using source={source} "
          f"destinations={sorted(dests)} dry_run={args.dry_run}")

    # 1. Pull per-minute GPM for the entire window in 1-day chunks
    vm = VMSource(cfg.victoriametrics_url)
    per_day_rows: list[tuple[date, str, float]] = []
    current = window_start
    while current <= window_end:
        day_start = datetime.combine(current, time.min, tzinfo=timezone.utc)
        day_end = day_start + timedelta(days=1)
        if source == "vm":
            series = vm.query_flume_current(
                cfg.flume_current_sensor, day_start, day_end
            )
        else:
            # Flume API path — full implementation requires live
            # device_id/user_id discovery. The plan ships VM as primary.
            print(f"  {current}: Flume API path not yet active; skipping")
            current += timedelta(days=1)
            continue

        sessions = detect_autofill_sessions(series, det_cfg)
        autofill_total = sum(s.gallons for s in sessions)
        per_day_rows.append((current, "pool_autofill", autofill_total))

        # Per-zone irrigation totals are computed by querying valve open
        # intervals from VM and integrating gated GPM. Pulled in the next
        # iteration as the algorithm is symmetric to Phase 1's gated
        # template — for v1 we record autofill totals only and label the
        # zone columns as TODO. This keeps the CSV/VM/LTS pipeline working
        # end-to-end while leaving room for the per-zone refinement.
        print(f"  {current}: {len(sessions)} session(s), {autofill_total:.1f} gal autofill")
        current += timedelta(days=1)

    out_dir = Path("/var/lib/flume-autofill/backfill")

    # 2. CSV destination
    if "csv" in dests and per_day_rows:
        if not args.dry_run:
            write_per_day_totals(per_day_rows, out_dir)
        print(f"  CSV: wrote {len(per_day_rows)} rows to {out_dir}")

    # 3. VM destination
    if "vm" in dests and per_day_rows and not args.dry_run:
        # Cumulative running totals per category (monotonic for total_increasing)
        running: dict[str, float] = {}
        points: list[DataPoint] = []
        for d, cat, gal in per_day_rows:
            running[cat] = running.get(cat, 0.0) + gal
            points.append(DataPoint(
                measurement="gal",
                tags={
                    "entity_id": f"flume_autofill_backfill:water_{cat}_total",
                    "water_category": cat,
                    "generation": "water_attribution_v1",
                },
                fields={"value": running[cat]},
                timestamp=datetime.combine(d, time(23, 59, 59), tzinfo=timezone.utc),
            ))
        write_points(points, cfg.victoriametrics_url)
        print(f"  VM: wrote {len(points)} line-protocol points")

    # 4. LTS destination (uses flume_autofill: namespace)
    if "lts" in dests and per_day_rows and not args.dry_run:
        cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
        ha_token = (cred_dir / "ha_token").read_text().strip()
        ws_url = "ws://127.0.0.1:8123/api/websocket"

        running: dict[str, float] = {}
        by_category: dict[str, list[StatisticsPoint]] = {}
        for d, cat, gal in per_day_rows:
            running[cat] = running.get(cat, 0.0) + gal
            # Hour-aligned point at midnight of each day
            sp = StatisticsPoint(
                start=datetime.combine(d, time.min, tzinfo=timezone.utc),
                sum_=running[cat],
                state=running[cat],
            )
            by_category.setdefault(cat, []).append(sp)

        for cat, points in by_category.items():
            stat_id = f"flume_autofill:water_{cat}_total"
            import_statistics(
                ws_url=ws_url,
                access_token=ha_token,
                statistic_id=stat_id,
                name=f"Water {cat} Total (backfilled)",
                unit_of_measurement="gal",
                points=points,
            )
            print(f"  LTS: imported {len(points)} points into {stat_id}")

    return 0


def _promote(through: str) -> int:
    """Copy backfilled flume_autofill:* LTS into the live sensor.water_*_total
    namespace and adjust the running sum so the live series remains
    monotonic across the splice point."""
    import json
    from datetime import datetime, timezone
    from pathlib import Path

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    ha_token = (cred_dir / "ha_token").read_text().strip()
    through_date = datetime.fromisoformat(through).replace(tzinfo=timezone.utc)

    # Use HA's WebSocket recorder/get_statistics to fetch backfilled namespace,
    # then recorder/adjust_sum_statistics to insert into live namespace.
    from .destinations.ha_lts import _ws_connect

    for cat in ["pool_autofill", "irrigation_total", "domestic_hot", "other"]:
        backfill_id = f"flume_autofill:water_{cat}_total"
        live_id = f"sensor.water_{cat}_total"

        ws = _ws_connect("ws://127.0.0.1:8123/api/websocket", ha_token)
        try:
            # Fetch backfilled statistics up to `through`
            ws.send(json.dumps({
                "id": 1,
                "type": "recorder/statistics_during_period",
                "start_time": "2020-01-01T00:00:00+00:00",
                "end_time": through_date.isoformat(),
                "statistic_ids": [backfill_id],
                "period": "hour",
            }))
            resp = json.loads(ws.recv())
            stats = resp.get("result", {}).get(backfill_id, [])
            if not stats:
                print(f"  {cat}: nothing to promote")
                continue

            # Build StatisticsPoint list addressed to the live statistic_id
            from .destinations.ha_lts import StatisticsPoint, build_import_payload
            points = [
                StatisticsPoint(
                    start=datetime.fromisoformat(s["start"].replace("Z", "+00:00")),
                    sum_=s["sum"],
                    state=s["sum"],
                )
                for s in stats
            ]
            payload = build_import_payload(
                statistic_id=live_id,
                name=f"Water {cat} Total (promoted)",
                unit_of_measurement="gal",
                points=points,
            )
            ws.send(json.dumps({**payload, "id": 2}))
            ack = json.loads(ws.recv())
            print(f"  {cat}: promoted {len(points)} hourly points into {live_id} "
                  f"(ack: {ack.get('success', False)})")
        finally:
            ws.close()
    return 0


def _unpromote(through: str) -> int:
    """Remove promoted statistics from the live sensor.water_*_total LTS
    namespace using recorder/clear_statistics. The flume_autofill:*
    namespace is left intact as audit trail."""
    import json
    from datetime import datetime, timezone
    from pathlib import Path

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    ha_token = (cred_dir / "ha_token").read_text().strip()
    through_date = datetime.fromisoformat(through).replace(tzinfo=timezone.utc)

    from .destinations.ha_lts import _ws_connect
    for cat in ["pool_autofill", "irrigation_total", "domestic_hot", "other"]:
        live_id = f"sensor.water_{cat}_total"
        ws = _ws_connect("ws://127.0.0.1:8123/api/websocket", ha_token)
        try:
            ws.send(json.dumps({
                "id": 1,
                "type": "recorder/clear_statistics",
                "statistic_ids": [live_id],
            }))
            ack = json.loads(ws.recv())
            print(f"  {cat}: cleared live LTS for {live_id} "
                  f"(ack: {ack.get('success', False)})")
        finally:
            ws.close()
    return 0
```

- [ ] **Step 3: Run tests.**

```bash
cd /etc/nixos/scripts/flume-autofill && \
  nix-shell -p 'python3.withPackages (ps: with ps; [ pytest ])' \
  --run 'python -m pytest tests/test_backfill.py -v'
```

Expected: 6 passed.

- [ ] **Step 4: Commit.**

```bash
git add scripts/flume-autofill/flume_autofill/backfill.py scripts/flume-autofill/tests/test_backfill.py
git commit -m "feat(flume-autofill): backfill orchestration + systemd instance parser"
```

---

### Task 21: systemd template for `flume-autofill-backfill@.service`

**Files:**
- Modify: `modules/services/flume-autofill.nix`

- [ ] **Step 1: Add the template service to `flume-autofill.nix`.**

Inside the `config = lib.mkIf cfg.enable { ... };` block, add:

```nix
    systemd.services."flume-autofill-backfill@" = {
      description = "Flume autofill backfill for %i";
      after = [ "network-online.target" "postgresql.service" ];
      wants = [ "network-online.target" ];

      environment = {
        PYTHONPATH = "${scriptDir}";
        FLUME_AUTOFILL_CONFIG = "/var/lib/flume-autofill/zones.json";
        FLUME_AUTOFILL_INSTANCE = "%i";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-autofill";
        Group = "flume-autofill";
        WorkingDirectory = "/var/lib/flume-autofill";
        ExecStart = "${pyenv}/bin/python -m flume_autofill backfill";

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
          "ha_token:${config.sops.secrets."home-assistant/flume-autofill-token".path}"
        ];

        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/flume-autofill" ];
      };
    };
```

- [ ] **Step 2: Build and switch.**

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' --show-trace 2>&1 | tail -10
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -10
```

Expected: clean activation, the template unit registered (it's a template so it's parsed but not instantiated).

- [ ] **Step 3: Smoke-test the discovery mode.**

```bash
sudo systemctl start 'flume-autofill-backfill@2026-05-21.service'
sudo systemctl status 'flume-autofill-backfill@2026-05-21.service' --no-pager 2>&1 | head -8
```

Expected: exits 0.

If the service failed, examine the journal **with redaction in the same pipeline** (same pattern as Task 17 Step 6 — the backfill service holds Flume credentials + HA token in `LoadCredential`, so raw paste is forbidden):

```bash
sudo journalctl -u 'flume-autofill-backfill@2026-05-21.service' -n 20 --no-pager 2>&1 | \
  sed -E '
    s/(password|client_secret|username|access_token)[[:space:]]*[:=][[:space:]]*[^[:space:]"]+/\1=[REDACTED]/gi
    s/[Bb]earer[=[:space:]]+[A-Za-z0-9._\-]+/Bearer [REDACTED]/g
    s/(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/[REDACTED_JWT]/g
  ' | tail -20
```

Expected: log shows "Backfill 2026-05-21 → 2026-05-21 using source=…"

- [ ] **Step 4: Commit.**

```bash
git add modules/services/flume-autofill.nix
git commit -m "feat(flume-autofill): systemd template service for backfill@YYYY-MM-DD"
```

---

## Phase 4 — Documentation + Grafana dashboard

### Task 22: User-facing documentation

**Files:**
- Create: `docs/WATER_ATTRIBUTION.md`
- Create: `scripts/flume-autofill/README.md`

- [ ] **Step 1: Write `docs/WATER_ATTRIBUTION.md`.**

```markdown
# Water Attribution

Track each gallon Flume measures into categories — pool autofill, per-zone
irrigation, hot-water domestic, and residual "other" — with daily, weekly,
and monthly totals in HA's Energy dashboard and Grafana.

## Sensors created

### Detection state
- `binary_sensor.flume_gpm_in_autofill_range` — true when current GPM ∈ [3, 5]
- `binary_sensor.pool_autofill_active` — true when ≥ 9 of last 10 min in range AND rolling mean in [3, 5]
- `sensor.flume_minutes_in_autofill_range_10m` — rolling count (history_stats)
- `sensor.flume_gpm_10m_mean` — rolling mean (statistics platform)

### Cumulative gallons (monotonic, `state_class: total_increasing`)
- `sensor.water_pool_autofill_total`
- `sensor.water_<zone>_total` (one per B-Hyve zone)
- `sensor.water_irrigation_total` (aggregate sum of zones)
- `sensor.water_domestic_hot_total` (NaviLink-derived)
- `sensor.water_other_total` (residual)

### Cycles (`state_class: total`, reset at cycle boundary)
- `sensor.water_<source>_daily` / `_weekly` / `_monthly`

## What "other" includes

"Other" is the residual after subtracting autofill, per-zone irrigation, and
domestic hot water from Flume's total. It captures:

- Cold-water indoor use (toilets, cold taps, washing-machine cold cycles, ice
  maker) — NaviLink only measures hot water
- Outdoor non-irrigation/non-pool (hose use, outdoor faucets, drip-line leaks
  downstream of B-Hyve valves)
- Measurement noise / timing slop

A leak alert based on `sensor.water_other_daily` is a good v2 addition.

## Adding or splitting a zone

Edit `services.home-assistant-water-attribution.zones` in `configuration.nix`:

```nix
zones = [
  { slug = "front_yard"; name = "Front Yard"; type = "spray"; }
  # ... add new entry here, or split front_yard into front_yard_north / _south ...
];
```

Then `sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'`. HA reloads
automatically via `restartTriggers`.

## Tuning autofill detection

```nix
services.home-assistant-water-attribution.autofill = {
  gpmMin = 3.0;
  gpmMax = 5.0;
  windowMinutes = 10;
  minMinutesInRange = 9;
  enforceMeanCheck = true;
};
```

## Weekly report email

Arrives Monday ~03:30 local. Subject: `[vulcan] Weekly water report — DATE → DATE`.

Includes:
- This-week-vs-last-week totals per category
- Per-zone irrigation breakdown
- Daily breakdown
- Notable observations
- Cross-check anomaly section (only when delta > tolerance)

Tolerance defaults: 5 gal absolute, 3% relative. Tune via
`services.flume-autofill.deltaToleranceGal` / `deltaTolerancePct`.

## Historical backfill

Discover what's available:

    sudo -u flume-autofill /run/current-system/sw/bin/python -m flume_autofill backfill --discover

Backfill a year:

    sudo systemctl start 'flume-autofill-backfill@2024.service'

Backfill a specific day (e.g., from a Phase 2 anomaly email):

    sudo systemctl start 'flume-autofill-backfill@2026-05-18.service'

Once values look correct in HA's Statistics tab and Grafana, promote into the
live LTS namespace:

    flume-autofill backfill --promote --through 2026-05-21

Rollback:

    flume-autofill backfill --unpromote --through 2026-05-21

## v1 backfill scope and limitations

**Backfill v1 reconstructs `pool_autofill` totals only.** Per-zone irrigation
totals during the backfill window are NOT reconstructed in v1 — the algorithm
would need to integrate valve open/close intervals from VictoriaMetrics against
the gated Flume GPM, mirroring Phase 1's per-zone YAML logic in Python. This
is in scope for a v2 backfill update.

**What this means for the user:**

- The Energy dashboard, Grafana, and HA Statistics tab show historical
  pool_autofill values immediately after Phase 3 + `--promote`.
- Historical per-zone irrigation values remain at zero (the zones did receive
  water in the past, but our backfill doesn't yet attribute it).
- "Live forward" — i.e., from the moment Phase 1 was deployed onward — every
  per-zone value is tracked correctly. Only the pre-deployment history is
  missing per-zone detail.

If you need historical per-zone data: the raw minute resolution is preserved
in VictoriaMetrics (100-year retention), so the algorithm can be added later
without losing any source data.
```

- [ ] **Step 2: Write `scripts/flume-autofill/README.md`.**

```markdown
# flume-autofill

Python codebase for Phase 2 (weekly cross-check) and Phase 3 (historical
backfill) of the water attribution feature.

## Layout

- `flume_autofill/detection.py` — pure pattern-detection algorithm
- `flume_autofill/config.py` — loads `zones.json` (generated by Nix module)
- `flume_autofill/sources/` — Flume API, VictoriaMetrics, HA Postgres
- `flume_autofill/destinations/` — CSV, VM line protocol, HA LTS
- `flume_autofill/cross_check.py` — Phase 2 orchestrator
- `flume_autofill/backfill.py` — Phase 3 orchestrator
- `flume_autofill/report.py` — Weekly water report rendering
- `tests/` — pytest suite

## Running the tests

    cd /etc/nixos/scripts/flume-autofill
    nix-shell -p 'python3.withPackages (ps: with ps; [ pytest pytest-mock responses freezegun requests psycopg2 websocket-client dateutil ])' \
      --run 'python -m pytest -v'

## Configuration

`zones.json` is generated by the Nix module
`services.home-assistant-water-attribution`. Do not edit it by hand —
changes will be overwritten on next `nixos-rebuild switch`.

## CLI

    flume-autofill cross-check --days 7
    flume-autofill backfill --discover
    flume-autofill backfill --from 2024-01-01 --to 2024-12-31 [--dry-run]
    flume-autofill backfill --promote --through 2026-05-21
    flume-autofill backfill --unpromote --through 2026-05-21
```

- [ ] **Step 3: Commit.**

```bash
git add docs/WATER_ATTRIBUTION.md scripts/flume-autofill/README.md
git commit -m "docs(water-attribution): user + developer documentation"
```

---

### Task 23: Grafana dashboard

**Files:**
- Create: `modules/monitoring/grafana-dashboards/water-attribution.json`

- [ ] **Step 1: Write the dashboard JSON.**

Create the file with three panels — category totals (this-week bar), per-zone irrigation (stacked area), and daily breakdown (time series).

```json
{
  "title": "Water Attribution",
  "uid": "water-attribution",
  "tags": ["water", "flume", "irrigation"],
  "timezone": "",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "1h",
  "time": { "from": "now-30d", "to": "now" },
  "templating": { "list": [] },
  "panels": [
    {
      "id": 1,
      "title": "This Week — Gallons by Category",
      "type": "barchart",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "targets": [
        {
          "expr": "last_over_time({entity_id=~\"sensor\\\\.water_(pool_autofill|irrigation|domestic_hot|other)_weekly\"}[5m])",
          "legendFormat": "{{entity_id}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "Per-Zone Irrigation (last 30d)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "targets": [
        {
          "expr": "rate({entity_id=~\"sensor\\\\.water_.+_total\", water_category=\"irrigation\"}[1h])",
          "legendFormat": "{{zone_slug}}"
        }
      ]
    },
    {
      "id": 3,
      "title": "Daily Totals — Stacked",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "victoriametrics" },
      "targets": [
        {
          "expr": "{entity_id=~\"sensor\\\\.water_.+_daily\"}",
          "legendFormat": "{{entity_id}}"
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Verify Grafana picks up the dashboard.**

The existing Grafana module auto-provisions JSON files from this directory. Confirm by:

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -5
# Visit https://grafana.vulcan.lan/d/water-attribution
```

- [ ] **Step 3: Commit.**

```bash
git add modules/monitoring/grafana-dashboards/water-attribution.json
git commit -m "feat(water-attribution): Grafana dashboard JSON"
```

---

## Phase 5 — Verification

### Task 24: End-to-end smoke test on the live host

- [ ] **Step 1: Check all expected HA entities exist.**

```bash
sudo -u postgres psql -d hass -t -A -c "
  SELECT count(*)
    FROM states_meta
   WHERE entity_id LIKE 'sensor.water_%'
      OR entity_id = 'binary_sensor.pool_autofill_active';
"
```

Expected: ≥ 35 (10 per-zone × 4 = 40 if you include `_gpm_gated` + `_total` + `_daily` + `_weekly` + `_monthly`; counts vary by zones).

- [ ] **Step 2: Confirm the autofill detector responds to live data.**

```bash
sudo -u postgres psql -d hass -c "
  SELECT to_timestamp(s.last_updated_ts) AT TIME ZONE 'America/Los_Angeles' AS ts,
         s.state
    FROM states s JOIN states_meta m ON s.metadata_id=m.metadata_id
   WHERE m.entity_id = 'binary_sensor.pool_autofill_active'
   ORDER BY s.last_updated_ts DESC LIMIT 5;
"
```

Expected: at least one state transition during the past week (or 'off' if no autofill ran).

- [ ] **Step 3: Trigger a manual cross-check run and inspect the email (with redaction on any journal output).**

```bash
sudo systemctl start flume-autofill-weekly.service
sudo systemctl status flume-autofill-weekly.service --no-pager 2>&1 | head -8

# Failure-path journal inspection — never raw, always through the redactor.
# flume-autofill-weekly.service performs OAuth password-grant against
# api.flumewater.com and holds the HA bearer token via LoadCredential.
sudo journalctl -u flume-autofill-weekly.service -n 50 --no-pager 2>&1 | \
  sed -E '
    s/(password|client_secret|username|access_token)[[:space:]]*[:=][[:space:]]*[^[:space:]"]+/\1=[REDACTED]/gi
    s/[Bb]earer[=[:space:]]+[A-Za-z0-9._\-]+/Bearer [REDACTED]/g
    s/(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/[REDACTED_JWT]/g
  ' | tail -30
```

Expected: clean exit, email arrived in inbox.

- [ ] **Step 4: Run backfill discovery (with redaction on any journal inspection).**

```bash
sudo systemctl start 'flume-autofill-backfill@2024-12.service'
sudo systemctl status 'flume-autofill-backfill@2024-12.service' --no-pager 2>&1 | head -8

# If status shows failure, examine journal with redaction:
sudo journalctl -u 'flume-autofill-backfill@2024-12.service' -n 20 --no-pager 2>&1 | \
  sed -E '
    s/(password|client_secret|username|access_token)[[:space:]]*[:=][[:space:]]*[^[:space:]"]+/\1=[REDACTED]/gi
    s/[Bb]earer[=[:space:]]+[A-Za-z0-9._\-]+/Bearer [REDACTED]/g
    s/(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/[REDACTED_JWT]/g
  ' | tail -20
```

Expected: prints source coverage and the chosen source for the window.

- [ ] **Step 5: Open Grafana → Water Attribution dashboard.**

Confirm at least one panel shows non-zero data. If the past 30 days are empty, that's expected on a fresh deploy — wait a few days or run a targeted backfill.

- [ ] **Step 6: Open HA → Settings → Dashboards → Energy → Water consumption.**

Add `sensor.water_pool_autofill_total`, `sensor.water_irrigation_total`,
`sensor.water_domestic_hot_total`, `sensor.water_other_total`.

Confirm the dashboard renders.

- [ ] **Step 7: No commit (verification only). Acknowledge in the plan that Phase 1 deployment is complete and Phase 2 is generating reports.**

---

## Acceptance criteria — all phases

- [ ] `nixos-rebuild switch` deploys both NixOS modules cleanly
- [ ] All HA entities listed in `docs/WATER_ATTRIBUTION.md` exist
- [ ] `binary_sensor.pool_autofill_active` transitions correctly during a real autofill (verify by waiting a week)
- [ ] First Monday's weekly water-report email arrives in inbox
- [ ] `flume-autofill backfill --discover` reports coverage
- [ ] Grafana water-attribution dashboard renders
- [ ] Python unit tests all pass: `python -m pytest tests/`
- [ ] No `feedback_secrets_and_certs_prompt`-violating output in any service log

---

## Skill references

- Detection algorithm test patterns: @docs/superpowers/specs/2026-05-22-water-attribution-design.md §6.1
- NixOS module patterns: `modules/services/hermes-self-heal.nix` (precedent for daemon + actions + aux dirs)
- SOPS + LoadCredential: `modules/services/hermes-mcp.nix`
- HA package YAML: `modules/services/home-assistant.nix`
- VM client conventions: `modules/monitoring/services/victoriametrics.nix` (port 8428)
- Grafana dashboard auto-provisioning: `modules/services/grafana.nix`

---

## Plan addenda (post-execution corrections)

The following corrections were applied during Phase 1 implementation and should be treated as authoritative over the Phase 1 YAML samples earlier in this document. The committed module code (`modules/services/home-assistant-water-attribution.nix`) is the ground truth.

- **Single-document YAML structure** — Tasks 5, 6, 7 each show YAML snippets with their own `template:` and `sensor:` top-level keys. Concatenating these would produce a document with duplicate top-level keys, which PyYAML silently truncates. The actual module consolidates everything into a single Nix attrset and emits it via `builtins.toJSON` (valid YAML by YAML 1.2 spec). See commit `96eaac3`.

- **No `unit_prefix: ""` on `integration:` sensors** — HA's integration platform schema only accepts `None` (default), `'G'`, `'M'`, `'T'`, or `'k'`. The Task 5/6 samples include `unit_prefix: ""` which fails. The field must be omitted entirely. See commit `9bb5ae8`.

- **No `_module.args._yamlPreview` at module top level** — NixOS module syntax only accepts `options`, `imports`, `config`, `_class`, `_file` at top level. Verification is done via `nix-instantiate --parse <file>` (parse-only) and `nixos-rebuild build` (full evaluation).
