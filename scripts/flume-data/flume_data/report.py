"""Weekly water report rendering: plain text + HTML.

The text rendering aligns columns with fixed-width padding so the
monospace HTML wrap looks the same as the plain-text form. Email
clients that strip the HTML fall back to the text/plain alternative
without losing information.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date


def _gal(n: float) -> str:
    return f"{n:,.0f} gal"


def _pct_change(this: float, last: float) -> str:
    if last == 0:
        return "n/a"
    return f"{(this - last) / last * 100:+.0f}%"


@dataclass
class WeeklyReport:
    """All numbers needed to render one weekly report."""

    window_start: date
    window_end: date
    this_week_total_gal: float
    last_week_total_gal: float
    # category -> (this_week, last_week)
    category_totals: dict[str, tuple[float, float]]
    per_zone_totals: dict[str, tuple[float, float]]
    daily_breakdown: list[tuple[date, float, dict[str, int]]]
    notable_observations: list[str] = field(default_factory=list)
    cross_check_anomaly: str | None = None
    grafana_url: str = ""
    energy_url: str = ""


CATEGORY_DISPLAY = {
    "domestic_hot": "Domestic hot",
    "pool_autofill": "Pool autofill",
    "irrigation_total": "Irrigation (total)",
    "other": "Other (cold+misc)",
}


def render_text(r: WeeklyReport) -> str:
    """Render the plain-text body emailed to johnw@."""
    out: list[str] = []
    out.append(
        f"Weekly Water Report  ·  vulcan  ·  "
        f"{r.window_start.isoformat()} → {r.window_end.isoformat()}"
    )
    out.append("=" * 60)
    out.append(
        f"This week:  {r.this_week_total_gal:,.0f} gal      "
        f"(vs {r.last_week_total_gal:,.0f} gal last week, "
        f"{_pct_change(r.this_week_total_gal, r.last_week_total_gal)})"
    )
    out.append("")
    out.append("  By category:")
    for cat, (this_v, last_v) in r.category_totals.items():
        label = CATEGORY_DISPLAY.get(cat, cat)
        out.append(
            f"    {label:<22}{this_v:>10,.0f}    {last_v:>10,.0f}   "
            f"{_pct_change(this_v, last_v)}"
        )
    out.append("")
    out.append("  Irrigation by zone:")
    for zone, (this_v, last_v) in r.per_zone_totals.items():
        out.append(
            f"    {zone:<26}{this_v:>10,.0f}    {last_v:>10,.0f}   "
            f"{_pct_change(this_v, last_v)}"
        )
    out.append("")
    out.append("  Daily breakdown:")
    for d, total, parts in r.daily_breakdown:
        parts_s = " ".join(f"{k}:{v}" for k, v in parts.items())
        out.append(
            f"    {d.strftime('%a %m-%d')}   {total:,.0f} gal    [{parts_s}]"
        )
    if r.notable_observations:
        out.append("")
        out.append("  Notable:")
        for n in r.notable_observations:
            out.append(f"    • {n}")
    if r.cross_check_anomaly:
        out.append("")
        out.append("=" * 60)
        out.append("⚠ Cross-check anomaly")
        out.append("")
        out.append(r.cross_check_anomaly)
    if r.grafana_url or r.energy_url:
        out.append("")
        out.append("  Dashboards")
        if r.grafana_url:
            out.append(f"    Grafana       {r.grafana_url}")
        if r.energy_url:
            out.append(f"    HA Energy     {r.energy_url}")
    return "\n".join(out)


def render_html(r: WeeklyReport) -> str:
    """Wrap the plain-text body in a ``<pre>`` for monospace HTML clients.

    We don't try to render a "rich" HTML version: monospace alignment is
    exactly what the report layout depends on, and any HTML reflow would
    break the column tables.
    """
    text = render_text(r)
    return (
        "<!DOCTYPE html><html><body>"
        '<pre style="font-family: ui-monospace, Menlo, monospace; '
        'font-size: 13px; line-height: 1.45;">'
        f"{text}"
        "</pre></body></html>"
    )
