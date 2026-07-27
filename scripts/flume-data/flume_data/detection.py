"""Pool autofill detection algorithm.

A session is a contiguous run of minutes where >= `min_minutes_in_range`
of every rolling `window_minutes`-minute window land in
[`gpm_min`, `gpm_max`], and the rolling mean is also in that range when
`enforce_mean_check=True`.

The Python algorithm uses a leading-edge debounce (requires >= 2
consecutive rolling windows to satisfy the in-range + mean rules before
declaring a session). Phase 1's HA equivalent uses a trailing-edge
`delay_off: 1m` debounce -- the two converge for steady sessions, but
Phase 2 cross-check will see small boundary differences on real-world
data with mid-session dips. Document any persistent drift in the Phase 2
anomaly section.

The two also diverge structurally as of 2026-07-27: since the 2026-06
low-flow retune, the HA template additionally suppresses whenever
`binary_sensor.irrigation_active` is on or the domestic-hot leg is
flowing (see the irrigation/hot guards in
modules/services/home-assistant-water-attribution.nix). This module has
no such guards, so it can report sessions the HA sensor deliberately
drops -- expect that class of difference in the cross-check too.

This module is a pure function over a (timestamp, gpm) list. Sources and
destinations are layered on top.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime


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
    # `pending_start` records the window_start of the FIRST active window
    # in a run; we only promote it to `active_start` once we have two
    # consecutive active windows (i.e. the activity is sustained, not a
    # single-window blip).
    pending_start: int | None = None
    consecutive_active = 0

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

        if is_active_at_i:
            consecutive_active += 1
            if consecutive_active == 1:
                # Remember where this active run started; don't declare a
                # session yet.
                pending_start = window_start
            elif consecutive_active >= 2 and active_start is None:
                # Two windows in a row confirm a real session.
                active_start = pending_start
        else:
            if active_start is not None:
                # Session ended at the previous index.
                session = _build_session(in_range, active_start, i - 1)
                if session is not None:
                    sessions.append(session)
                active_start = None
            consecutive_active = 0
            pending_start = None

    if active_start is not None:
        session = _build_session(in_range, active_start, len(in_range) - 1)
        if session is not None:
            sessions.append(session)

    return sessions


def _build_session(
    in_range: list[tuple[datetime, float, bool]],
    start_idx: int,
    end_idx: int,
) -> AutofillSession | None:
    # Defensive guard: callers (detect_autofill_sessions) should never
    # pass an inverted span, but a future refactor that promotes `active_start`
    # without crossing through `start_idx <= end_idx` would silently produce
    # a 0-length session that crashes on `span[0]`. Bail out cleanly instead.
    if start_idx > end_idx:
        return None

    # Trim leading/trailing out-of-range minutes so session boundaries
    # reflect actual activity. Mid-session out-of-range minutes (e.g. a
    # one-minute blip) are preserved.
    while start_idx <= end_idx and not in_range[start_idx][2]:
        start_idx += 1
    while end_idx >= start_idx and not in_range[end_idx][2]:
        end_idx -= 1

    # All-out-of-range trims to an empty span — drop it.
    if start_idx > end_idx:
        return None

    span = in_range[start_idx : end_idx + 1]
    # 1 minute per sample; gpm * 1 = gal contribution.
    gallons = sum(gpm for _, gpm, _ in span)
    return AutofillSession(
        start=span[0][0],
        end=span[-1][0],
        gallons=round(gallons, 3),
    )


def run_cli(input_path: str) -> int:
    """CLI helper used by `flume-data detect --input X.csv`."""
    raise NotImplementedError("Wired in Phase 2 alongside the Flume API source.")
