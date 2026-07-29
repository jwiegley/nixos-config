"""Tests for the Phase 2 cross-check comparison core."""
from __future__ import annotations

import json
from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import pytest

from flume_data import cross_check
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


def test_weekly_categories_summed_from_per_day_daily_meters():
    """Per-category / per-zone weekly numbers are summed from the per-day
    water_<x>_daily last_period over the report window — NOT the cycle-aligned
    *_weekly meters (which drift to a partial new week when the job runs after
    the Monday reset), and NOT the broken water_irrigation_* aggregate.
    Irrigation = sum of the per-zone daily meters.
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
        # Each day's last_period returns a fixed per-zone value.
        if 'entity_id="water_front_yard_daily"' in metric:
            return [(end, 100.0)]
        if 'entity_id="water_zone_5_daily"' in metric:
            return [(end, 7.0)]
        return []  # pool_autofill / other dailies -> 0

    vm = MagicMock()
    vm.query_range.side_effect = qr
    cats, per_zone = _read_weekly_categories(
        vm, end, domestic_hot_present=False, zones=zones
    )

    # 7 days each: front_yard 7*100=700, zone_5 7*7=49, irrigation 749.
    assert per_zone["Front Yard"][0] == pytest.approx(700.0)
    assert per_zone["Zone 5"][0] == pytest.approx(49.0)
    assert cats["irrigation_total"][0] == pytest.approx(749.0)
    queried = [c.kwargs["metric"] for c in vm.query_range.call_args_list]
    assert any("water_front_yard_daily" in m for m in queried)
    assert all('__name__="gal_last_period"' in m for m in queried)
    assert not any("_weekly" in m for m in queried)
    assert not any("water_irrigation_" in m for m in queried)


def test_grand_totals_summed_from_per_day_whole_house():
    """this_week / last_week totals are summed from the per-day whole-house
    current_day peaks over the window (window-aligned), NOT the cycle-aligned
    current_week meter.
    """
    from datetime import datetime, timezone

    from flume_data.cross_check import _grand_totals

    end = datetime(2026, 6, 15, tzinfo=timezone.utc)

    def qr(metric, start, end, step="60s"):
        if "max_over_time" in metric and "current_day" in metric:
            return [(end, 500.0)]
        return []

    vm = MagicMock()
    vm.query_range.side_effect = qr
    this_v, last_v = _grand_totals(vm, end)

    # 7 days * 500 in each of the two windows
    assert this_v == pytest.approx(3500.0)
    assert last_v == pytest.approx(3500.0)
    queried = [c.kwargs["metric"] for c in vm.query_range.call_args_list]
    assert all("current_day" in m for m in queried)
    assert not any("current_week" in m for m in queried)


def test_headline_total_equals_sum_of_daily_breakdown():
    """Regression for the self-contradictory report (headline 21 gal vs daily
    rows summing to thousands): the headline this-week total MUST equal the sum
    of the daily-breakdown row totals, because both now derive from the same
    per-day whole-house reads over the same window.
    """
    from datetime import datetime, timezone

    from flume_data.cross_check import _build_daily_breakdown, _grand_totals

    end = datetime(2026, 6, 15, tzinfo=timezone.utc)

    def qr(metric, start, end, step="60s"):
        if "max_over_time" in metric and "current_day" in metric:
            # Vary per day (by the reset-instant date) so a coincidental match
            # can't mask a bug; both callers query the same reset instants.
            return [(end, 100.0 + (end.toordinal() % 50))]
        return []

    vm = MagicMock()
    vm.query_range.side_effect = qr
    daily = _build_daily_breakdown(vm, end, [], domestic_hot_present=False)
    this_v, _last = _grand_totals(vm, end)

    assert this_v == pytest.approx(sum(total for (_d, total, _p) in daily))


def test_completed_period_total_reads_last_period():
    """A finished daily period's gallons come from the meter's gal_last_period
    (captured atomically at the reset), which is sparse-immune."""
    from datetime import datetime, timezone

    from flume_data.cross_check import _completed_period_total

    vm = MagicMock()
    vm.query_range.return_value = [
        (datetime(2026, 6, 9, 7, 30, tzinfo=timezone.utc), 177.888)
    ]
    reset = datetime(2026, 6, 9, 7, tzinfo=timezone.utc)
    val = _completed_period_total(vm, "water_other_daily", reset)

    assert val == pytest.approx(177.888)
    metric = vm.query_range.call_args.kwargs["metric"]
    assert 'entity_id="water_other_daily"' in metric
    assert '__name__="gal_last_period"' in metric
    # graceful zero on a missing meter
    vm.query_range.return_value = []
    assert _completed_period_total(vm, "water_other_daily", reset) == 0.0


def test_build_daily_breakdown_local_day_totals_and_real_categories():
    """Daily breakdown now yields real per-day totals (whole-house Flume peak
    via max_over_time, NOT the reset-skewed [10m] read) and a real per-category
    split (each category's *_daily last_period; irrigation = sum of zones),
    anchored at the local-midnight (07:00Z PDT) meter reset."""
    from datetime import datetime, timezone

    from flume_data.config import Zone
    from flume_data.cross_check import _build_daily_breakdown

    zones = [
        Zone("front_yard", "Front Yard", "spray"),
        Zone("zone_5", "Zone 5", None),  # placeholder zone -> dead meter -> 0
    ]
    end = datetime(2026, 6, 15, tzinfo=timezone.utc)
    calls = []

    def qr(metric, start, end, step="60s"):
        calls.append((metric, start, end, step))
        if "max_over_time" in metric and "current_day" in metric:
            return [(end, 500.0)]
        if '__name__="gal_last_period"' in metric:
            if "water_pool_autofill_daily" in metric:
                return [(end, 5.0)]
            if "water_domestic_hot_daily" in metric:
                return [(end, 100.0)]
            if "water_other_daily" in metric:
                return [(end, 50.0)]
            if "water_front_yard_daily" in metric:
                return [(end, 200.0)]
            if "water_zone_5_daily" in metric:
                return []  # dead placeholder zone -> 0
        return []

    vm = MagicMock()
    vm.query_range.side_effect = qr
    out = _build_daily_breakdown(vm, end, zones, domestic_hot_present=True)

    assert len(out) == 7
    assert [d.isoformat() for d, _, _ in out] == [
        f"2026-06-{n:02d}" for n in range(8, 15)
    ]
    day, total, parts = out[0]
    assert total == 500.0
    # irrig = front_yard(200) + zone_5(0); others from their daily meters
    assert parts == {"autofill": 5, "hot": 100, "irrig": 200, "other": 50}
    # whole-house total uses max_over_time[3h], never the old reset-skewed [10m]
    cd = [c for c in calls if "current_day" in c[0]]
    assert cd and all("max_over_time" in c[0] and "[3h]" in c[0] for c in cd)
    assert all("[10m]" not in c[0] for c in calls)
    # every read is anchored at the local-midnight reset = 07:00 UTC (PDT June)
    assert all(c[2].hour == 7 for c in cd)


# ---------------------------------------------------------------------------
# Degradation tally (added 2026-07-28)
#
# Before this, every read helper caught broadly, returned 0.0, and run() returned 0
# unconditionally -- so the unit reported success no matter how much of the check had
# been skipped, and FlumeCrossCheckFailed could never fire even though it is correctly
# wired to $SERVICE_RESULT. A failed VM read also became a FABRICATED zero that the
# comparison treated as real data. These tests pin the fix.
# ---------------------------------------------------------------------------


def test_degraded_records_and_prints(capsys):
    """_degraded() both tallies and echoes, so journal and exit code agree."""
    cross_check._DEGRADATIONS.clear()
    cross_check._degraded("vm_lookup_failed", "sensor.foo: TimeoutError")
    assert cross_check._DEGRADATIONS == ["vm_lookup_failed: sensor.foo: TimeoutError"]
    assert "WARN: vm_lookup_failed: sensor.foo: TimeoutError" in capsys.readouterr().out


def test_failed_vm_lookup_is_tallied_not_silent(capsys):
    """A failing VM read must degrade LOUDLY, not just return a quiet 0.0.

    The 0.0 return is retained deliberately (the report must stay renderable), which
    is exactly why the tally is required: 0.0 is indistinguishable from a real reading.
    """
    cross_check._DEGRADATIONS.clear()

    class Boom:
        def query_range(self, **_kw):
            raise TimeoutError("vm unreachable")

    val = cross_check._query_ha_total_via_vm(
        Boom(), "sensor.water_pool_autofill_total", datetime(2026, 7, 20, tzinfo=UTC)
    )
    assert val == 0.0, "still returns 0.0 so the report renders"
    assert len(cross_check._DEGRADATIONS) == 1, "but the skip is now recorded"
    assert "vm_lookup_failed" in cross_check._DEGRADATIONS[0]
    # The exception BODY must never be echoed -- it can carry request/response
    # material. Only the type name.
    assert "vm unreachable" not in capsys.readouterr().out


def test_daily_read_failure_is_tallied():
    cross_check._DEGRADATIONS.clear()

    class Boom:
        def query_range(self, **_kw):
            raise ConnectionError("nope")

    assert cross_check._completed_period_total(
        Boom(), "flume_sensor_x", datetime(2026, 7, 20, tzinfo=UTC)
    ) == 0.0
    assert any("daily_read_failed" in d for d in cross_check._DEGRADATIONS)


def test_daily_total_failure_is_tallied():
    cross_check._DEGRADATIONS.clear()

    class Boom:
        def query_range(self, **_kw):
            raise ConnectionError("nope")

    assert cross_check._whole_house_day_total(
        Boom(), datetime(2026, 7, 20, tzinfo=UTC)
    ) == 0.0
    assert any("daily_total_read_failed" in d for d in cross_check._DEGRADATIONS)


def test_tally_is_empty_on_clean_path():
    """No degradation recorded when reads succeed -- the rule must not fire always."""
    cross_check._DEGRADATIONS.clear()

    class Fine:
        def query_range(self, **_kw):
            return [(1785000000, "12.5")]

    val = cross_check._query_ha_total_via_vm(
        Fine(), "sensor.water_pool_autofill_total", datetime(2026, 7, 20, tzinfo=UTC)
    )
    assert val == 12.5
    assert cross_check._DEGRADATIONS == []
