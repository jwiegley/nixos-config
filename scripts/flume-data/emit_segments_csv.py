#!/usr/bin/env python3
"""Pull all available Flume history and emit a per-segment classified CSV.

For each continuous-usage segment Flume detects (consecutive minutes with
GPM > threshold), output one row tagged with whether it matches the pool
autofill detector rule (10+ min in [3, 5] GPM with 1-min blip tolerance
and rolling-mean check).

The script authenticates against Flume's Personal API, derives `user_id`
from the JWT's `user_id` claim, lists devices to find `device_id`, queries
per-minute samples in 24-hour chunks (the largest window the API accepts
for the MIN bucket, self-throttled to stay under the 120-req/hr rate
budget), re-implements the autofill rule locally (see the constants below
— this script does NOT import `flume_data.detection`), and writes:

    /var/lib/flume-data/backfill/flume-segments.csv
    /var/lib/flume-data/backfill/flume-day-totals.csv

Both end up root-owned (the script runs as root) with group `users` and
mode 0640. Note the enclosing /var/lib/flume-data/backfill is
0750 flume-data:flume-data, so reading them still needs sudo.

There is no systemd unit for this script — run it as root, which can read
the SOPS-deployed credentials directly (or point CREDENTIALS_DIRECTORY at
a LoadCredential dir):

    sudo python3 emit_segments_csv.py
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import sys
import time
from collections import defaultdict
from datetime import date, datetime, time as dtime, timedelta, timezone
from pathlib import Path
from typing import Iterator

import requests

# Per-day cache: paths, formats, and the "has this window elapsed?" clock.
# Everything about cache completeness lives there, not here.
from flume_data import day_cache


# ───────────────────────────────── Constants ─────────────────────────────────

FLUME_API_BASE = "https://api.flumewater.com"
FLUME_RATE_LIMIT_PER_HOUR = 120

# Autofill detection. These mirror the ORIGINAL Phase 1 HA rule, i.e. the
# old pool-fill valve's long 30-200 min fills at 3-5 gpm. The pool auto-fill
# valve was replaced 2026-05-26 and the live HA rule moved to
# [1.3, 1.9] gpm / window 5 / min-in-range 4 (hosts/vulcan/default.nix
# `services.home-assistant-water-attribution.autofill`), so as of 2026-07-27
# these constants NO LONGER match the live rule. They are kept as-is because
# this script is a historical EDA tool over the pre-swap archive; bump them
# if you re-run it over post-2026-05-26 data.
GPM_MIN = 3.0
GPM_MAX = 5.0
WINDOW_MINUTES = 10
MIN_MINUTES_IN_RANGE = 9

# Segment detection: consecutive minutes with GPM > threshold form a segment.
SEGMENT_GPM_THRESHOLD = 0.05
# A single below-threshold minute inside an otherwise-active run is absorbed.
SEGMENT_MAX_INNER_GAP_MIN = 1

# Output
OUTPUT_DIR = Path("/var/lib/flume-data/backfill")
SEGMENTS_CSV = OUTPUT_DIR / "flume-segments.csv"
DAY_TOTALS_CSV = OUTPUT_DIR / "flume-day-totals.csv"

# Single source of truth for the device-local frame lives in day_cache —
# cache keys are minted in it, so completeness must be judged in it.
LOCAL_TZ_NAME = day_cache.LOCAL_TZ_NAME

# ────────────────────────────────── Auth ─────────────────────────────────────


def load_credentials() -> dict[str, str]:
    """Read Flume API credentials from systemd's LoadCredential directory."""
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not cred_dir:
        # Fall back to the live SOPS deployment when invoked outside systemd.
        # Caller MUST be root (root is in the SOPS owner-or-readable set).
        cred_dir = "/run/secrets/flume"
    base = Path(cred_dir)
    out = {}
    for key in ("client_id", "client_secret", "username", "password"):
        path = base / key
        if not path.exists():
            sys.exit(f"FATAL: credential {key} not at {path}")
        out[key] = path.read_text().strip()
    return out


def mint_token(creds: dict[str, str]) -> tuple[str, int]:
    """OAuth password grant → (access_token, user_id)."""
    resp = requests.post(
        f"{FLUME_API_BASE}/oauth/token",
        json={
            "grant_type": "password",
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
            "username": creds["username"],
            "password": creds["password"],
        },
        timeout=30,
    )
    if resp.status_code != 200:
        # Don't echo response body — it can mirror the request including creds.
        sys.exit(f"FATAL: oauth/token returned {resp.status_code}")
    token = resp.json()["data"][0]["access_token"]

    # JWT body is base64url-encoded JSON; read the `user_id` claim from it.
    _hdr, body, _sig = token.split(".")
    pad = "=" * (-len(body) % 4)
    body_json = json.loads(base64.urlsafe_b64decode(body + pad))
    user_id = body_json["user_id"]
    return token, int(user_id)


def list_devices(token: str, user_id: int) -> list[dict]:
    """GET /users/{user_id}/devices — returns the device list."""
    resp = requests.get(
        f"{FLUME_API_BASE}/users/{user_id}/devices",
        headers={"Authorization": f"Bearer {token}"},
        params={"user": "false", "location": "false"},
        timeout=30,
    )
    if resp.status_code != 200:
        sys.exit(f"FATAL: /devices returned {resp.status_code}")
    devices = resp.json().get("data", [])
    if not devices:
        sys.exit("FATAL: no Flume devices on this account")
    return devices


# ────────────────────────────── Rate-limited fetch ───────────────────────────


class RateLimiter:
    """Sleeps as needed to stay under FLUME_RATE_LIMIT_PER_HOUR."""

    def __init__(self, limit_per_hour: int = FLUME_RATE_LIMIT_PER_HOUR):
        # Conservative: 90% of the budget, evenly spaced.
        self.min_interval_s = 3600.0 / (limit_per_hour * 0.9)
        self._last_call = 0.0

    def wait(self) -> None:
        elapsed = time.monotonic() - self._last_call
        if elapsed < self.min_interval_s:
            time.sleep(self.min_interval_s - elapsed)
        self._last_call = time.monotonic()


def query_data(
    token: str,
    user_id: int,
    device_id: str,
    since_local: datetime,
    until_local: datetime,
    bucket: str,
    rate: RateLimiter,
) -> list[tuple[datetime, float]]:
    """POST /users/{u}/devices/{d}/query in device-local TZ.

    Flume's API expects naive timestamps in device-local time (the timezone
    reported on the device record), NOT UTC. Return values come back the
    same way.

    Returned tuples are (timestamp_local_naive, gallons_per_bucket).
    """
    rate.wait()
    body = {
        "queries": [
            {
                "request_id": "main",
                "bucket": bucket,
                "since_datetime": since_local.strftime("%Y-%m-%d %H:%M:%S"),
                "until_datetime": until_local.strftime("%Y-%m-%d %H:%M:%S"),
                "units": "GALLONS",
                "sort_direction": "ASC",
            }
        ]
    }
    url = f"{FLUME_API_BASE}/users/{user_id}/devices/{device_id}/query"
    for attempt in range(5):
        resp = requests.post(
            url,
            json=body,
            headers={"Authorization": f"Bearer {token}"},
            timeout=90,
        )
        if resp.status_code == 200:
            break
        if resp.status_code == 429:
            wait = float(resp.headers.get("Retry-After", "60")) + 2.0
            print(f"  429 rate-limit; sleeping {wait:.0f}s")
            time.sleep(wait)
            continue
        # The API's 4xx body has a structured `detail` field that says
        # what's wrong (e.g., "bucket MIN limited to N-day range"). Echo
        # ONLY that field — not the full body, which can include request
        # echo. Defensive: also strip anything that looks like a JWT or
        # credential pattern from the printed detail.
        try:
            body_detail = resp.json().get("detail") or resp.json().get("message", "")
        except Exception:
            body_detail = "(unparseable body)"
        import re
        body_detail = re.sub(r"eyJ[A-Za-z0-9._=-]+", "[REDACTED_JWT]", str(body_detail))
        body_detail = re.sub(
            r"(password|client_secret|username|access_token)[^,\s\"]*",
            r"\1=[REDACTED]",
            body_detail,
            flags=re.I,
        )
        sys.exit(
            f"FATAL: query returned {resp.status_code} (attempt {attempt + 1}): {body_detail[:200]}"
        )
    else:
        sys.exit("FATAL: query exhausted retries")

    pts = resp.json()["data"][0].get("main", [])
    out: list[tuple[datetime, float]] = []
    for p in pts:
        # Flume returns datetimes in device-local time. Parse as naive — we
        # treat all per-minute samples as local-TZ-anchored throughout.
        ts = datetime.strptime(p["datetime"], "%Y-%m-%d %H:%M:%S")
        out.append((ts, float(p["value"])))
    return out


def discover_earliest_data(
    token: str, user_id: int, device_id: str, rate: RateLimiter
) -> datetime:
    """Probe MON bucket in 1-year chunks (empirical max window) backwards
    until we find an empty year.

    Flume rejects MON queries spanning > 1 year, so we walk a year at a
    time. The first chunk that returns no data (or whose first sample is
    several months from the chunk start) marks the device-install boundary.
    """
    now_local = datetime.now()
    earliest_found: datetime | None = None
    for years_back in range(0, 6):
        chunk_end = (
            now_local if years_back == 0
            else datetime(now_local.year - years_back + 1, 1, 1)
        )
        chunk_start = datetime(now_local.year - years_back, 1, 1)
        mon_data = query_data(
            token, user_id, device_id,
            chunk_start, chunk_end, bucket="MON", rate=rate,
        )
        if not mon_data:
            print(f"  {chunk_start.year}: no data (boundary)")
            break
        nonzero = [(ts, v) for ts, v in mon_data if v > 0]
        if not nonzero:
            print(f"  {chunk_start.year}: 0 gal across {len(mon_data)} months (boundary)")
            break
        first_ts = nonzero[0][0]
        if earliest_found is None or first_ts < earliest_found:
            earliest_found = first_ts
        total = sum(v for _, v in mon_data)
        print(f"  {chunk_start.year}: first non-zero month {first_ts.strftime('%Y-%m')}  ({total:.0f} gal/yr)")
        # If first non-zero month is NOT January, we found the boundary
        # within this year and don't need to look further back.
        if first_ts.month > 1:
            break
    if earliest_found is None:
        print("  no MON data found — defaulting to 1 year back")
        return now_local - timedelta(days=365)
    return datetime(earliest_found.year, earliest_found.month, 1)


# Cache location and format now live in flume_data.day_cache — see that
# module's header for why "the file exists" is not "the day is complete".


def chunked_pull(
    token: str,
    user_id: int,
    device_id: str,
    earliest_local: datetime,
    latest_local: datetime,
    rate: RateLimiter,
    chunk_hours: int = 24,
    *,
    reuse_cache: bool = True,
    now: datetime | None = None,
) -> Iterator[tuple[datetime, float]]:
    """Yield (ts_local_naive, gpm) tuples in chunk_hours windows.

    Flume's MIN bucket is restricted to ≤ 24 hours per call.

    Cache policy — the rationale is in flume_data/day_cache.py:

    * A day is served from cache only once it has fully elapsed in
      device-local time. An in-progress day is ALWAYS re-fetched, because
      Flume zero-fills minutes that have not happened yet: a response for
      "today" taken at 00:30 carries 1410 fake zeros and, left in the
      cache, freezes the day there forever.
    * An in-progress window is yielded but never written. Only an elapsed
      window earns a cache file.
    * `reuse_cache=False` bypasses the read side entirely, for callers that
      have already decided these days need re-fetching (flume_db_sync does
      this for every day whose cache is not recorded-complete).
    * `now` is the test seam for the local clock.
    """
    day_cache.CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cursor = earliest_local
    while cursor < latest_local:
        window_end = min(cursor + timedelta(hours=chunk_hours), latest_local)
        day = cursor.date()

        if reuse_cache and day_cache.cache_day_is_reusable(day, now=now):
            entry = day_cache.read_cache_day(day)
            yield from entry.points
            print(f"  cache hit  {day} ({len(entry.points)} pts)")
            cursor = window_end
            continue

        batch = query_data(
            token, user_id, device_id, cursor, window_end, "MIN", rate
        )
        # Two guards, deliberately: `window_is_final` covers a sub-day
        # chunk_hours (the window may end before the day does), and
        # `write_cache_day` re-checks the day itself, which is the frame
        # the cache key is minted in.
        cached = day_cache.window_is_final(
            window_end, now=now
        ) and day_cache.write_cache_day(day, batch, now=now)
        if cached:
            print(f"  fetched    {day} ({len(batch)} pts, cached)")
        else:
            print(f"  fetched    {day} ({len(batch)} pts; window still open "
                  f"— deliberately not cached)")
        yield from batch
        cursor = window_end


# ─────────────────────────── Detection + segmentation ────────────────────────


def detect_segments(
    samples: list[tuple[datetime, float]],
) -> list[tuple[int, int]]:
    """Return list of (start_idx, end_idx) index pairs for continuous usage.

    A segment is a contiguous run where GPM > SEGMENT_GPM_THRESHOLD, with
    single below-threshold minutes absorbed.
    """
    n = len(samples)
    if not n:
        return []
    active = [g > SEGMENT_GPM_THRESHOLD for _, g in samples]
    # Absorb single-minute gaps
    for i in range(1, n - 1):
        if not active[i] and active[i - 1] and active[i + 1]:
            active[i] = True
    segments: list[tuple[int, int]] = []
    i = 0
    while i < n:
        if active[i]:
            start = i
            while i < n and active[i]:
                i += 1
            segments.append((start, i - 1))
        else:
            i += 1
    return segments


def is_pool_autofill_segment(
    samples: list[tuple[datetime, float]], start_idx: int, end_idx: int
) -> bool:
    """Apply the canonical autofill rule across a single segment.

    Mirror of the ORIGINAL Phase 1 HA / Phase 0 Python detector (see the
    constants block above: the live HA rule has since been re-tuned for the
    2026-05-26 valve swap and no longer uses these thresholds):
      - Duration ≥ WINDOW_MINUTES
      - ≥ MIN_MINUTES_IN_RANGE of any rolling window in [GPM_MIN, GPM_MAX]
      - Rolling 10-min mean in [GPM_MIN, GPM_MAX]
    """
    duration = end_idx - start_idx + 1
    if duration < WINDOW_MINUTES:
        return False
    # Check every WINDOW_MINUTES-long sliding window inside the segment.
    in_range = [GPM_MIN <= g <= GPM_MAX for _, g in samples[start_idx : end_idx + 1]]
    gpms = [g for _, g in samples[start_idx : end_idx + 1]]
    for i in range(0, len(in_range) - WINDOW_MINUTES + 1):
        window_in_range = sum(in_range[i : i + WINDOW_MINUTES])
        if window_in_range < MIN_MINUTES_IN_RANGE:
            continue
        window_mean = sum(gpms[i : i + WINDOW_MINUTES]) / WINDOW_MINUTES
        if GPM_MIN <= window_mean <= GPM_MAX:
            return True
    return False


def segment_to_local(ts_local_naive: datetime) -> datetime:
    """Identity — Flume timestamps are already in device-local TZ.

    Kept as a named helper so future changes (e.g., if we migrate to UTC
    storage) have a single conversion point.
    """
    return ts_local_naive


# ─────────────────────────────── CSV writing ─────────────────────────────────


def write_segments_csv(
    samples: list[tuple[datetime, float]],
    segments: list[tuple[int, int]],
    path: Path,
) -> int:
    """One row per segment, with autofill classification + session ids."""
    path.parent.mkdir(parents=True, exist_ok=True)
    autofill_id = 0
    written = 0
    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(
            [
                "date",
                "start_time_local",
                "end_time_local",
                "duration_min",
                "gallons",
                "mean_gpm",
                "peak_gpm",
                "category",
                "autofill_session_id",
            ]
        )
        for start_i, end_i in segments:
            span = samples[start_i : end_i + 1]
            gpms = [g for _, g in span]
            gallons = round(sum(gpms), 3)  # 1 min/sample × gpm = gal
            mean_gpm = round(gallons / len(span), 3)
            peak_gpm = round(max(gpms), 3)
            duration = len(span)
            start_local = segment_to_local(span[0][0])
            end_local = segment_to_local(span[-1][0])
            is_autofill = is_pool_autofill_segment(samples, start_i, end_i)
            session_id = ""
            category = "other"
            if is_autofill:
                autofill_id += 1
                session_id = str(autofill_id)
                category = "pool_autofill"
            w.writerow(
                [
                    start_local.date().isoformat(),
                    start_local.time().strftime("%H:%M:%S"),
                    end_local.time().strftime("%H:%M:%S"),
                    duration,
                    gallons,
                    mean_gpm,
                    peak_gpm,
                    category,
                    session_id,
                ]
            )
            written += 1
    return written


def write_day_totals_csv(
    samples: list[tuple[datetime, float]],
    segments: list[tuple[int, int]],
    path: Path,
) -> int:
    """Per-day rollup: total gallons, autofill gallons, autofill session count."""
    path.parent.mkdir(parents=True, exist_ok=True)
    day_total: dict[date, float] = defaultdict(float)
    day_autofill: dict[date, float] = defaultdict(float)
    day_autofill_count: dict[date, int] = defaultdict(int)

    # Total — sum all sample GPM (gal/min × 1 min = gallons).
    for ts, g in samples:
        d = segment_to_local(ts).date()
        day_total[d] += g

    # Autofill — only segments classified as such.
    for start_i, end_i in segments:
        if not is_pool_autofill_segment(samples, start_i, end_i):
            continue
        span = samples[start_i : end_i + 1]
        day = segment_to_local(span[0][0]).date()
        day_autofill[day] += sum(g for _, g in span)
        day_autofill_count[day] += 1

    all_days = sorted(set(day_total) | set(day_autofill))
    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(
            [
                "date",
                "total_gallons",
                "pool_autofill_gallons",
                "pool_autofill_sessions",
                "other_gallons",
            ]
        )
        for d in all_days:
            total = round(day_total[d], 2)
            af = round(day_autofill[d], 2)
            other = round(total - af, 2)
            w.writerow([d.isoformat(), total, af, day_autofill_count[d], other])
    return len(all_days)


# ──────────────────────────────────  Main  ───────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--from", dest="from_date", help="YYYY-MM-DD (default: auto-detect device install)"
    )
    parser.add_argument(
        "--to",
        dest="to_date",
        default=date.today().isoformat(),
        help="YYYY-MM-DD (default: today)",
    )
    args = parser.parse_args()

    print("Loading Flume API credentials…")
    creds = load_credentials()
    print("Minting OAuth token…")
    token, user_id = mint_token(creds)
    print(f"  user_id={user_id}")

    print("Listing devices…")
    devices = list_devices(token, user_id)
    # Prefer the meter sensor (type 2) over the bridge (type 1).
    sensor_devices = [d for d in devices if d.get("type") == 2]
    chosen = sensor_devices[0] if sensor_devices else devices[0]
    device_id = chosen["id"]
    print(f"  device_id={device_id}")

    rate = RateLimiter()

    # Resolve date range (all naive — device-local TZ per Flume API contract).
    if args.from_date:
        earliest = datetime.strptime(args.from_date, "%Y-%m-%d")
    else:
        print("Discovering earliest data via YR + MON probes…")
        earliest = discover_earliest_data(token, user_id, device_id, rate)
    latest = datetime.strptime(args.to_date, "%Y-%m-%d") + timedelta(days=1)

    span_days = (latest - earliest).days
    chunks = span_days  # 1 chunk per day at MIN bucket
    eta_min = chunks * 60 / (FLUME_RATE_LIMIT_PER_HOUR * 0.9)
    eta_hr = eta_min / 60
    print(
        f"\nFetching per-minute Flume data: {earliest.date()} → {latest.date()} "
        f"({span_days} days, {chunks} per-day chunks at MIN bucket)"
    )
    print(f"  Rate budget: {FLUME_RATE_LIMIT_PER_HOUR} req/hr → est wall time "
          f"{eta_hr:.1f}h ({eta_min:.0f} min)\n")

    samples = list(chunked_pull(token, user_id, device_id, earliest, latest, rate))
    print(f"\nFetched {len(samples)} per-minute samples total")

    if not samples:
        print("No data returned — aborting.")
        return 1

    print("\nDetecting segments…")
    segments = detect_segments(samples)
    print(f"  {len(segments)} continuous-usage segments")

    print("\nWriting CSVs…")
    n_seg = write_segments_csv(samples, segments, SEGMENTS_CSV)
    n_day = write_day_totals_csv(samples, segments, DAY_TOTALS_CSV)

    # Make output readable by group `users` so johnw can scp / open without sudo.
    for p in (SEGMENTS_CSV, DAY_TOTALS_CSV):
        os.chmod(p, 0o640)
    try:
        import grp
        users_gid = grp.getgrnam("users").gr_gid
        for p in (SEGMENTS_CSV, DAY_TOTALS_CSV):
            os.chown(p, -1, users_gid)
    except (KeyError, PermissionError):
        pass

    print(f"\n✓ wrote {SEGMENTS_CSV} ({n_seg} rows)")
    print(f"✓ wrote {DAY_TOTALS_CSV} ({n_day} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
