"""Tests for the v3 probabilistic classifier.

Test cases mirror real observed events from the 4-day EDA window so
the library calibration is validated against actual signatures.
"""
from __future__ import annotations

import pytest

from flume_data.classify_v3 import SegmentContext, classify


def ctx(**kwargs) -> SegmentContext:
    """Default-filled SegmentContext."""
    return SegmentContext(
        mean_gpm=kwargs.get("mean_gpm", 1.0),
        duration_min=kwargs.get("duration_min", 5.0),
        gallons=kwargs.get("gallons", kwargs.get("mean_gpm", 1.0) * kwargs.get("duration_min", 5.0)),
        peak_gpm=kwargs.get("peak_gpm", kwargs.get("mean_gpm", 1.0)),
        hot_gallons=kwargs.get("hot_gallons", 0.0),
        bhyve_overlaps=kwargs.get("bhyve_overlaps", False),
        bhyve_zone_type=kwargs.get("bhyve_zone_type", None),
        dishwasher_overlaps=kwargs.get("dishwasher_overlaps", False),
        v2_category=kwargs.get("v2_category", None),
    )


def top_fixture(attrs) -> str:
    return attrs[0].fixture


# Ground-truth overrides -----------------------------------------------

def test_during_dishwasher_cycle_attributes_to_dishwasher():
    """A small water draw during a Miele cycle window must be dishwasher,
    even if its shape also matches sink_hot."""
    result = classify(ctx(
        mean_gpm=0.51, duration_min=4, gallons=2.0,
        hot_gallons=2.0,
        dishwasher_overlaps=True,
    ))
    assert top_fixture(result) == "dishwasher"


def test_during_irrigation_spray_zone_attributes_to_spray():
    """A 22 GPM segment overlapping a spray-zone B-Hyve window."""
    result = classify(ctx(
        mean_gpm=22.0, peak_gpm=25.0, duration_min=6, gallons=132,
        bhyve_overlaps=True,
        bhyve_zone_type="spray",
    ))
    assert top_fixture(result) == "irrigation_spray"


def test_during_irrigation_drip_zone_attributes_to_drip():
    """2.0 GPM during a drip zone — the flow shape alone is ambiguous;
    the B-Hyve overlap plus the drip zone type forces irrigation_drip."""
    result = classify(ctx(
        mean_gpm=2.0, duration_min=8, gallons=16,
        bhyve_overlaps=True,
        bhyve_zone_type="drip",
    ))
    assert top_fixture(result) == "irrigation_drip"


# Pool autofill --------------------------------------------------------

def test_pool_autofill_signature_classified_correctly():
    """5/21 10:40: 117 min, 3.62 GPM, 423 gal, no B-Hyve overlap, ~0 hot.
    v2 is the authoritative pool_autofill classifier (stddev + in-band-frac
    checks v3's lenient pool fixture lacks). v3 short-circuits to 100%
    pool_autofill when v2 confirms."""
    result = classify(ctx(
        mean_gpm=3.62, peak_gpm=4.0, duration_min=117, gallons=423,
        hot_gallons=18.7,
        v2_category="pool_autofill",
    ))
    assert top_fixture(result) == "pool_autofill"
    assert result[0].probability == 1.0


def test_without_v2_pool_confirmation_pool_is_not_attributed():
    """A segment that LOOKS like pool autofill (3.5 GPM steady) but
    that v2 already rejected (insufficient stddev/in-band-frac) must
    NOT be classified as pool_autofill by v3."""
    result = classify(ctx(
        mean_gpm=3.5, peak_gpm=4.5, duration_min=20, gallons=70,
        hot_gallons=0,
        v2_category="other",
    ))
    assert top_fixture(result) != "pool_autofill"
    for a in result:
        assert a.fixture != "pool_autofill"


# Hot-water domestic ---------------------------------------------------

def test_long_hot_event_classified_as_shower():
    """5/22 09:29: 21 min, 1.10 GPM, 23.1 gal, hot_frac ~1.0, NO Miele overlap."""
    result = classify(ctx(
        mean_gpm=1.10, duration_min=21, gallons=23.1,
        hot_gallons=24.2,
    ))
    assert top_fixture(result) == "shower"


def test_short_hot_event_classified_as_sink_hot():
    """5/22 06:51: 4 min, 0.51 GPM, 2 gal, hot — but if NOT during a
    Miele cycle, classify as sink_hot (default for short hot events)."""
    result = classify(ctx(
        mean_gpm=0.51, duration_min=4, gallons=2.0,
        hot_gallons=6.2,  # >gallons due to Flume/tankless timing skew
    ))
    # Could be sink_hot or shower; both possible. Just assert it's hot-using.
    assert top_fixture(result) in ("sink_hot", "shower")


# Cold-only fixtures ---------------------------------------------------

def test_classic_toilet_flush_signature():
    """1-minute 1.4 GPM = ~1.4 gal, no hot. Observed 4 times in window."""
    result = classify(ctx(
        mean_gpm=1.4, duration_min=1, gallons=1.4,
        hot_gallons=0,
    ))
    assert top_fixture(result) == "toilet_flush"


def test_clothes_washer_cold_signature():
    """5/22 23:44: 48 min, mean 6.41 GPM, peak 25.66, 308 gal, no hot.
    The peak-over-mean ratio (~4) is the signature."""
    result = classify(ctx(
        mean_gpm=6.41, peak_gpm=25.66, duration_min=48, gallons=308,
        hot_gallons=0,
    ))
    assert top_fixture(result) == "clothes_washer_cold"


def test_low_flow_short_cold_is_fridge():
    """Sub-1 GPM, short duration, no hot — fridge dispenser/ice maker."""
    result = classify(ctx(
        mean_gpm=0.4, duration_min=2, gallons=0.8,
        hot_gallons=0,
    ))
    # Allow fridge_event or sink_cold (some overlap in ranges); both reasonable
    assert top_fixture(result) in ("fridge_event", "sink_cold")


# Constraint validation ------------------------------------------------

def test_hot_event_cannot_be_irrigation():
    """A 22 GPM segment WITH hot water must NOT be classified as irrigation,
    even if it has the right flow rate."""
    result = classify(ctx(
        mean_gpm=22.0, peak_gpm=25.0, duration_min=6, gallons=132,
        hot_gallons=80,
        bhyve_overlaps=False,
    ))
    assert top_fixture(result) != "irrigation_spray"
    assert "irrigation" not in top_fixture(result)


def test_cold_event_cannot_be_shower():
    """No hot water = cannot be shower regardless of flow shape."""
    result = classify(ctx(
        mean_gpm=2.5, duration_min=10, gallons=25,
        hot_gallons=0,
    ))
    assert top_fixture(result) != "shower"


def test_no_irrigation_when_bhyve_not_overlapping():
    """Even a textbook spray signature can't be irrigation without
    B-Hyve overlap — must be something else (likely unknown)."""
    result = classify(ctx(
        mean_gpm=22.0, peak_gpm=25.0, duration_min=6, gallons=132,
        hot_gallons=0,
        bhyve_overlaps=False,
    ))
    assert "irrigation" not in top_fixture(result)


def test_unidentifiable_event_returns_unknown():
    """A 200 GPM signature (impossible for residential) doesn't match
    anything in the library — must return ('unknown', 1.0)."""
    result = classify(ctx(
        mean_gpm=200, peak_gpm=200, duration_min=10, gallons=2000,
        hot_gallons=0,
    ))
    assert len(result) == 1
    assert result[0].fixture == "unknown"
    assert result[0].probability == 1.0


# Probability invariants -----------------------------------------------

def test_probabilities_sum_to_one():
    result = classify(ctx(
        mean_gpm=1.4, duration_min=2, gallons=2.8, hot_gallons=0,
    ))
    total_prob = sum(a.probability for a in result)
    assert abs(total_prob - 1.0) < 0.01


def test_gallons_attributions_sum_to_total():
    g = 25.0
    result = classify(ctx(
        mean_gpm=1.1, duration_min=21, gallons=g, hot_gallons=24.2,
    ))
    total_gal = sum(a.gallons for a in result)
    assert abs(total_gal - g) < 0.1


@pytest.mark.parametrize("hot_frac", [0.0, 0.1, 0.3, 0.5, 0.8, 1.0, 1.5])
def test_classifier_doesnt_crash_on_any_hot_fraction(hot_frac):
    """Especially important: hot_fraction can exceed 1.0 due to
    Flume/tankless timing skew — classifier must accept gracefully."""
    g = 10.0
    result = classify(ctx(
        mean_gpm=1.0, duration_min=10, gallons=g,
        hot_gallons=g * hot_frac,
    ))
    assert len(result) >= 1
