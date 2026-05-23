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
from datetime import datetime, timedelta

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


def _query_ha_total_via_vm(
    vm,
    entity_id: str,
    at_time: datetime,
) -> float:
    """Read HA's recorded value for ``entity_id`` near ``at_time`` from VM.

    The HA recorder mirrors every sensor into VictoriaMetrics, so reading
    VM for HA's tally avoids a second psycopg2 path. ``last_over_time``
    over a 5-minute trailing window forgives small clock drift between
    HA's state update and VM ingestion.

    Returns ``0.0`` when no data is found or the query fails (best-effort
    — the cross-check degrades gracefully rather than crashing the report).
    """
    try:
        series = vm.query_range(
            metric=(
                f'last_over_time({{entity_id="{entity_id}"}}[5m])'
            ),
            start=at_time - timedelta(minutes=5),
            end=at_time,
            step="60s",
        )
        if not series:
            return 0.0
        # Take the latest value at or before at_time.
        return float(series[-1][1])
    except Exception as exc:  # noqa: BLE001
        print(
            f"WARN: VM lookup for {entity_id} failed: {type(exc).__name__}"
        )
        return 0.0


def _build_category_comparisons(
    vm,
    phase2_pool_autofill_gal: float,
    end: datetime,
) -> list[CategoryComparison]:
    """Compare HA's recorded category totals against Phase 2's recompute.

    Phase 2 currently only re-derives ``pool_autofill`` from the raw Flume
    signal in VM. Other categories (irrigation/domestic_hot/other) appear
    as 1-row "self-comparisons" so the summary at least surfaces an
    HA-side delta of zero — they'll grow real Phase 2 numbers in a later
    iteration. Until then, the meaningful row is ``pool_autofill``.
    """
    comps: list[CategoryComparison] = []

    pool_autofill_ha = _query_ha_total_via_vm(
        vm, "sensor.water_pool_autofill_weekly", end
    )
    comps.append(
        CategoryComparison(
            category="pool_autofill",
            ha_total_gal=pool_autofill_ha,
            phase2_total_gal=phase2_pool_autofill_gal,
        )
    )
    return comps


def _read_weekly_categories(
    vm,
    end: datetime,
    domestic_hot_present: bool,
    zones: list,
) -> tuple[dict[str, tuple[float, float]], dict[str, tuple[float, float]]]:
    """Best-effort: pull this-week / last-week numbers for every category + zone.

    Reads HA's existing ``*_weekly`` utility-meter sensors at the period
    boundary (this week's value as of ``end``, last week's as of ``end -
    7d``). On any failure for a given metric we land 0.0 in that slot and
    move on — the report's `notable_observations` flags any zero-vs-real
    asymmetries.
    """
    last_week = end - timedelta(days=7)
    category_totals: dict[str, tuple[float, float]] = {}
    cats = ["pool_autofill", "irrigation_total", "other"]
    if domestic_hot_present:
        cats.append("domestic_hot")
    for cat in cats:
        eid = f"sensor.water_{cat}_weekly"
        this_v = _query_ha_total_via_vm(vm, eid, end)
        last_v = _query_ha_total_via_vm(vm, eid, last_week)
        category_totals[cat] = (this_v, last_v)

    per_zone_totals: dict[str, tuple[float, float]] = {}
    for z in zones:
        eid = f"sensor.water_{z.slug}_weekly"
        display = getattr(z, "name", z.slug)
        per_zone_totals[display] = (
            _query_ha_total_via_vm(vm, eid, end),
            _query_ha_total_via_vm(vm, eid, last_week),
        )

    return category_totals, per_zone_totals


def _build_daily_breakdown(
    vm,
    flume_entity_id: str,
    end: datetime,
) -> list[tuple]:
    """Per-day total water (best-effort) for the trailing 7 days.

    Returns ``[(date, total_gal, parts_dict), ...]``. ``parts_dict`` is a
    rough categorisation that today only records the bucket name; per-
    bucket gallons land in a v2 once detection is wired across all
    categories. The current entry serves as a placeholder so the email
    layout stays consistent.
    """
    out: list[tuple] = []
    for offset in range(7, 0, -1):
        day_end = end - timedelta(days=offset - 1)
        day_start = day_end - timedelta(days=1)
        try:
            # Use HA's `current_day` Flume sensor sampled at end-of-day.
            series = vm.query_range(
                metric=(
                    'last_over_time({entity_id='
                    '"sensor.flume_sensor_sierra_oaks_current_day"}[10m])'
                ),
                start=day_end - timedelta(minutes=10),
                end=day_end,
                step="60s",
            )
            total = float(series[-1][1]) if series else 0.0
        except Exception as exc:  # noqa: BLE001
            print(
                f"WARN: daily breakdown for {day_start.date()} failed: "
                f"{type(exc).__name__}"
            )
            total = 0.0
        out.append(
            (
                day_start.date(),
                total,
                {"autofill": 0, "hot": 0, "irrig": 0, "other": 0},
            )
        )
    return out


def _notable_observations(
    category_totals: dict[str, tuple[float, float]],
) -> list[str]:
    """Bullet points generated from category-level deltas.

    Mention a category when the week-over-week percentage shift exceeds
    25%. Skip when last_week is 0 (we get a divide-by-zero and the
    comparison isn't meaningful).
    """
    out: list[str] = []
    for cat, (this_v, last_v) in category_totals.items():
        if last_v == 0:
            if this_v > 0:
                out.append(
                    f"{cat}: {this_v:,.0f} gal this week (no prior-week "
                    f"baseline)."
                )
            continue
        pct = (this_v - last_v) / last_v * 100.0
        if abs(pct) >= 25.0:
            sign = "+" if pct >= 0 else ""
            out.append(
                f"{cat}: {sign}{pct:.0f}% week-over-week "
                f"({last_v:,.0f} → {this_v:,.0f} gal)."
            )
    return out


def _post_cross_check_sensor(
    ha_token: str,
    value: float,
    sessions_count: int,
    window_start,
    window_end,
) -> None:
    """POST the cross-check max-abs-delta to HA. Failures are non-fatal.

    Extracted so cross_check.run() reads as a linear sequence of phases
    and so a unit test can stub `requests.post`.
    """
    import requests

    try:
        resp = requests.post(
            "http://127.0.0.1:8123/api/states/"
            "sensor.water_attribution_cross_check_delta_gal",
            headers={
                "Authorization": f"Bearer {ha_token}",
                "Content-Type": "application/json",
            },
            json={
                "state": round(value, 2),
                "attributes": {
                    "unit_of_measurement": "gal",
                    "device_class": "water",
                    "state_class": "measurement",
                    "friendly_name": "Water Attribution Cross-Check Delta",
                    "window_start": window_start.isoformat(),
                    "window_end": window_end.isoformat(),
                    "sessions_detected": sessions_count,
                    "generation": "water_attribution_v1",
                },
            },
            timeout=15,
        )
        resp.raise_for_status()
    except Exception as exc:  # noqa: BLE001 — broad on purpose
        # Type name only, never the exception body — request bodies and
        # response headers can echo Bearer tokens in some library versions.
        print(f"WARN: HA write-back failed: {type(exc).__name__}")


def run(days: int = 7) -> int:
    """Phase 2 weekly cross-check entry point.

    Loads credentials from ``$CREDENTIALS_DIRECTORY`` (systemd
    ``LoadCredential``), runs detection against VictoriaMetrics, writes
    a JSON report, posts the max-delta sensor back to HA via REST, and
    sends the weekly water-report email via sendmail.

    Failure modes intentionally degrade rather than abort:
      - HA write-back failure is logged as a type-name warning and the
        email still goes out. This keeps an HA outage from suppressing
        the report.
      - sendmail failure is non-fatal too; the JSON report on disk is
        the durable record.
      - Best-effort VM lookups for category/zone/daily numbers fall back
        to 0.0 on per-metric failure rather than crashing the entire
        report — one missing series shouldn't suppress everything else.

    No credential value ever reaches print/log output — only the type
    name of any exception, never its repr (which can include the value
    of the offending argument).
    """
    import subprocess
    from datetime import timezone
    from email.message import EmailMessage
    from pathlib import Path

    from .destinations.csv_writer import write_per_day_totals
    from .detection import DetectionConfig, detect_autofill_sessions
    from .report import WeeklyReport, render_html, render_text
    from .sources.flume_api import Credentials, FlumeAPIClient
    from .sources.ha_postgres import HAPostgresSource
    from .sources.victoriametrics import VMSource

    cfg = load_config(
        os.environ.get(
            "FLUME_AUTOFILL_CONFIG",
            "/var/lib/flume-data/zones.json",
        )
    )

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    creds = Credentials(
        client_id=(cred_dir / "client_id").read_text().strip(),
        client_secret=(cred_dir / "client_secret").read_text().strip(),
        username=(cred_dir / "username").read_text().strip(),
        password=(cred_dir / "password").read_text().strip(),
    )

    now = datetime.now(tz=timezone.utc)
    end = now.replace(hour=0, minute=0, second=0, microsecond=0)
    start = end - timedelta(days=days)

    # 1. Set up the three sources. The Flume client is constructed but
    # not actively queried in this skeleton — the cross-check uses VM as
    # the independent series so the API call doesn't burn rate-limit
    # budget on every weekly run. Future iterations may sample Flume API
    # for a small "third-witness" subset of windows.
    _flume = FlumeAPIClient(
        creds,
        token_cache_path=Path("/var/lib/flume-data/token.json"),
    )
    vm = VMSource(cfg.victoriametrics_url)
    _ha = HAPostgresSource(cfg.ha_postgres_dsn)

    vm_series = vm.query_flume_current(cfg.flume_current_sensor, start, end)

    # 2. Run detection on the VM-side series.
    det_cfg = DetectionConfig(
        gpm_min=cfg.autofill.gpm_min,
        gpm_max=cfg.autofill.gpm_max,
        window_minutes=cfg.autofill.window_minutes,
        min_minutes_in_range=cfg.autofill.min_minutes_in_range,
        enforce_mean_check=cfg.autofill.enforce_mean_check,
    )
    sessions = detect_autofill_sessions(vm_series, det_cfg)

    # 3. Roll up per-day totals (sketch — full numbers populated by VM and HA
    # in a follow-up iteration that adds per-zone totals).
    per_day_rows: list[tuple] = []
    for s in sessions:
        per_day_rows.append((s.start.date(), "pool_autofill", s.gallons))

    # The reports directory is overridable for tests; production points
    # at /var/lib/flume-data/reports (writable by the flume-data
    # user, see modules/services/flume-data.nix tmpfiles entry).
    reports_root = Path(
        os.environ.get(
            "FLUME_AUTOFILL_REPORTS_DIR",
            "/var/lib/flume-data/reports",
        )
    )
    out_dir = reports_root / end.date().isoformat()
    if per_day_rows:
        write_per_day_totals(per_day_rows, out_dir)

    # 4. Cross-check comparison: pit Phase 2's recomputed pool_autofill
    # total against HA's recorded value. The configured tolerances live
    # in env vars from the NixOS module so the operator can tune them
    # without a Python redeploy.
    pool_autofill_total = sum(s.gallons for s in sessions)
    tol = Tolerances(
        abs_gal=float(os.environ.get("FLUME_AUTOFILL_DELTA_GAL", "5.0")),
        pct=float(os.environ.get("FLUME_AUTOFILL_DELTA_PCT", "3.0")),
    )
    comparisons = _build_category_comparisons(
        vm, pool_autofill_total, end
    )
    summary = summarize(comparisons, tol)
    max_abs_delta = float(summary["max_abs_delta_gal"])
    overall_status = summary["overall_status"]

    # 5. Write JSON report (the durable on-disk record). Includes the
    # full summary so an operator can re-render the report later or
    # audit what numbers the cross-check ran against.
    json_path = reports_root / f"{end.date().isoformat()}.json"
    json_path.parent.mkdir(parents=True, exist_ok=True)
    import json as _json
    json_path.write_text(
        _json.dumps(
            {
                "sessions_detected": len(sessions),
                "window_start": start.isoformat(),
                "window_end": end.isoformat(),
                "pool_autofill_gal": round(pool_autofill_total, 2),
                "cross_check_summary": summary,
            },
            indent=2,
        )
    )

    # 6. Build the weekly report — best-effort numbers from VM. Each
    # helper returns sensible defaults on failure so one missing query
    # doesn't suppress the whole report.
    domestic_hot_present = cfg.domestic_hot_flow_sensor is not None
    category_totals, per_zone_totals = _read_weekly_categories(
        vm, end, domestic_hot_present, cfg.zones
    )
    daily_breakdown = _build_daily_breakdown(
        vm, cfg.flume_current_sensor, end
    )

    # Last week's grand total — sum of category last_week values, or fall
    # back to HA's existing `current_week` sensor at the prior boundary.
    last_week_total_gal = sum(lv for (_tv, lv) in category_totals.values())
    if last_week_total_gal == 0:
        last_week_total_gal = _query_ha_total_via_vm(
            vm,
            "sensor.flume_sensor_sierra_oaks_current_week",
            end - timedelta(days=7),
        )
    this_week_total_gal = sum(
        tv for (tv, _lv) in category_totals.values()
    )
    if this_week_total_gal == 0:
        this_week_total_gal = pool_autofill_total

    observations = _notable_observations(category_totals)
    observations.insert(
        0,
        f"Detected {len(sessions)} pool autofill session(s) in the window.",
    )
    anomaly: str | None = None
    if overall_status == "anomaly":
        anomaly_lines = [
            f"Cross-check max |Δ| = {max_abs_delta:.2f} gal "
            f"exceeded tolerances (abs={tol.abs_gal} gal, pct={tol.pct}%)."
        ]
        for cat in summary["categories"]:
            if cat["status"] == "anomaly":
                anomaly_lines.append(
                    f"  - {cat['category']}: HA={cat['ha_total_gal']:.1f} "
                    f"Phase2={cat['phase2_total_gal']:.1f} "
                    f"Δ={cat['delta_gal']:+.1f} gal "
                    f"({cat['delta_pct']:+.1f}%)"
                )
        anomaly = "\n".join(anomaly_lines)

    report = WeeklyReport(
        window_start=start.date(),
        window_end=end.date() - timedelta(days=1),
        this_week_total_gal=this_week_total_gal,
        last_week_total_gal=last_week_total_gal,
        category_totals=category_totals,
        per_zone_totals=per_zone_totals,
        daily_breakdown=daily_breakdown,
        notable_observations=observations,
        cross_check_anomaly=anomaly,
        grafana_url="https://grafana.vulcan.lan/d/water-attribution",
        energy_url="https://hass.vulcan.lan/energy",
    )

    # 7. Write back the cross-check delta sensor to HA so dashboards and
    # future NR consumers can react. Failure is non-fatal — we never
    # block the weekly email on an HA outage.
    #
    # SECURITY: the token is read from $CREDENTIALS_DIRECTORY/ha_token
    # and placed only in the Authorization header. We catch a broad
    # Exception and surface only its type name; we never log `repr(e)`
    # because some libraries embed request headers in exception messages.
    ha_token_path = cred_dir / "ha_token"
    ha_token = ha_token_path.read_text().strip()
    try:
        _post_cross_check_sensor(
            ha_token=ha_token,
            value=max_abs_delta,
            sessions_count=len(sessions),
            window_start=start.date(),
            window_end=end.date() - timedelta(days=1),
        )
    finally:
        # Best-effort scrub the local reference. Doesn't help against a
        # process-memory reader but reinforces intent.
        ha_token = None  # type: ignore[assignment]

    # 8. Email.
    email_to = os.environ.get(
        "FLUME_AUTOFILL_EMAIL_TO", "johnw@newartisans.com"
    )
    from_addr = os.environ.get(
        "FLUME_AUTOFILL_FROM", "vulcan@vulcan.newartisans.com"
    )
    msg = EmailMessage()
    msg["Subject"] = (
        f"[vulcan] Weekly water report — "
        f"{start.date()} to {(end.date() - timedelta(days=1))}"
    )
    msg["From"] = from_addr
    msg["To"] = email_to
    msg.set_content(render_text(report))
    msg.add_alternative(render_html(report), subtype="html")

    # sendmail exit code is surfaced so a queue-permission or postfix
    # outage gets noticed in journal output (the JSON report on disk is
    # still the durable record either way).
    result = subprocess.run(
        ["sendmail", "-t", "-i"],
        input=msg.as_string(),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        print(f"WARN: sendmail exited {result.returncode}")

    return 0
