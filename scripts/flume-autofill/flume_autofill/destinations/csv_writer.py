"""CSV destination: one file per category, columns are `date,gallons`.

The writer is used by both Phase 2 (per-week roll-ups stored for later
review) and Phase 3 (full historical backfill exports). Output files
overwrite on each invocation — callers control the directory layout to
avoid clobbering prior runs.
"""
from __future__ import annotations

import csv
from collections import defaultdict
from datetime import date
from pathlib import Path


def write_per_day_totals(
    rows: list[tuple[date, str, float]],
    out_dir: Path,
) -> dict[str, Path]:
    """Write per-day totals into one CSV per category.

    Args:
        rows: ``(date, category, gallons)`` triples in any order.
        out_dir: target directory; created if missing.

    Returns:
        ``{category: written_path}`` mapping for the caller's verification.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    by_category: dict[str, list[tuple[date, float]]] = defaultdict(list)
    for d, cat, gal in rows:
        by_category[cat].append((d, gal))

    written: dict[str, Path] = {}
    for category, entries in by_category.items():
        entries.sort(key=lambda r: r[0])
        path = out_dir / f"{category}.csv"
        with path.open("w", newline="") as fh:
            writer = csv.writer(fh)
            writer.writerow(["date", "gallons"])
            for d, gal in entries:
                writer.writerow([d.isoformat(), gal])
        written[category] = path
    return written
