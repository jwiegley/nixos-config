"""Tests for the weekly report renderer."""
from __future__ import annotations

from datetime import date

from flume_autofill.report import WeeklyReport, render_html, render_text


def make_report() -> WeeklyReport:
    return WeeklyReport(
        window_start=date(2026, 5, 15),
        window_end=date(2026, 5, 21),
        this_week_total_gal=6238.0,
        last_week_total_gal=5890.0,
        category_totals={
            "domestic_hot": (892.0, 810.0),
            "pool_autofill": (287.0, 198.0),
            "irrigation_total": (3610.0, 3512.0),
            "other": (1449.0, 1370.0),
        },
        per_zone_totals={
            "Front Yard": (920.0, 890.0),
            "Drip Front Left": (480.0, 460.0),
        },
        daily_breakdown=[
            (
                date(2026, 5, 15),
                612.0,
                {"autofill": 42, "hot": 128, "irrig": 402, "other": 40},
            ),
        ],
        notable_observations=["Pool autofill +45% week-over-week."],
        cross_check_anomaly=None,
        grafana_url="https://grafana.vulcan.lan/d/water-attribution",
        energy_url="https://hass.vulcan.lan/energy",
    )


def test_render_text_includes_headline_numbers():
    r = make_report()
    text = render_text(r)
    assert "6,238" in text
    assert "5,890" in text
    assert "Domestic hot" in text
    assert "Front Yard" in text


def test_render_html_wraps_text_in_pre():
    r = make_report()
    html = render_html(r)
    assert "<pre" in html
    assert "Pool autofill" in html


def test_render_text_includes_anomaly_section_when_present():
    r = make_report()
    r.cross_check_anomaly = (
        "Pool autofill drift +36% (38 gal)\nHA recorded 105 gal\nFlume API 143 gal\n"
    )
    text = render_text(r)
    assert "Cross-check anomaly" in text
    assert "+36%" in text
