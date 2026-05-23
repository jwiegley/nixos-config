"""Tests for the v2 classifier.

The classifier is a pure function; everything here is parametrized
tabular data — no DB, no HA, no flume API.
"""
from __future__ import annotations

from datetime import datetime, date, time

import pytest

from flume_data.classify_v2 import classify_segment


# Helpers -------------------------------------------------------------

D = date(2026, 5, 21)
T = lambda h, m: time(h, m)  # noqa: E731


def steady_minutes(n: int, gpm: float) -> list[float]:
    return [gpm] * n


def jittery_minutes(n: int, base: float, jitter: float) -> list[float]:
    """Alternating +/- jitter to push stddev above 0.6 deterministically."""
    return [base + (jitter if i % 2 else -jitter) for i in range(n)]


# Rule 3: irrigation overlap suppresses everything ---------------------

def test_irrigation_overlap_wins_even_with_perfect_signal():
    """A segment with a textbook pool_autofill shape that sits inside an
    irrigation window must classify as irrigation, not pool_autofill.
    This is the headline failure mode that motivated v2."""
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(22, 12),
        seg_end_time=T(22, 19),
        mean_gpm=3.5,
        per_minute_gpm=steady_minutes(8, 3.5),
        irrigation_sessions=[
            (datetime(2026, 5, 21, 22, 0), datetime(2026, 5, 21, 23, 22)),
        ],
        have_valve_data=True,
    )
    assert result.category == "irrigation"
    assert "22:00-23:22" in result.reason


def test_no_irrigation_overlap_lets_pool_autofill_pass():
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(9, 15),
        seg_end_time=T(11, 0),
        mean_gpm=3.5,
        per_minute_gpm=steady_minutes(106, 3.5),
        irrigation_sessions=[
            (datetime(2026, 5, 21, 22, 0), datetime(2026, 5, 21, 23, 22)),
        ],
        have_valve_data=True,
    )
    assert result.category == "pool_autofill"


def test_segment_ends_exactly_when_irrigation_starts_is_safe():
    """Boundary case: segment [22:00..22:01) abuts irrigation [22:01..23:00).
    Per the half-open semantics we picked (end_time stored is inclusive
    last minute, segment occupies [start, end+1min)), a segment ending
    at 22:00 does NOT overlap a session starting at 22:01."""
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(21, 55),
        seg_end_time=T(22, 0),  # actually occupies [21:55, 22:01)
        mean_gpm=3.5,
        per_minute_gpm=steady_minutes(6, 3.5),
        irrigation_sessions=[
            (datetime(2026, 5, 21, 22, 1), datetime(2026, 5, 21, 22, 30)),
        ],
        have_valve_data=True,
    )
    assert result.category == "pool_autofill"


def test_no_valve_data_skips_irrigation_check_but_appends_note():
    """When B-Hyve history doesn't cover this date, rule 3 is skipped.
    Rules 1+2 still apply; the reason string carries the limitation."""
    result = classify_segment(
        seg_date=date(2024, 6, 1),
        seg_start_time=T(22, 30),
        seg_end_time=T(22, 50),
        mean_gpm=3.5,
        per_minute_gpm=steady_minutes(21, 3.5),
        irrigation_sessions=[],
        have_valve_data=False,
    )
    assert result.category == "pool_autofill"
    assert "(no B-Hyve data)" in result.reason


# Rule 1: tight mean band ----------------------------------------------

@pytest.mark.parametrize(
    "mean_gpm,expected",
    [
        (3.2, "pool_autofill"),  # lower edge inclusive
        (3.8, "pool_autofill"),  # upper edge inclusive
        (3.5, "pool_autofill"),
        (3.19, "other"),         # just below band
        (3.81, "other"),         # just above band
        (5.0, "other"),
        (8.0, "other"),
    ],
)
def test_mean_gpm_band(mean_gpm: float, expected: str):
    samples = steady_minutes(60, mean_gpm)
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(10, 0),
        seg_end_time=T(10, 59),
        mean_gpm=mean_gpm,
        per_minute_gpm=samples,
        irrigation_sessions=[],
        have_valve_data=True,
    )
    assert result.category == expected


def test_background_takes_precedence_over_band_check():
    """A segment with mean GPM well below 1.0 is `background`, not
    `other` — distinguishes faint constant leaks from genuine misfits."""
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(2, 0),
        seg_end_time=T(2, 30),
        mean_gpm=0.5,
        per_minute_gpm=steady_minutes(31, 0.5),
        irrigation_sessions=[],
        have_valve_data=True,
    )
    assert result.category == "background"


# Rule 2: sustained ----------------------------------------------------

def test_high_stddev_disqualifies_pool_autofill():
    """Even with the right mean, a segment that swings wildly is the
    irrigation drip tail, not a sustained autofill."""
    # Mean 3.5, but per-minute alternates 2.5/4.5 -> stddev ~1.0
    samples = jittery_minutes(40, base=3.5, jitter=1.0)
    mean = sum(samples) / len(samples)
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(10, 0),
        seg_end_time=T(10, 39),
        mean_gpm=mean,
        per_minute_gpm=samples,
        irrigation_sessions=[],
        have_valve_data=True,
    )
    assert result.category == "other"
    assert "stddev" in result.reason


def test_low_in_band_fraction_disqualifies_even_at_correct_mean():
    """Mean lands in [3.2, 3.8] by accident — half the minutes are at
    2.0, half at 5.0. Average = 3.5 but no individual minute is in band.
    The in-band-fraction check (>= 85%) catches this."""
    samples = [2.0] * 20 + [5.0] * 20  # mean 3.5, stddev ~1.5
    mean = sum(samples) / len(samples)
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(10, 0),
        seg_end_time=T(10, 39),
        mean_gpm=mean,
        per_minute_gpm=samples,
        irrigation_sessions=[],
        have_valve_data=True,
    )
    assert result.category == "other"


def test_steady_sample_with_short_segment_still_passes():
    """Single-minute observations are degenerate (stddev defined as 0).
    A 2-minute steady 3.5 GPM segment should still classify as
    pool_autofill — guards against an off-by-one in the stddev branch."""
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(10, 0),
        seg_end_time=T(10, 1),
        mean_gpm=3.5,
        per_minute_gpm=[3.5, 3.5],
        irrigation_sessions=[],
        have_valve_data=True,
    )
    assert result.category == "pool_autofill"


def test_empty_samples_classifies_as_other_not_crash():
    """Defensive: segment in flume_segments but no matching minute rows
    (would be a data integrity bug, but shouldn't crash the classifier)."""
    result = classify_segment(
        seg_date=D,
        seg_start_time=T(10, 0),
        seg_end_time=T(10, 5),
        mean_gpm=3.5,
        per_minute_gpm=[],
        irrigation_sessions=[],
        have_valve_data=True,
    )
    assert result.category == "other"
    assert "no per-minute samples" in result.reason
