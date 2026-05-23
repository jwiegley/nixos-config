"""v2 segment classifier with B-Hyve irrigation suppression.

A segment is `pool_autofill` if and only if ALL of:

  1. mean_gpm is in the tight band [GPM_BAND_MIN, GPM_BAND_MAX] around 3.5
  2. per-minute gpm is "sustained": stddev < STDDEV_MAX AND >= IN_BAND_FRAC
     of minutes fall in the tight band
  3. the segment does NOT overlap any irrigation session in
     `irrigation_sessions` (sourced from B-Hyve valve.* events in HA)

If we have no B-Hyve ground truth for the segment's date (rule 3 can't
be applied), the classification still computes rules 1+2 and notes
"(no B-Hyve data)" in the reason. The user can filter on that suffix
when querying.

Output `category_v2` values:

  * `pool_autofill`     — all three rules pass
  * `irrigation`        — overlaps a known B-Hyve session
  * `background`        — mean_gpm < BACKGROUND_GPM_MAX (faint leak / drip / noise)
  * `other`             — anything else (failed band or sustained checks)
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Sequence

# Public knobs — kept module-level so the backfill/test suites can
# parametrize them and the production sync code can override them
# without monkeypatching.
GPM_BAND_MIN: float = 3.2
GPM_BAND_MAX: float = 3.8
STDDEV_MAX: float = 0.6
IN_BAND_FRAC: float = 0.85
BACKGROUND_GPM_MAX: float = 1.0


@dataclass(frozen=True)
class SegmentV2Result:
    category: str
    reason: str


def _overlaps(
    seg_start: datetime,
    seg_end: datetime,
    irr_sessions: Sequence[tuple[datetime, datetime]],
) -> tuple[datetime, datetime] | None:
    """First irrigation session that overlaps the segment, or None."""
    for s_start, s_end in irr_sessions:
        if seg_start < s_end and seg_end > s_start:
            return (s_start, s_end)
    return None


def classify_segment(
    seg_date: date,
    seg_start_time: time,
    seg_end_time: time,
    mean_gpm: float,
    per_minute_gpm: Sequence[float],
    irrigation_sessions: Sequence[tuple[datetime, datetime]],
    have_valve_data: bool,
) -> SegmentV2Result:
    """Pure function. Returns (category, reason)."""
    seg_start = datetime.combine(seg_date, seg_start_time)
    # end_time in flume_segments is the last-minute timestamp, not an
    # exclusive boundary. Treat the segment as occupying [start, end+1min).
    seg_end = datetime.combine(seg_date, seg_end_time) + timedelta(minutes=1)
    # Same-day wrap if a segment crosses midnight (rare; flume_segments
    # is keyed on (date, start_time) so cross-midnight segments split).
    if seg_end <= seg_start:
        seg_end += timedelta(days=1)

    # ---- Rule 3 first: irrigation suppresses everything else.
    if have_valve_data:
        hit = _overlaps(seg_start, seg_end, irrigation_sessions)
        if hit is not None:
            s_start, s_end = hit
            return SegmentV2Result(
                category="irrigation",
                reason=(
                    f"overlaps B-Hyve session "
                    f"{s_start.strftime('%H:%M')}-{s_end.strftime('%H:%M')}"
                ),
            )

    no_valve_note = "" if have_valve_data else " (no B-Hyve data)"

    # ---- Background: very low flow, not a real draw event.
    if mean_gpm < BACKGROUND_GPM_MAX:
        return SegmentV2Result(
            category="background",
            reason=f"mean_gpm={mean_gpm:.2f} < {BACKGROUND_GPM_MAX:.1f}" + no_valve_note,
        )

    # ---- Rule 1: tight mean band around 3.5 GPM.
    if not (GPM_BAND_MIN <= mean_gpm <= GPM_BAND_MAX):
        return SegmentV2Result(
            category="other",
            reason=(
                f"mean_gpm={mean_gpm:.2f} outside [{GPM_BAND_MIN}, {GPM_BAND_MAX}]"
                + no_valve_note
            ),
        )

    # ---- Rule 2: sustained.
    n = len(per_minute_gpm)
    if n == 0:
        return SegmentV2Result(
            category="other",
            reason="no per-minute samples" + no_valve_note,
        )

    if n >= 2:
        stddev = statistics.stdev(per_minute_gpm)
    else:
        stddev = 0.0
    if stddev >= STDDEV_MAX:
        return SegmentV2Result(
            category="other",
            reason=(
                f"gpm_stddev={stddev:.2f} >= {STDDEV_MAX} (not sustained)"
                + no_valve_note
            ),
        )

    in_band = sum(1 for g in per_minute_gpm if GPM_BAND_MIN <= g <= GPM_BAND_MAX)
    in_band_frac = in_band / n
    if in_band_frac < IN_BAND_FRAC:
        return SegmentV2Result(
            category="other",
            reason=(
                f"only {in_band_frac:.0%} of {n} minutes in tight band "
                f"(need >= {IN_BAND_FRAC:.0%})" + no_valve_note
            ),
        )

    return SegmentV2Result(
        category="pool_autofill",
        reason=(
            f"mean={mean_gpm:.2f}, stddev={stddev:.2f}, "
            f"{in_band_frac:.0%} in band over {n} min" + no_valve_note
        ),
    )
