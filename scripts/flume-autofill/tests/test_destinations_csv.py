"""Tests for the per-category CSV writer."""
from __future__ import annotations

from datetime import date

from flume_autofill.destinations.csv_writer import write_per_day_totals


def test_write_per_day_totals_creates_one_file_per_category(tmp_path):
    rows = [
        (date(2026, 5, 15), "pool_autofill", 42.3),
        (date(2026, 5, 16), "pool_autofill", 38.1),
        (date(2026, 5, 15), "irrigation_front_yard", 920.0),
    ]
    write_per_day_totals(rows, tmp_path)

    autofill = (tmp_path / "pool_autofill.csv").read_text()
    assert "2026-05-15,42.3" in autofill
    assert "2026-05-16,38.1" in autofill

    irrigation = (tmp_path / "irrigation_front_yard.csv").read_text()
    assert "2026-05-15,920.0" in irrigation
