"""Fixture library — calibrated signatures for vulcan's plumbing.

Each fixture defines:
- Expected mean GPM range (low, mid, high) — triangular likelihood peaks at mid
- Expected duration range in minutes
- Expected per-segment gallons range
- Hot fraction expectation (0 = cold-only, 1 = all hot)
- Peak/mean ratio expectation (washer has high peak/mean; sustained fixtures don't)
- Hard constraints (cold-only, must-overlap-irrigation, etc.)

These are STARTING POINTS calibrated from 4 days of correlated data
plus literature defaults where we lack samples. Re-calibrate every
~2 weeks as more data accumulates.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable


@dataclass(frozen=True)
class Range:
    """Gaussian likelihood centered on the range midpoint.

    sigma = (high - low) / 4, so the range spans ~±2σ from the mid.
    Values inside the range score ≥ 0.135; outside, the score decays
    smoothly to zero. The smoothness avoids the "edge-cliff" problem
    where a sample sitting exactly at `low` would score 0 under a
    triangular distribution and kill the whole fixture.
    """
    low: float
    high: float

    def __post_init__(self) -> None:
        if self.low > self.high:
            raise ValueError(f"Range low={self.low} > high={self.high}")

    @property
    def mid(self) -> float:
        return (self.low + self.high) / 2.0

    def likelihood(self, x: float) -> float:
        width = self.high - self.low
        if width <= 0:
            return 1.0 if x == self.low else 0.0
        sigma = width / 4.0
        return math.exp(-((x - self.mid) ** 2) / (2.0 * sigma * sigma))


@dataclass(frozen=True)
class Fixture:
    name: str
    mean_gpm: Range
    duration_min: Range
    gallons: Range
    hot_frac: Range
    peak_over_mean: Range
    # Hard constraints (all must pass or score = 0)
    requires_bhyve_overlap: bool = False
    requires_dishwasher_overlap: bool = False
    must_be_cold_only: bool = False    # hot_frac must be < COLD_THRESHOLD
    must_be_hot_active: bool = False   # hot_frac must be > HOT_THRESHOLD
    # Hard duration cutoffs (Gaussian falloff isn't strict enough for
    # things like leak detection, where a short background event would
    # still pick up a sliver of likelihood and dominate when nothing
    # else matches).
    min_duration_min: float | None = None
    max_duration_min: float | None = None
    # Free-form per-fixture predicate the classifier evaluates
    # (e.g., "B-Hyve zone is type=spray"). Returns True to keep, False to zero.
    extra_filter: Callable[[dict], bool] | None = field(default=None, compare=False)


# Thresholds for hot/cold classification (in hot_frac space)
COLD_THRESHOLD = 0.15
HOT_THRESHOLD = 0.30


# ---------- The library ----------
# Order matters for ties: earlier-listed fixtures win when scores equal.

FIXTURES: list[Fixture] = [
    # Ground-truth-bound fixtures — context predicates handled by the
    # classifier's hard constraints, not here.
    Fixture(
        name="irrigation_spray",
        mean_gpm=Range(8.0, 30.0),
        duration_min=Range(3.0, 90.0),
        gallons=Range(40.0, 700.0),
        hot_frac=Range(0.0, 0.1),
        peak_over_mean=Range(1.0, 3.0),
        requires_bhyve_overlap=True,
        must_be_cold_only=True,
        extra_filter=lambda ctx: ctx.get("bhyve_zone_type") == "spray",
    ),
    Fixture(
        name="irrigation_drip",
        mean_gpm=Range(0.8, 4.0),
        duration_min=Range(5.0, 30.0),
        gallons=Range(5.0, 60.0),
        hot_frac=Range(0.0, 0.1),
        peak_over_mean=Range(1.0, 2.5),
        requires_bhyve_overlap=True,
        must_be_cold_only=True,
        extra_filter=lambda ctx: ctx.get("bhyve_zone_type") == "drip",
    ),
    Fixture(
        name="irrigation_bubbler",
        mean_gpm=Range(0.8, 4.0),
        duration_min=Range(4.0, 20.0),
        gallons=Range(5.0, 40.0),
        hot_frac=Range(0.0, 0.1),
        peak_over_mean=Range(1.0, 2.5),
        requires_bhyve_overlap=True,
        must_be_cold_only=True,
        # Only match when zone is explicitly bubbler OR unknown type. The
        # current zones.json doesn't have bubblers, so this is the
        # null-type fallback (e.g., zone_5).
        extra_filter=lambda ctx: ctx.get("bhyve_zone_type") in (None, "bubbler"),
    ),
    Fixture(
        name="dishwasher",
        mean_gpm=Range(0.2, 2.0),
        duration_min=Range(1.0, 180.0),
        gallons=Range(0.5, 8.0),
        hot_frac=Range(0.3, 1.5),   # accept >1 due to Flume/tankless timing skew
        peak_over_mean=Range(1.0, 3.0),
        requires_dishwasher_overlap=True,
    ),
    # Pool autofill — handed off from v2 detector (same tight rules)
    Fixture(
        name="pool_autofill",
        mean_gpm=Range(3.2, 3.8),
        duration_min=Range(30.0, 200.0),
        gallons=Range(100.0, 700.0),
        hot_frac=Range(0.0, 0.1),
        peak_over_mean=Range(1.0, 1.5),
        must_be_cold_only=True,
    ),
    # Hot-water-using domestic
    Fixture(
        name="shower",
        mean_gpm=Range(1.3, 10.0),  # high end accommodates 3-4 simultaneous
        duration_min=Range(3.0, 30.0),
        gallons=Range(8.0, 80.0),
        hot_frac=Range(0.4, 1.5),
        peak_over_mean=Range(1.0, 2.0),
        must_be_hot_active=True,
    ),
    Fixture(
        name="sink_hot",
        mean_gpm=Range(0.3, 3.0),
        duration_min=Range(1.0, 5.0),
        gallons=Range(0.3, 8.0),
        hot_frac=Range(0.3, 1.5),
        peak_over_mean=Range(1.0, 3.0),
        must_be_hot_active=True,
    ),
    Fixture(
        name="clothes_washer_hot",
        mean_gpm=Range(2.0, 10.0),
        duration_min=Range(25.0, 70.0),
        gallons=Range(20.0, 60.0),
        hot_frac=Range(0.3, 0.8),
        peak_over_mean=Range(2.5, 8.0),  # high peak (fill pulses)
        must_be_hot_active=True,
    ),
    # Cold-only domestic
    Fixture(
        name="clothes_washer_cold",
        mean_gpm=Range(2.0, 10.0),
        duration_min=Range(25.0, 70.0),
        gallons=Range(20.0, 60.0),
        hot_frac=Range(0.0, 0.15),
        peak_over_mean=Range(2.5, 8.0),
        must_be_cold_only=True,
    ),
    Fixture(
        # Toilet refills are very consistent: ~1 minute, 1.3-1.6 gal,
        # ~1.4 GPM mean.
        name="toilet_flush",
        mean_gpm=Range(1.2, 2.5),
        duration_min=Range(0.8, 1.5),
        gallons=Range(1.2, 2.5),
        hot_frac=Range(0.0, 0.1),
        peak_over_mean=Range(0.9, 1.2),
        must_be_cold_only=True,
        max_duration_min=2.0,
    ),
    Fixture(
        # Sink (cold) — explicitly NOT 1-minute events (those are toilets).
        name="sink_cold",
        mean_gpm=Range(0.4, 2.5),
        duration_min=Range(1.5, 4.0),
        gallons=Range(0.5, 8.0),
        hot_frac=Range(0.0, 0.15),
        peak_over_mean=Range(1.0, 3.0),
        must_be_cold_only=True,
        max_duration_min=10.0,
    ),
    Fixture(
        # Defaults: dispenser ~0.4 GPM, ice maker ~0.6 GPM (per user
        # decision to use literature defaults until refrigerator make/
        # model tells us otherwise). Short events only.
        name="fridge_event",
        mean_gpm=Range(0.1, 1.0),
        duration_min=Range(1.0, 5.0),
        gallons=Range(0.1, 1.5),
        hot_frac=Range(0.0, 0.1),
        peak_over_mean=Range(1.0, 1.5),
        must_be_cold_only=True,
        max_duration_min=5.0,
    ),
    Fixture(
        # Leak detection is a long-duration low-flow signature ONLY.
        # Short low-flow events are sinks/fridges. Without the hard
        # min_duration_min cutoff, the Gaussian falloff still ranks
        # leak high for very short events when nothing else matches —
        # which produced ~21k false-positive leak labels on the first
        # backfill.
        name="leak",
        mean_gpm=Range(0.05, 0.3),
        duration_min=Range(60.0, 1440.0),
        gallons=Range(3.0, 200.0),
        hot_frac=Range(0.0, 0.3),
        peak_over_mean=Range(1.0, 1.2),
        min_duration_min=30.0,
    ),
]


def find_by_name(name: str) -> Fixture | None:
    for f in FIXTURES:
        if f.name == name:
            return f
    return None
