"""Tests for Phase 3 backfill orchestration."""
from __future__ import annotations

from datetime import date

from flume_autofill.backfill import (
    SourceCoverage,
    parse_systemd_instance,
    select_source_for_window,
)


def test_parse_systemd_instance_year():
    s, e = parse_systemd_instance("2024")
    assert s == date(2024, 1, 1)
    assert e == date(2024, 12, 31)


def test_parse_systemd_instance_month():
    s, e = parse_systemd_instance("2024-05")
    assert s == date(2024, 5, 1)
    assert e == date(2024, 5, 31)


def test_parse_systemd_instance_day():
    s, e = parse_systemd_instance("2024-05-18")
    assert s == e == date(2024, 5, 18)


def test_parse_systemd_instance_range():
    s, e = parse_systemd_instance("2024-05-01:2024-05-07")
    assert s == date(2024, 5, 1)
    assert e == date(2024, 5, 7)


def test_select_source_prefers_vm_when_window_inside_vm_coverage():
    """VM is preferred whenever it covers the window — it's the cheapest read."""
    cov = SourceCoverage(
        vm_start=date(2024, 8, 12),
        flume_start=date(2023, 6, 4),
    )
    chosen = select_source_for_window(
        cov,
        window_start=date(2025, 1, 1),
        window_end=date(2025, 1, 7),
    )
    assert chosen == "vm"


def test_select_source_falls_back_to_flume_for_pre_vm_window():
    """Pre-VM history falls back to the Flume API (slower but covers older data)."""
    cov = SourceCoverage(
        vm_start=date(2024, 8, 12),
        flume_start=date(2023, 6, 4),
    )
    chosen = select_source_for_window(
        cov,
        window_start=date(2024, 1, 1),
        window_end=date(2024, 1, 7),
    )
    assert chosen == "flume_api"
