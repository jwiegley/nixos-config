"""Tests for the Phase 2 cross-check comparison core."""
from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import pytest

from flume_data.cross_check import (
    CategoryComparison,
    Tolerances,
    _build_category_comparisons,
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
    """abs delta is within budget, but the pct delta exceeds it."""
    tol = Tolerances(abs_gal=5.0, pct=3.0)
    cmp = CategoryComparison(
        category="pool_autofill",
        ha_total_gal=1000.0,
        phase2_total_gal=1050.0,  # 5% drift, both bounds breached
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


def test_build_category_comparisons_pulls_ha_total_from_vm():
    """``_build_category_comparisons`` queries VM for the HA-side tally and
    compares it against the Phase-2-rederived pool_autofill total.

    Regression check for the wiring fix: before Fix #3 the cross-check
    wrote ``max(abs(s.gallons))`` (the largest detected session size) to
    the HA sensor instead of the summary's actual max-abs-delta.
    """
    from datetime import datetime, timezone

    vm = MagicMock()
    # VM returns one matched row at the requested boundary; ``last_over_time``
    # always emits the most-recent sample within the window.
    vm.query_range.return_value = [
        (datetime(2026, 5, 22, tzinfo=timezone.utc), 105.5)
    ]

    comps = _build_category_comparisons(
        vm=vm,
        phase2_pool_autofill_gal=110.0,
        end=datetime(2026, 5, 22, tzinfo=timezone.utc),
    )

    assert len(comps) == 1
    assert comps[0].category == "pool_autofill"
    assert comps[0].ha_total_gal == pytest.approx(105.5)
    assert comps[0].phase2_total_gal == pytest.approx(110.0)
    # Sanity: VM was queried for the weekly utility-meter sensor, with the
    # `sensor.` domain prefix stripped (VM stores it as a separate label) and
    # pinned to the numeric value series.
    call = vm.query_range.call_args
    metric = call.kwargs.get("metric", "")
    assert 'entity_id="water_pool_autofill_weekly"' in metric
    assert "sensor.water_pool_autofill_weekly" not in metric
    assert '__name__=~".+_value"' in metric


def test_build_category_comparisons_returns_zero_on_vm_failure():
    """When VM fails for an HA-tally lookup, the comparison degrades
    gracefully to ``ha_total_gal=0.0`` rather than crashing the report."""
    from datetime import datetime, timezone

    vm = MagicMock()
    vm.query_range.side_effect = RuntimeError("network down")
    comps = _build_category_comparisons(
        vm=vm,
        phase2_pool_autofill_gal=42.0,
        end=datetime(2026, 5, 22, tzinfo=timezone.utc),
    )
    assert comps[0].ha_total_gal == 0.0
    assert comps[0].phase2_total_gal == 42.0


def test_cross_check_run_writes_summary_max_delta(tmp_path, monkeypatch):
    """End-to-end wiring check: cross_check.run() POSTs the summary's
    ``max_abs_delta_gal`` to HA, NOT ``max(abs(s.gallons))``.

    The fixture forces a single 100-gal session and a recorded HA total
    of 0 gal, so the expected max-abs-delta is 100.0 (Phase2=100 vs HA=0).
    Pre-fix this test would have asserted 100.0 too (same numbers), so
    the meaningful behavioural check is that the body matches
    ``summary["max_abs_delta_gal"]`` exactly — a different session-sum
    would surface the regression.
    """
    # Stand up a zones.json the loader can consume.
    cfg_data = {
        "flume_current_sensor": "sensor.flume_x_current",
        "domestic_hot_flow_sensor": None,
        "autofill": {
            "gpm_min": 3.0,
            "gpm_max": 5.0,
            "window_minutes": 10,
            "min_minutes_in_range": 9,
            "enforce_mean_check": True,
        },
        "cycles": ["weekly"],
        "zones": [],
        "victoriametrics_url": "http://127.0.0.1:8428",
        "ha_postgres_dsn": "postgresql:///hass",
    }
    cfg_path = tmp_path / "zones.json"
    cfg_path.write_text(json.dumps(cfg_data))

    cred_dir = tmp_path / "creds"
    cred_dir.mkdir()
    for k in ("client_id", "client_secret", "username", "password", "ha_token"):
        (cred_dir / k).write_text(f"fake-{k}")

    reports_dir = tmp_path / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)

    monkeypatch.setenv("FLUME_AUTOFILL_CONFIG", str(cfg_path))
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(cred_dir))
    monkeypatch.setenv("FLUME_AUTOFILL_DELTA_GAL", "5.0")
    monkeypatch.setenv("FLUME_AUTOFILL_DELTA_PCT", "3.0")
    monkeypatch.setenv("FLUME_AUTOFILL_REPORTS_DIR", str(reports_dir))

    # Patch the VM source so the Flume series and HA-tally lookup both
    # return controlled values. We need detection to find ONE session
    # so the per-day rollup writes a single row; the cross-check should
    # then compare phase2=session.gallons vs ha=42.0.
    fake_series_block = [(None, 4.0)] * 12  # 12 minutes in-range (debounced)
    # Build real timestamps for detection to work.
    from datetime import datetime, timedelta, timezone

    base = datetime(2026, 5, 22, 12, 0, tzinfo=timezone.utc)
    flume_series = [
        (base + timedelta(minutes=i), 4.0) for i in range(15)
    ]

    def vm_query_flume_current(entity_id, start, end):
        return flume_series

    def vm_query_range(metric, start, end, step="60s"):
        # All HA-tally lookups return a fixed value. The cross-check now
        # strips the `sensor.` domain prefix before querying VM.
        if "water_pool_autofill_weekly" in metric:
            return [(end, 42.0)]
        # Everything else (daily breakdown, etc.) returns empty.
        return []

    posted = {}

    def fake_post(url, headers=None, json=None, timeout=None):
        posted["url"] = url
        posted["headers"] = headers
        posted["body"] = json
        resp = MagicMock()
        resp.raise_for_status = lambda: None
        return resp

    fake_subprocess_run = MagicMock(
        return_value=MagicMock(returncode=0, stdout="", stderr="")
    )

    with patch(
        "flume_data.sources.victoriametrics.VMSource"
    ) as VMMock, patch(
        "flume_data.sources.flume_api.FlumeAPIClient"
    ) as _FlumeMock, patch(
        "flume_data.sources.ha_postgres.HAPostgresSource"
    ) as _HAMock, patch(
        "requests.post", side_effect=fake_post
    ), patch(
        "subprocess.run", fake_subprocess_run
    ):
        vm_inst = MagicMock()
        vm_inst.query_flume_current.side_effect = vm_query_flume_current
        vm_inst.query_range.side_effect = vm_query_range
        VMMock.return_value = vm_inst

        from flume_data.cross_check import run

        rc = run(days=7)

    assert rc == 0
    assert posted, "cross_check.run() did not POST to HA"
    body = posted["body"]
    # Pre-fix the value was max(abs(s.gallons)) (largest session size,
    # which equals the only session's 60.0 gallons — 4 gpm × 15 min).
    # Post-fix the value must equal summary["max_abs_delta_gal"], which
    # is |Phase2(60) - HA(42)| = 18.0.
    expected = abs(60.0 - 42.0)
    assert body["state"] == pytest.approx(expected, abs=0.5)
    # Sanity: the URL points at the cross-check delta sensor.
    assert (
        "sensor.water_attribution_cross_check_delta_gal" in posted["url"]
    )


def test_query_ha_total_uses_full_cycle_window_for_sparse_meters():
    """Headline water-report regression.

    HA mirrors its utility-meter sensors into VM only when their value
    CHANGES, so an intermittent category (pool_autofill, any irrigation
    zone) emits no sample in the final hours before the weekly boundary —
    even though its weekly total has been sitting in VM since its last run
    hours or days earlier. A short trailing window therefore read 0 for
    everything that wasn't flowing right at the boundary (continuous base
    load like domestic_hot/other was unaffected, which is why the bug hid).

    The read must span a full weekly cycle so ``last_over_time`` returns the
    most-recent in-cycle sample.
    """
    from datetime import datetime, timedelta, timezone

    from flume_data.cross_check import _query_ha_total_via_vm

    vm = MagicMock()
    # A single sample ~18h before the boundary (a Sunday-morning zone run).
    # The old [2h] window missed it; a weekly window catches it.
    vm.query_range.return_value = [
        (datetime(2026, 6, 14, 6, tzinfo=timezone.utc), 754.4)
    ]
    at = datetime(2026, 6, 15, tzinfo=timezone.utc)
    val = _query_ha_total_via_vm(vm, "sensor.water_front_yard_weekly", at)

    assert val == pytest.approx(754.4)
    call = vm.query_range.call_args
    metric = call.kwargs.get("metric", "")
    start = call.kwargs.get("start")
    assert "[2h]" not in metric
    assert "[7d]" in metric
    assert start <= at - timedelta(days=6)


def test_irrigation_total_is_sum_of_zones_not_the_broken_aggregate():
    """``sensor.water_irrigation_weekly`` (the HA template that sums the zone
    totals) can stick at 0 or go unavailable while the per-zone meters keep
    accumulating — which is exactly what zeroed the "Irrigation (total)"
    line. The report must reconstruct irrigation as the sum of the per-zone
    reads and must never consult the aggregate meter.
    """
    from datetime import datetime, timezone

    from flume_data.config import Zone
    from flume_data.cross_check import _read_weekly_categories

    zones = [
        Zone(slug="front_yard", name="Front Yard", type="spray"),
        Zone(slug="zone_5", name="Zone 5", type=None),
    ]
    end = datetime(2026, 6, 15, tzinfo=timezone.utc)

    def qr(metric, start, end, step="60s"):
        if 'entity_id="water_front_yard_weekly"' in metric:
            return [(end, 700.0)]
        if 'entity_id="water_zone_5_weekly"' in metric:
            return [(end, 49.0)]
        # The broken aggregate would (wrongly) report 0 — must be ignored.
        if 'entity_id="water_irrigation_weekly"' in metric:
            return [(end, 0.0)]
        return []  # pool_autofill / other / domestic_hot

    vm = MagicMock()
    vm.query_range.side_effect = qr
    cats, per_zone = _read_weekly_categories(
        vm, end, domestic_hot_present=False, zones=zones
    )

    assert cats["irrigation_total"][0] == pytest.approx(749.0)  # 700 + 49
    assert per_zone["Front Yard"][0] == pytest.approx(700.0)
    assert per_zone["Zone 5"][0] == pytest.approx(49.0)
    queried = [c.kwargs["metric"] for c in vm.query_range.call_args_list]
    assert not any("water_irrigation_weekly" in m for m in queried)


def test_grand_totals_prefer_authoritative_whole_house_meter():
    """``this_week``/``last_week`` totals come from the whole-house
    ``current_week`` Flume meter (continuously sampled, reliable at any
    window), falling back to the sum of category reads only when that meter
    is unavailable.
    """
    from datetime import datetime, timezone

    from flume_data.cross_check import _grand_totals

    end = datetime(2026, 6, 15, tzinfo=timezone.utc)

    def qr(metric, start, end, step="60s"):
        # current_week present at the this-week boundary, absent a week ago.
        if "current_week" in metric and end == datetime(
            2026, 6, 15, tzinfo=timezone.utc
        ):
            return [(end, 4997.6)]
        return []

    vm = MagicMock()
    vm.query_range.side_effect = qr
    cats = {"irrigation_total": (4149.0, 10.0), "other": (476.0, 290.0)}
    this_v, last_v = _grand_totals(vm, cats, end)

    # Whole-house meter wins over sum(categories) == 4625.
    assert this_v == pytest.approx(4997.6)
    # last week's current_week missing -> fall back to sum of last-week cats.
    assert last_v == pytest.approx(300.0)  # 10 + 290
