"""Phase 3 multi-source historical backfill.

End-to-end driver for the backfill subcommand. Composes the source
clients (VM, Flume API) with the writers (CSV, VM line-protocol, HA LTS)
and the autofill-detection core to produce per-day cumulative totals
across an arbitrary historical window.

High-level shape::

    backfill --from D1 --to D2 [--destinations csv,vm,lts] [--dry-run]
        1. discover_coverage() probes the earliest data available
        2. select_source_for_window() picks VM vs Flume API per window
        3. _drive_backfill() chunks the window by day, runs detection,
           and forwards the per-day rollups to the enabled destinations
        4. _promote(through) splices the flume_data: namespace into
           the live sensor.water_*_total LTS namespace
        5. _unpromote(through) reverses _promote via recorder/clear_statistics

The systemd template service passes the instance suffix in
``FLUME_AUTOFILL_INSTANCE`` (e.g. ``2024-05``); :func:`parse_systemd_instance`
expands it into a (start, end) date pair so a single template covers all
four ``YYYY[-MM[-DD[:YYYY-MM-DD]]]`` shapes.

v1 scope: only the ``pool_autofill`` category is computed from the
VM-stored Flume signal. Per-zone irrigation roll-up is symmetric to the
Phase 1 gated template but lands in a follow-up iteration — see
``docs/WATER_ATTRIBUTION.md``.
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Literal


@dataclass(frozen=True)
class SourceCoverage:
    """Earliest data date available from each historical source."""

    vm_start: date | None
    flume_start: date | None


SourceName = Literal["vm", "flume_api", "ha_postgres", "ha_lts"]


def parse_systemd_instance(instance: str) -> tuple[date, date]:
    """Expand a systemd instance suffix into an inclusive (start, end) range.

    Accepted shapes:
        ``YYYY``                  → Jan 1 .. Dec 31
        ``YYYY-MM``               → 1st .. last day of month
        ``YYYY-MM-DD``            → that single day (start == end)
        ``YYYY-MM-DD:YYYY-MM-DD`` → explicit range

    Raises :class:`ValueError` for any other shape.
    """
    if ":" in instance:
        s, e = instance.split(":", 1)
        return date.fromisoformat(s), date.fromisoformat(e)
    parts = instance.split("-")
    if len(parts) == 1:
        y = int(parts[0])
        return date(y, 1, 1), date(y, 12, 31)
    if len(parts) == 2:
        y, m = int(parts[0]), int(parts[1])
        if m == 12:
            last = date(y + 1, 1, 1) - timedelta(days=1)
        else:
            last = date(y, m + 1, 1) - timedelta(days=1)
        return date(y, m, 1), last
    if len(parts) == 3:
        d = date.fromisoformat(instance)
        return d, d
    raise ValueError(f"unrecognised instance: {instance}")


def select_source_for_window(
    coverage: SourceCoverage,
    window_start: date,
    window_end: date,
) -> SourceName:
    """Pick the highest-fidelity source that fully covers the window.

    VM is preferred when ``vm_start <= window_start`` (per-minute series,
    cheapest read). Falls back to the Flume API for pre-VM windows.

    Raises:
        ValueError: when no source covers ``window_start``.
    """
    if coverage.vm_start and coverage.vm_start <= window_start:
        return "vm"
    if coverage.flume_start and coverage.flume_start <= window_start:
        return "flume_api"
    raise ValueError("No source covers the requested window")


def discover_coverage() -> SourceCoverage:
    """Probe each source for its earliest available data point.

    VM lookup uses a 10-year window at 30-day step against the configured
    Flume current sensor — VM returns the first non-empty bucket, so this
    is cheap even on a fresh database. Failures are non-fatal: a missing
    source yields ``None`` and ``select_source_for_window`` will degrade
    gracefully (or raise if no source remains).

    The Flume API path is sketched but yields ``None`` in v1: a complete
    implementation needs device/user-id discovery via ``/users/me``, which
    the spec defers to the live deployment.
    """
    from .config import load_config

    cfg = load_config(
        os.environ.get(
            "FLUME_AUTOFILL_CONFIG", "/var/lib/flume-data/zones.json"
        )
    )

    vm_start: date | None = None
    flume_start: date | None = None

    # VM: cheap range query at coarse step finds the first stored sample.
    try:
        from datetime import datetime, timezone, timedelta as td

        from .sources.victoriametrics import VMSource

        vm = VMSource(cfg.victoriametrics_url)
        end = datetime.now(tz=timezone.utc)
        start = end - td(days=3650)
        vm_id = VMSource.vm_entity_id(cfg.flume_current_sensor)
        series = vm.query_range(
            metric=(
                f'last_over_time({{entity_id="{vm_id}"}}'
                "[1d])"
            ),
            start=start,
            end=end,
            step="30d",
        )
        # series[0] is the earliest bucket VM has data for, regardless of
        # value — a 0 reading is still a valid sample (water just wasn't
        # flowing). VM returns empty results outside its stored range, so
        # series[0] is the actual earliest-data boundary.
        if series:
            vm_start = series[0][0].date()
    except Exception as e:
        # Type name only — the exception body can include URL/credential
        # fragments from `requests` (e.g. NewConnectionError repr) and from
        # OAuth-grant failures. Mirrors cross_check.py:251.
        print(f"WARN: VM discovery failed: {type(e).__name__}")

    # Flume API: live deployment fills this in once device/user ids are
    # wired. Token plumbing exists; the discovery query does not.
    try:
        cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
        if cred_dir:
            from pathlib import Path

            from .sources.flume_api import Credentials, FlumeAPIClient

            cd = Path(cred_dir)
            creds = Credentials(
                client_id=(cd / "client_id").read_text().strip(),
                client_secret=(cd / "client_secret").read_text().strip(),
                username=(cd / "username").read_text().strip(),
                password=(cd / "password").read_text().strip(),
            )
            FlumeAPIClient(
                creds,
                token_cache_path=Path("/var/lib/flume-data/token.json"),
            )
            # TODO: needs /users/me + device-id discovery before the API
            # path goes live. Tracked in docs/WATER_ATTRIBUTION.md §v2.
            flume_start = None
    except Exception as e:
        # Type name only — see VM-discovery comment above.
        print(f"WARN: Flume API discovery failed: {type(e).__name__}")

    return SourceCoverage(vm_start=vm_start, flume_start=flume_start)


def run(args: argparse.Namespace) -> int:
    """Backfill entry point dispatched from ``__main__``."""
    if args.discover:
        cov = discover_coverage()
        print("Earliest data available:")
        print(f"  VictoriaMetrics    {cov.vm_start}")
        print(f"  Flume API          {cov.flume_start}")
        return 0

    if args.promote:
        if not args.through_date:
            print(
                "ERROR: --promote requires --through YYYY-MM-DD",
                file=sys.stderr,
            )
            return 2
        return _promote(args.through_date)
    if args.unpromote:
        if not args.through_date:
            print(
                "ERROR: --unpromote requires --through YYYY-MM-DD",
                file=sys.stderr,
            )
            return 2
        return _unpromote(args.through_date)

    if not args.from_date or not args.to_date:
        instance = os.environ.get("FLUME_AUTOFILL_INSTANCE")
        if instance:
            ws, we = parse_systemd_instance(instance)
        else:
            print(
                "ERROR: provide --from and --to or run via systemd template",
                file=sys.stderr,
            )
            return 2
    else:
        ws = date.fromisoformat(args.from_date)
        we = date.fromisoformat(args.to_date)

    return _drive_backfill(ws, we, args)


def _drive_backfill(
    window_start: date,
    window_end: date,
    args: argparse.Namespace,
) -> int:
    """Run the per-day detection loop and forward results to destinations.

    Per-day rollups are accumulated in memory across the window so the
    LTS writer can submit one ``import_statistics`` call per category
    (rather than one per day). For multi-year windows the row count is
    still modest (≈4000 rows per category over 10 years).
    """
    from datetime import datetime, time, timezone, timedelta
    from pathlib import Path

    from .config import load_config
    from .destinations.csv_writer import write_per_day_totals
    from .destinations.ha_lts import StatisticsPoint, import_statistics
    from .destinations.vm_writer import DataPoint, write_points
    from .detection import DetectionConfig, detect_autofill_sessions
    from .sources.victoriametrics import VMSource

    cfg = load_config(
        os.environ.get(
            "FLUME_AUTOFILL_CONFIG", "/var/lib/flume-data/zones.json"
        )
    )
    det_cfg = DetectionConfig(
        gpm_min=cfg.autofill.gpm_min,
        gpm_max=cfg.autofill.gpm_max,
        window_minutes=cfg.autofill.window_minutes,
        min_minutes_in_range=cfg.autofill.min_minutes_in_range,
        enforce_mean_check=cfg.autofill.enforce_mean_check,
    )
    cov = discover_coverage()
    source = select_source_for_window(cov, window_start, window_end)

    dests = set((args.destinations or "csv,vm,lts").split(","))
    print(
        f"Backfill {window_start} → {window_end} using source={source} "
        f"destinations={sorted(dests)} dry_run={args.dry_run}"
    )

    # 1. Pull per-minute GPM for the entire window in 1-day chunks
    vm = VMSource(cfg.victoriametrics_url)
    per_day_rows: list[tuple[date, str, float]] = []
    current = window_start
    while current <= window_end:
        day_start = datetime.combine(current, time.min, tzinfo=timezone.utc)
        day_end = day_start + timedelta(days=1)
        if source == "vm":
            series = vm.query_flume_current(
                cfg.flume_current_sensor, day_start, day_end
            )
        else:
            # Flume API path — full implementation requires live
            # device_id/user_id discovery. The plan ships VM as primary.
            print(f"  {current}: Flume API path not yet active; skipping")
            current += timedelta(days=1)
            continue

        sessions = detect_autofill_sessions(series, det_cfg)
        autofill_total = sum(s.gallons for s in sessions)
        per_day_rows.append((current, "pool_autofill", autofill_total))

        # Per-zone irrigation totals are symmetric to the Phase 1 gated
        # template (open valve × instantaneous GPM minus autofill) but
        # require the HA-Postgres valve-event source and a second
        # detection pass. v1 records autofill only; v2 lands per-zone.
        print(
            f"  {current}: {len(sessions)} session(s), "
            f"{autofill_total:.1f} gal autofill"
        )
        current += timedelta(days=1)

    out_dir = Path("/var/lib/flume-data/backfill")

    # 2. CSV destination
    if "csv" in dests and per_day_rows:
        if not args.dry_run:
            write_per_day_totals(per_day_rows, out_dir)
        print(f"  CSV: wrote {len(per_day_rows)} rows to {out_dir}")

    # 3. VM destination — cumulative monotonic totals per category.
    if "vm" in dests and per_day_rows and not args.dry_run:
        running: dict[str, float] = {}
        points: list[DataPoint] = []
        for d, cat, gal in per_day_rows:
            running[cat] = running.get(cat, 0.0) + gal
            points.append(
                DataPoint(
                    measurement="gal",
                    tags={
                        "entity_id": (
                            f"flume_data_backfill:water_{cat}_total"
                        ),
                        "water_category": cat,
                        "generation": "water_attribution_v1",
                    },
                    fields={"value": running[cat]},
                    timestamp=datetime.combine(
                        d, time(23, 59, 59), tzinfo=timezone.utc
                    ),
                )
            )
        write_points(points, cfg.victoriametrics_url)
        print(f"  VM: wrote {len(points)} line-protocol points")

    # 4. LTS destination — hourly cumulative points in the
    # flume_data: external-statistic namespace.
    if "lts" in dests and per_day_rows and not args.dry_run:
        cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
        ha_token = (cred_dir / "ha_token").read_text().strip()
        ws_url = "ws://127.0.0.1:8123/api/websocket"

        running_lts: dict[str, float] = {}
        by_category: dict[str, list[StatisticsPoint]] = {}
        for d, cat, gal in per_day_rows:
            running_lts[cat] = running_lts.get(cat, 0.0) + gal
            sp = StatisticsPoint(
                start=datetime.combine(d, time.min, tzinfo=timezone.utc),
                sum_=running_lts[cat],
                state=running_lts[cat],
            )
            by_category.setdefault(cat, []).append(sp)

        for cat, points_lts in by_category.items():
            stat_id = f"flume_data:water_{cat}_total"
            import_statistics(
                ws_url=ws_url,
                access_token=ha_token,
                statistic_id=stat_id,
                name=f"Water {cat} Total (backfilled)",
                unit_of_measurement="gal",
                points=points_lts,
            )
            print(f"  LTS: imported {len(points_lts)} points into {stat_id}")

    return 0


def _promote(through: str) -> int:
    """Splice ``flume_data:*`` LTS into live ``sensor.water_*_total``.

    Fetches the backfilled namespace through ``through`` via
    ``recorder/statistics_during_period`` and re-imports each hour into
    the live ``sensor.water_*_total`` namespace. ``recorder/import_statistics``
    is idempotent on ``(statistic_id, hour)``, so re-running this command
    is a no-op against unchanged data.
    """
    import json
    from datetime import datetime, timezone
    from pathlib import Path

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    ha_token = (cred_dir / "ha_token").read_text().strip()
    through_date = datetime.fromisoformat(through).replace(tzinfo=timezone.utc)

    from .destinations.ha_lts import (
        StatisticsPoint,
        _ws_connect,
        build_import_payload,
    )

    for cat in ["pool_autofill", "irrigation_total", "domestic_hot", "other"]:
        backfill_id = f"flume_data:water_{cat}_total"
        live_id = f"sensor.water_{cat}_total"

        ws = _ws_connect("ws://127.0.0.1:8123/api/websocket", ha_token)
        try:
            ws.send(
                json.dumps(
                    {
                        "id": 1,
                        "type": "recorder/statistics_during_period",
                        "start_time": "2020-01-01T00:00:00+00:00",
                        "end_time": through_date.isoformat(),
                        "statistic_ids": [backfill_id],
                        "period": "hour",
                    }
                )
            )
            resp = json.loads(ws.recv())
            stats = resp.get("result", {}).get(backfill_id, [])
            if not stats:
                print(f"  {cat}: nothing to promote")
                continue

            points = [
                StatisticsPoint(
                    start=datetime.fromisoformat(
                        s["start"].replace("Z", "+00:00")
                    ),
                    sum_=s["sum"],
                    state=s["sum"],
                )
                for s in stats
            ]
            payload = build_import_payload(
                statistic_id=live_id,
                name=f"Water {cat} Total (promoted)",
                unit_of_measurement="gal",
                points=points,
            )
            ws.send(json.dumps({**payload, "id": 2}))
            ack = json.loads(ws.recv())
            print(
                f"  {cat}: promoted {len(points)} hourly points into "
                f"{live_id} (ack: {ack.get('success', False)})"
            )
        finally:
            ws.close()
    return 0


def _unpromote(through: str) -> int:
    """Reverse :func:`_promote` via ``recorder/clear_statistics``.

    The ``flume_data:`` backfill namespace is left intact as an
    audit trail — only the live ``sensor.*`` namespace is cleared. Use
    ``_promote`` again to restore.

    NOTE: ``--through`` is accepted for CLI symmetry with ``--promote``
    but is **ignored** by this operation. HA's ``recorder/clear_statistics``
    is namespace-wide, not range-filtered, so any value passed for
    ``through`` cannot bound what's cleared. The print on entry makes
    this explicit so the operator isn't surprised.
    """
    import json
    from datetime import datetime, timezone
    from pathlib import Path

    print(
        "INFO: --unpromote ignores --through; HA's "
        "recorder/clear_statistics wipes the entire namespace"
    )

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    ha_token = (cred_dir / "ha_token").read_text().strip()
    # `through` is accepted for symmetry with --promote and parsed only
    # to validate that it's well-formed (early failure beats a silent
    # success on a misspelled date). The parsed value is not used.
    _through_date = datetime.fromisoformat(through).replace(tzinfo=timezone.utc)

    from .destinations.ha_lts import _ws_connect

    for cat in ["pool_autofill", "irrigation_total", "domestic_hot", "other"]:
        live_id = f"sensor.water_{cat}_total"
        ws = _ws_connect("ws://127.0.0.1:8123/api/websocket", ha_token)
        try:
            ws.send(
                json.dumps(
                    {
                        "id": 1,
                        "type": "recorder/clear_statistics",
                        "statistic_ids": [live_id],
                    }
                )
            )
            ack = json.loads(ws.recv())
            print(
                f"  {cat}: cleared live LTS for {live_id} "
                f"(ack: {ack.get('success', False)})"
            )
        finally:
            ws.close()
    return 0
