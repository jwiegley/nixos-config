"""Phase 2 cross-check entry point + comparison logic.

A "category comparison" pits HA's live tally for one bucket (pool_autofill,
irrigation_total, etc.) against the same total re-derived independently
by this Phase 2 service. If both the absolute and the percentage deltas
exceed the configured tolerances, we flag the category as an anomaly so
the weekly email surfaces it.
"""
from __future__ import annotations

import os
from dataclasses import asdict, dataclass

from .config import load_config


@dataclass
class Tolerances:
    """Cross-check tolerances. A category passes if *either* bound holds."""

    abs_gal: float
    pct: float


@dataclass
class CategoryComparison:
    """One category's HA total vs. Phase-2-rederived total."""

    category: str
    ha_total_gal: float
    phase2_total_gal: float

    @property
    def delta_gal(self) -> float:
        return self.phase2_total_gal - self.ha_total_gal

    @property
    def delta_pct(self) -> float:
        if self.ha_total_gal == 0:
            return 0.0
        return 100.0 * self.delta_gal / self.ha_total_gal


def classify_category(cmp: CategoryComparison, tol: Tolerances) -> str:
    """Return ``"ok"`` if either the absolute or percentage delta is within tolerance.

    The OR semantics matter for low-total categories: a 6 gal swing on
    a 12 gal weekly autofill is 50% drift but only 6 gallons, well within
    the noise floor of either measurement chain. We don't want to false-
    alarm on those.
    """
    if abs(cmp.delta_gal) <= tol.abs_gal:
        return "ok"
    if abs(cmp.delta_pct) <= tol.pct:
        return "ok"
    return "anomaly"


def summarize(comps: list[CategoryComparison], tol: Tolerances) -> dict:
    """Roll up a list of comparisons into a single JSON-ready report dict."""
    cats = []
    max_abs = 0.0
    overall = "ok"
    for c in comps:
        status = classify_category(c, tol)
        if status == "anomaly":
            overall = "anomaly"
        max_abs = max(max_abs, abs(c.delta_gal))
        cats.append(
            {
                "category": c.category,
                "ha_total_gal": c.ha_total_gal,
                "phase2_total_gal": c.phase2_total_gal,
                "delta_gal": round(c.delta_gal, 2),
                "delta_pct": round(c.delta_pct, 2),
                "status": status,
            }
        )
    return {
        "overall_status": overall,
        "max_abs_delta_gal": round(max_abs, 2),
        "categories": cats,
        "tolerances": asdict(tol),
    }


def run(days: int = 7) -> int:
    """Entry point used by ``__main__``.

    Stub implementation: the real orchestration (Flume API + VM + HA
    Postgres + detection + email) lands in Task 16. This stub exists so
    the CLI plumbing has something to call during development of the
    individual sources and destinations.
    """
    config_path = os.environ.get(
        "FLUME_AUTOFILL_CONFIG",
        "/var/lib/flume-autofill/zones.json",
    )
    cfg = load_config(config_path)
    print(
        f"[stub] cross-check would run over last {days} days with "
        f"{len(cfg.zones)} zones and Flume sensor {cfg.flume_current_sensor}"
    )
    return 0
