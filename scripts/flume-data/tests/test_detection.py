"""Unit tests for the autofill detection algorithm."""
from __future__ import annotations

from datetime import datetime, timedelta

from flume_data.detection import (
    AutofillSession,  # noqa: F401  # public-API surface check
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


def test_9_min_at_4_gpm_then_drop_to_zero_yields_no_session():
    """Below the 10-min duration threshold -> no session."""
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
    """A 25 GPM spike (hose burst) pushes the rolling mean above 5.

    With the leading-edge debounce, the activity has only one rolling
    window that passes (at i=9) before the spike at i=10 fails the
    mean check, so no session is declared.
    """
    start = datetime(2026, 5, 22, 22, 0, 0)
    gpms = [4.0] * 10 + [25.0] + [4.0] * 5
    series = _series(start, gpms)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert sessions == []


def test_two_separate_autofills_30_min_apart():
    start = datetime(2026, 5, 22, 22, 0, 0)
    gpms = [4.0] * 15 + [0.0] * 30 + [4.0] * 15
    series = _series(start, gpms)
    sessions = detect_autofill_sessions(series, CONFIG)
    assert len(sessions) == 2
    assert all(round(s.gallons, 1) == 60.0 for s in sessions)
    assert sessions[0].end == start + timedelta(minutes=14)
    assert sessions[1].start == start + timedelta(minutes=45)


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
