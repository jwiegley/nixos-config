"""Tests for the zones.json loader."""
from __future__ import annotations

import json

import pytest

# Config is imported only as an API-surface check: load_config must
# return a Config and tests should be able to reference the type.
# Keep it in the import line via `# noqa: F401` rather than dropping it.
from flume_autofill.config import Config, Zone, load_config  # noqa: F401


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
    assert z.gated_gpm_sensor == "sensor.water_front_yard_gated_gpm"
    assert z.total_sensor == "sensor.water_front_yard_total"
