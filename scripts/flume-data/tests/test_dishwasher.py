"""Tests for the Miele dishwasher cycle extractor.

reconstruct_cycles + annotate_cycles_with_metadata are pure; everything
here exercises them tabular-style without HA or psycopg2.
"""
from __future__ import annotations

from datetime import datetime

from flume_data.dishwasher import (
    DishwasherCycle,
    annotate_cycles_with_metadata,
    reconstruct_cycles,
)


def DT(h: int, m: int, day: int = 1) -> datetime:
    return datetime(2026, 5, day, h, m)


def test_single_complete_cycle():
    """The canonical Miele cycle: pre_dishwash -> main_dishwash -> rinse
    -> final_rinse -> drying -> finished -> not_running."""
    events = [
        (DT(6, 31), "not_running"),
        (DT(6, 32), "pre_dishwash"),
        (DT(6, 52), "main_dishwash"),
        (DT(8, 43), "rinse"),
        (DT(9, 4), "final_rinse"),
        (DT(9, 24), "drying"),       # cycle ends here (no more water)
        (DT(9, 57), "finished"),
        (DT(10, 6), "not_running"),
    ]
    cycles = reconstruct_cycles(events)
    assert len(cycles) == 1
    start, end = cycles[0]
    assert start == DT(6, 32)
    assert end == DT(9, 24)


def test_aborted_cycle_is_dropped():
    """Door-opened-immediately abort: pre_dishwash for 19 sec then back
    to not_running. Real data showed two of these in the user's history."""
    events = [
        (DT(6, 9), "not_running"),
        (DT(6, 9, day=2), "pre_dishwash"),
        (DT(6, 10, day=2), "not_running"),  # less than 5min later
    ]
    cycles = reconstruct_cycles(events)
    assert cycles == []


def test_unavailable_flap_is_ignored():
    """The integration sometimes loses WiFi and emits unavailable;
    treat as continuation, don't end the cycle prematurely."""
    events = [
        (DT(6, 31), "not_running"),
        (DT(6, 32), "pre_dishwash"),
        (DT(7, 0), "unavailable"),    # flap
        (DT(7, 1), "main_dishwash"),  # resume
        (DT(8, 0), "drying"),
    ]
    cycles = reconstruct_cycles(events)
    assert len(cycles) == 1
    # End should still be 8:00 (start of drying), not earlier
    assert cycles[0][1] == DT(8, 0)


def test_two_back_to_back_cycles():
    """Two complete cycles separated by a not_running period."""
    events = [
        (DT(6, 32), "pre_dishwash"),
        (DT(8, 0), "drying"),
        (DT(9, 0), "not_running"),
        (DT(12, 0), "pre_dishwash"),
        (DT(14, 0), "drying"),
        (DT(15, 0), "not_running"),
    ]
    cycles = reconstruct_cycles(events)
    assert len(cycles) == 2
    assert cycles[0] == (DT(6, 32), DT(8, 0))
    assert cycles[1] == (DT(12, 0), DT(14, 0))


def test_water_phase_to_water_phase_does_not_create_new_cycle():
    """Transitioning pre_dishwash -> main_dishwash should NOT split the
    cycle. Both are water phases."""
    events = [
        (DT(6, 32), "pre_dishwash"),
        (DT(7, 0), "main_dishwash"),
        (DT(8, 0), "drying"),
    ]
    cycles = reconstruct_cycles(events)
    assert len(cycles) == 1


def test_finished_directly_from_water_phase_ends_cycle():
    """If the dishwasher skipped drying and went straight to finished."""
    events = [
        (DT(6, 32), "pre_dishwash"),
        (DT(8, 0), "finished"),
    ]
    cycles = reconstruct_cycles(events)
    assert len(cycles) == 1
    assert cycles[0][1] == DT(8, 0)


def test_annotate_picks_peak_consumption_and_program_at_start():
    """Per-cycle gallons = peak water_consumption inside window;
    program = most recent program-sensor value at-or-before start."""
    cycle_windows = [(DT(6, 32), DT(9, 24))]
    # cumulative gallons climb from 0.5 to 3.7
    consumption = [
        (DT(6, 33), 0.5),
        (DT(7, 0), 1.5),
        (DT(8, 30), 2.9),
        (DT(9, 0), 3.7),
        (DT(9, 30), 3.7),     # outside window — ignored
    ]
    programs = [
        (DT(0, 0), "Eco"),
        (DT(6, 30), "Normal"),  # the active program at cycle start
        (DT(10, 0), "Auto"),    # set later — not what was used
    ]
    cycles = annotate_cycles_with_metadata(cycle_windows, consumption, programs)
    assert len(cycles) == 1
    assert cycles[0] == DishwasherCycle(
        start_ts=DT(6, 32),
        end_ts=DT(9, 24),
        program="Normal",
        gallons=3.7,
    )


def test_annotate_handles_missing_consumption_gracefully():
    """If the consumption sensor was unavailable, gallons should be None."""
    cycle_windows = [(DT(6, 32), DT(9, 24))]
    cycles = annotate_cycles_with_metadata(cycle_windows, [], [(DT(0, 0), "Eco")])
    assert cycles[0].gallons is None
    assert cycles[0].program == "Eco"
