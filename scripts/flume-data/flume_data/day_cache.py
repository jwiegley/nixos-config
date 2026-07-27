#!/usr/bin/env python3
"""Per-local-day cache of Flume per-minute samples, with recorded completeness.

WHY THIS MODULE EXISTS
──────────────────────
Between 2026-05-23 and 2026-07-27 this pipeline silently discarded ~94% of
its own data. The mechanism was a one-line conflation:

    if cache_path.exists():        # "we have this day" → "this day is done"

The 00:30 timer run asked Flume for *the whole of today*, thirty minutes
into it. Flume answers such a query with a full 1440-bucket series in which
the ~1410 minutes that have not happened yet are zero-filled. That response
was written to `<today>.json`, and because the file now existed the 06:30 /
12:30 / 18:30 runs skipped the day entirely. Every day was frozen at its
first half hour. Every health check passed, because a partial day and a
complete day are byte-shaped identically: both are exactly 1440 samples.

The invariant this module exists to enforce:

    A cache entry may substitute for an API call only when the file itself
    records that it captured a window which had already fully elapsed.

Two rules follow, and both are load-bearing:

  1. Never persist an in-progress window. `write_cache_day` refuses. A day
     still being lived can be fetched and used, but not cached.
  2. Never infer completeness from the mere existence of a file, and never
     from its mtime — an mtime flips the moment anyone copies, restores,
     rsyncs or touches the file. Completeness is *recorded*, inside the
     file, at write time.

TIMEZONE
────────
Cache keys are LOCAL days. Flume's query API speaks naive device-local time
and returns it the same way, so the entire pipeline is anchored to
America/Los_Angeles. "Has this day ended?" is therefore evaluated in that
same frame — never in UTC, and never in whatever the host TZ happens to be.
At 23:30 local on the 26th it is already the 27th in UTC; a UTC-based check
would call the 26th finished with half an hour still to run.

FILE FORMATS
────────────
Legacy — the 908 files written before 2026-07-27 — a bare JSON array:

    [["2026-03-15T00:00:00", 0.0], ["2026-03-15T00:01:00", 1.2], ...]

Current — a JSON object that describes itself:

    {"schema": 1, "day": "2026-03-15", "complete": true,
     "written_at": "2026-03-16T00:30:12", "points": [[...], ...]}

Both are read. Legacy files are never rewritten or migrated: they are read
in place, and because they carry no completeness record they are reported
as *unproven* (`complete is None`) rather than complete. Callers decide
what unproven means for them — see the two predicates at the bottom of this
module, which deliberately answer that question differently.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import date, datetime, time as dtime, timedelta
from pathlib import Path
from typing import Iterable
from zoneinfo import ZoneInfo

# Canonical location. Tests monkeypatch this attribute; every path in this
# module is built through `cache_path_for()`, which reads it at call time,
# so patching here redirects all callers including the operator scripts.
CACHE_DIR = Path("/var/lib/flume-data/cache/per-minute-by-day")

LOCAL_TZ_NAME = "America/Los_Angeles"
LOCAL_TZ = ZoneInfo(LOCAL_TZ_NAME)

CACHE_SCHEMA_VERSION = 1

# (naive local timestamp, gallons in that minute)
Sample = tuple[datetime, float]


# ─────────────────────────────── Local clock ─────────────────────────────────


def local_now(now: datetime | None = None) -> datetime:
    """Wall-clock time in the device-local zone, as a NAIVE datetime.

    Cache keys are minted from the naive device-local timestamps Flume
    returns, so completeness has to be judged in that same frame.

    `now` is the seam every caller uses for testing:
      * omitted   → real clock, converted into device-local time;
      * aware     → converted into device-local time (so a test may pass
                    UTC and exercise the local-vs-UTC boundary honestly);
      * naive     → taken as already being device-local.
    """
    if now is None:
        return datetime.now(LOCAL_TZ).replace(tzinfo=None)
    if now.tzinfo is not None:
        return now.astimezone(LOCAL_TZ).replace(tzinfo=None)
    return now


def local_today(now: datetime | None = None) -> date:
    """Today's date in the device-local zone (NOT `date.today()`).

    `date.today()` reads the host TZ. Those agree on vulcan today, but the
    cache key's frame must not depend on that coincidence.
    """
    return local_now(now).date()


def window_is_final(window_end: datetime, *, now: datetime | None = None) -> bool:
    """True once `window_end` (naive local) has passed."""
    return local_now(now) >= window_end


def day_is_final(day: date, *, now: datetime | None = None) -> bool:
    """True once `day` has fully elapsed in device-local time.

    Boundary is exclusive of the day itself and inclusive of the instant
    the next day begins: the 18:30 run on day D gets False for D, the
    00:00:00 tick of D+1 gets True.
    """
    return window_is_final(
        datetime.combine(day + timedelta(days=1), dtime.min), now=now
    )


# ──────────────────────────────── Cache I/O ──────────────────────────────────


@dataclass(frozen=True)
class CachedDay:
    """One day's cached payload, plus what the file says about itself."""

    day: date
    points: list[Sample]
    #: True/False when the file records it; None for legacy bare-array
    #: files, which predate the record and cannot be interrogated.
    complete: bool | None
    legacy: bool


def cache_path_for(day: date) -> Path:
    return CACHE_DIR / f"{day.isoformat()}.json"


def cached_days() -> list[date]:
    """Every day present in the cache directory, ascending."""
    if not CACHE_DIR.exists():
        return []
    out: list[date] = []
    for path in sorted(CACHE_DIR.glob("*.json")):
        try:
            out.append(date.fromisoformat(path.stem))
        except ValueError:
            continue  # not a day-keyed file; ignore rather than crash
    return out


def _decode_points(entries: Iterable) -> list[Sample]:
    return [(datetime.fromisoformat(e[0]), float(e[1])) for e in entries]


def read_cache_day(day: date) -> CachedDay | None:
    """Return the cached day, or None when absent or unreadable.

    A truncated or corrupt file is reported as absent rather than raised.
    The caller's remedy is identical either way — fetch the day again — and
    one bad file must not take down a nightly sync that walks a 900-day
    archive. (Writes are atomic, so this should not happen; it is here
    because "should not happen" is not a guarantee.)
    """
    path = cache_path_for(day)
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError, OSError) as exc:
        print(f"  WARN: unreadable cache file {path.name} "
              f"({exc.__class__.__name__}); treating as absent")
        return None

    if isinstance(raw, list):
        # Legacy bare array. Read in place, never rewritten.
        return CachedDay(day=day, points=_decode_points(raw),
                         complete=None, legacy=True)
    if isinstance(raw, dict):
        return CachedDay(day=day, points=_decode_points(raw.get("points", [])),
                         complete=bool(raw.get("complete", False)),
                         legacy=False)
    print(f"  WARN: unrecognised cache payload in {path.name}; treating as absent")
    return None


def write_cache_day(
    day: date, points: Iterable[Sample], *, now: datetime | None = None
) -> bool:
    """Persist `points` as the cache entry for `day`. Returns True if written.

    Refuses — returning False, not raising — while `day` is still in
    progress. That refusal IS the fix for the 2026-05-23 data loss: Flume
    pads the minutes that have not happened yet with zeros, so a response
    for "today" taken at 00:30 is indistinguishable from a quiet complete
    day and must never be allowed to become the cached answer for it.

    The write is atomic (temp file + rename). Two reasons: a half-written
    payload can never be read back as a day, and `os.replace` needs write
    permission on the *directory* rather than the target file — which is
    what lets the flume-data service user overwrite the 573 root-owned
    files left behind by the historical bulk pull.
    """
    if not day_is_final(day, now=now):
        return False

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": CACHE_SCHEMA_VERSION,
        "day": day.isoformat(),
        "complete": True,
        "written_at": local_now(now).isoformat(timespec="seconds"),
        "points": [[ts.isoformat(), v] for ts, v in points],
    }
    path = cache_path_for(day)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload))
    os.replace(tmp, path)
    return True


# ───────────────────────────── Trust predicates ──────────────────────────────
#
# Two questions that look the same and are not. Keep them apart.


def cache_day_is_authoritative(day: date, *, now: datetime | None = None) -> bool:
    """May the cache stand in for an API call when correctness is at stake?

    Requires BOTH that the file records completeness AND that the day has
    in fact elapsed. The second half is belt-and-braces against a clock
    that moved backwards or a file copied in from another host.

    A legacy bare-array file answers False. It predates the completeness
    record, and nothing inside it can distinguish a full day from thirty
    real minutes followed by 1410 zero-filled future ones. `flume_db_sync`
    uses this predicate, which is why the tail of the damaged window heals
    itself as it passes back through the sync's `--days` horizon.
    """
    entry = read_cache_day(day)
    if entry is None or not entry.complete:
        return False
    return day_is_final(day, now=now)


def cache_day_is_reusable(day: date, *, now: datetime | None = None) -> bool:
    """May the cache stand in for an API call when we are merely resuming?

    Weaker: any cached payload for a day that has already elapsed counts,
    including legacy files whose completeness was never recorded. This is
    the *resume* semantics `emit_segments_csv` needs — an eight-hour
    historical pull must not re-fetch 900 days it already has on disk —
    and it is deliberately NOT the semantics used to decide whether the
    database is being fed the truth.

    A payload that labels itself incomplete is refused here too.
    """
    entry = read_cache_day(day)
    if entry is None or entry.complete is False:
        return False
    return day_is_final(day, now=now)
