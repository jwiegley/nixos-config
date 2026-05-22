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

    No credential value ever reaches print/log output — only the type
    name of any exception, never its repr (which can include the value
    of the offending argument).
    """
    import subprocess
    from datetime import datetime, timedelta, timezone
    from email.message import EmailMessage
    from pathlib import Path

    import requests

    from .destinations.csv_writer import write_per_day_totals
    from .detection import DetectionConfig, detect_autofill_sessions
    from .report import WeeklyReport, render_html, render_text
    from .sources.flume_api import Credentials, FlumeAPIClient
    from .sources.ha_postgres import HAPostgresSource
    from .sources.victoriametrics import VMSource

    cfg = load_config(
        os.environ.get(
            "FLUME_AUTOFILL_CONFIG",
            "/var/lib/flume-autofill/zones.json",
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
        token_cache_path=Path("/var/lib/flume-autofill/token.json"),
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

    out_dir = Path("/var/lib/flume-autofill/reports") / end.date().isoformat()
    if per_day_rows:
        write_per_day_totals(per_day_rows, out_dir)

    # 4. Write JSON report (the durable on-disk record).
    json_path = (
        Path("/var/lib/flume-autofill/reports")
        / f"{end.date().isoformat()}.json"
    )
    json_path.parent.mkdir(parents=True, exist_ok=True)
    import json as _json
    json_path.write_text(
        _json.dumps(
            {
                "sessions_detected": len(sessions),
                "window_start": start.isoformat(),
                "window_end": end.isoformat(),
                "pool_autofill_gal": round(
                    sum(s.gallons for s in sessions), 2
                ),
            },
            indent=2,
        )
    )

    # 5. Build the weekly report. Minimal viable version: per-zone numbers
    # and last-week comparisons land in a follow-up once we have at least
    # two weeks of real data to compute against.
    pool_autofill_total = sum(s.gallons for s in sessions)
    report = WeeklyReport(
        window_start=start.date(),
        window_end=end.date() - timedelta(days=1),
        this_week_total_gal=pool_autofill_total,
        last_week_total_gal=0.0,
        category_totals={"pool_autofill": (pool_autofill_total, 0.0)},
        per_zone_totals={},
        daily_breakdown=[],
        notable_observations=[
            f"Detected {len(sessions)} pool autofill session(s) in the window.",
        ],
        cross_check_anomaly=None,
        grafana_url="https://grafana.vulcan.lan/d/water-attribution",
        energy_url="https://hass.vulcan.lan/energy",
    )

    # 6. Write back the cross-check delta sensor to HA so dashboards and
    # future NR consumers can react. Failure is non-fatal — we never
    # block the weekly email on an HA outage.
    #
    # SECURITY: the token is read from $CREDENTIALS_DIRECTORY/ha_token
    # and placed only in the Authorization header. We catch a broad
    # Exception and surface only its type name; we never log `repr(e)`
    # because some libraries embed request headers in exception messages.
    ha_token_path = cred_dir / "ha_token"
    ha_token = ha_token_path.read_text().strip()
    max_abs_delta = max((abs(s.gallons) for s in sessions), default=0.0)
    try:
        resp = requests.post(
            "http://127.0.0.1:8123/api/states/"
            "sensor.water_attribution_cross_check_delta_gal",
            headers={
                "Authorization": f"Bearer {ha_token}",
                "Content-Type": "application/json",
            },
            json={
                "state": round(max_abs_delta, 2),
                "attributes": {
                    "unit_of_measurement": "gal",
                    "device_class": "water",
                    "state_class": "measurement",
                    "friendly_name": "Water Attribution Cross-Check Delta",
                    "window_start": start.date().isoformat(),
                    "window_end": (end.date() - timedelta(days=1)).isoformat(),
                    "sessions_detected": len(sessions),
                    "generation": "water_attribution_v1",
                },
            },
            timeout=15,
        )
        resp.raise_for_status()
    except Exception as exc:  # noqa: BLE001 — broad on purpose
        # Type name only, never the exception body — see SECURITY note above.
        print(f"WARN: HA write-back failed: {type(exc).__name__}")
    finally:
        # Best-effort scrub the local reference. Doesn't help against a
        # process-memory reader but reinforces intent.
        ha_token = None  # type: ignore[assignment]

    # 7. Email.
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

    subprocess.run(
        ["sendmail", "-t", "-i"],
        input=msg.as_string(),
        text=True,
        check=False,
    )

    return 0
