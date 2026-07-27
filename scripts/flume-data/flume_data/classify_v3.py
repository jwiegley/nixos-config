"""v3 probabilistic classifier — produces per-segment fixture attributions.

For each segment, evaluates every fixture in `fixtures.FIXTURES`:
1. Applies hard constraints (must overlap irrigation, must be cold-only,
   custom predicate, etc.). Any constraint failure zeros that fixture.
2. Computes a likelihood score = product of Gaussian likelihoods (see
   `fixtures.Range`) over mean_gpm, duration, gallons, hot_fraction,
   peak/mean ratio.
3. Normalizes scores to probabilities (sum to 1).
4. If all fixtures score 0, emits a single ("unknown", 1.0) attribution.

`pool_autofill` is never scored here: v2 is authoritative for it, so
`classify()` short-circuits when `v2_category == "pool_autofill"` and
otherwise skips that fixture.

User labels from `flume_user_labels` override this entirely, but the
substitution happens in the CALLER (backfill_v3.py): when a label exists
it emits (user_fixture, 1.0) without calling `classify()` at all.
"""
from __future__ import annotations

from dataclasses import dataclass

from .fixtures import (
    COLD_THRESHOLD,
    FIXTURES,
    HOT_THRESHOLD,
    Fixture,
)


@dataclass(frozen=True)
class SegmentContext:
    """Inputs for classification. Pure data; the classifier reads only this."""
    mean_gpm: float
    duration_min: float
    gallons: float
    peak_gpm: float
    hot_gallons: float                 # sum of tankless GPM over segment minutes
    bhyve_overlaps: bool               # any irrigation session intersects?
    bhyve_zone_type: str | None        # 'spray' | 'drip' | 'bubbler' | None
    dishwasher_overlaps: bool          # any Miele cycle intersects?
    v2_category: str | None = None     # authoritative v2 label (overrides v3 for pool_autofill)

    @property
    def hot_fraction(self) -> float:
        if self.gallons <= 0:
            return 0.0
        return self.hot_gallons / self.gallons

    @property
    def peak_over_mean(self) -> float:
        if self.mean_gpm <= 0:
            return 1.0
        return self.peak_gpm / self.mean_gpm


@dataclass(frozen=True)
class Attribution:
    fixture: str
    probability: float
    gallons: float
    reason: str = ""


def _passes_hard_constraints(f: Fixture, ctx: SegmentContext) -> bool:
    if f.requires_bhyve_overlap and not ctx.bhyve_overlaps:
        return False
    if f.requires_dishwasher_overlap and not ctx.dishwasher_overlaps:
        return False
    if f.must_be_cold_only and ctx.hot_fraction > COLD_THRESHOLD:
        return False
    if f.must_be_hot_active and ctx.hot_fraction < HOT_THRESHOLD:
        return False
    if f.min_duration_min is not None and ctx.duration_min < f.min_duration_min:
        return False
    if f.max_duration_min is not None and ctx.duration_min > f.max_duration_min:
        return False
    if f.extra_filter is not None:
        ctx_dict = {
            "bhyve_zone_type": ctx.bhyve_zone_type,
            "dishwasher_overlaps": ctx.dishwasher_overlaps,
        }
        if not f.extra_filter(ctx_dict):
            return False
    # Fixtures that DON'T require B-Hyve overlap shouldn't fire DURING
    # an irrigation session (irrigation suppresses domestic detection).
    if ctx.bhyve_overlaps and not f.requires_bhyve_overlap:
        # Allow only dishwasher (rare overlap). pool_autofill is on a
        # different circuit but never reaches here — classify() skips that
        # fixture outright because v2 is authoritative for it. Treat the
        # rest as suppressed.
        if f.name not in ("dishwasher",):
            return False
    # Conversely, during a Miele cycle window, attribute to dishwasher.
    # This means a shower running concurrently with the dishwasher will
    # be miscategorized — recover via flume_user_labels when observed.
    if ctx.dishwasher_overlaps and not f.requires_dishwasher_overlap:
        return False
    return True


def _score(f: Fixture, ctx: SegmentContext) -> float:
    s = 1.0
    s *= f.mean_gpm.likelihood(ctx.mean_gpm)
    s *= f.duration_min.likelihood(ctx.duration_min)
    s *= f.gallons.likelihood(ctx.gallons)
    s *= f.hot_frac.likelihood(ctx.hot_fraction)
    s *= f.peak_over_mean.likelihood(ctx.peak_over_mean)
    return s


# Drop attributions below this probability to keep the table clean.
# Re-normalize remaining attributions so they still sum to 1.0.
MIN_KEEP_PROBABILITY = 0.05


def classify(ctx: SegmentContext) -> list[Attribution]:
    """Return list of attributions summing to probability=1.0, gallons
    summing to ctx.gallons (within rounding)."""
    # v2 is the authoritative pool autofill classifier (it enforces
    # stddev + in-band-fraction sustained-flow checks that v3's
    # probabilistic library is too lenient about). When v2 said yes,
    # short-circuit at 100%.
    if ctx.v2_category == "pool_autofill":
        return [Attribution(
            fixture="pool_autofill",
            probability=1.0,
            gallons=round(ctx.gallons, 3),
            reason="v2 sustained-flow classifier confirmed",
        )]

    scores: list[tuple[Fixture, float]] = []
    for f in FIXTURES:
        # When v2 has already ruled this segment out of pool_autofill,
        # don't even consider it in v3.
        if f.name == "pool_autofill":
            continue
        if not _passes_hard_constraints(f, ctx):
            continue
        s = _score(f, ctx)
        if s > 0:
            scores.append((f, s))

    if not scores:
        return [Attribution(
            fixture="unknown",
            probability=1.0,
            gallons=ctx.gallons,
            reason=f"no fixture matched mean={ctx.mean_gpm:.2f}, dur={ctx.duration_min}, "
                   f"hot_frac={ctx.hot_fraction:.2f}, peak/mean={ctx.peak_over_mean:.2f}",
        )]

    total = sum(s for _, s in scores)
    # First-pass probabilities
    raw_probs = [(f, s / total) for (f, s) in scores]
    # Drop noise then re-normalize so the kept rows sum to 1.0
    kept = [(f, p) for (f, p) in raw_probs if p >= MIN_KEEP_PROBABILITY]
    if not kept:
        # Everything was noise — fall back to top-1
        kept = [max(raw_probs, key=lambda fp: fp[1])]
    kept_total = sum(p for _, p in kept)

    out: list[Attribution] = []
    for f, p in kept:
        prob = p / kept_total
        out.append(Attribution(
            fixture=f.name,
            probability=round(prob, 3),
            gallons=round(ctx.gallons * prob, 3),
            reason=f"score-share={p:.2f}",
        ))
    out.sort(key=lambda a: -a.probability)
    return out
