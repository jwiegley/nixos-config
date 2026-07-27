"""Cache-completeness tests — the 2026-05-23 silent data loss.

For two months this pipeline threw away ~94% of its own data and every
health check stayed green. The 00:30 timer run asked Flume for the whole of
today, thirty minutes into it; Flume padded the 1410 minutes that had not
happened yet with zeros; that response was written to `<today>.json`; and
because a file now existed, the 06:30 / 12:30 / 18:30 runs skipped the day.
Each day was frozen at its first half hour, forever. Nothing noticed,
because a partial day and a complete day are the same shape: 1440 samples.

The defect class is "a cache entry was written before the data it caches
was complete, and completeness was never re-checked". These tests pin the
property, not the symptom:

  * an in-progress day is always re-fetched and never written;
  * a finished day is written once, with its completeness recorded, and
    then served from cache without spending an API call;
  * "has this day ended" is asked in the device-local frame the cache key
    was minted in, not in UTC and not in the host TZ;
  * the 908 pre-existing bare-array files keep working, unmigrated.

The paths that touch the cache are tested against a *frozen real clock*
rather than an injected one, so they exercise `local_now()` for real. The
pure predicates take an explicit `now=`, which is faster and states the
boundary directly.
"""

from __future__ import annotations

import json
import os
from datetime import date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from freezegun import freeze_time

import emit_segments_csv as esc
import flume_db_sync as fds
from flume_data import day_cache


UTC = ZoneInfo("UTC")
LA = ZoneInfo("America/Los_Angeles")


# ───────────────────────────────── Helpers ───────────────────────────────────


def at_local(year, month, day, hour, minute=0) -> datetime:
    """An instant named in device-local wall-clock time.

    The tests want to say "06:30 on the 26th, in the zone the cache keys
    live in"; freezegun wants an absolute instant.
    """
    return datetime(year, month, day, hour, minute, tzinfo=LA)


def minute_series(day: date, nonzero_minutes: int = 0,
                  total_minutes: int = 1440, gpm: float = 2.5):
    """A Flume-shaped day response.

    `total_minutes` buckets, the first `nonzero_minutes` carrying flow and
    every one after that zero. That trailing run of zeros is the whole
    problem: for a day 30 minutes old Flume returns all 1440 buckets with
    1410 of them zero-filled, which is byte-for-byte the shape of a quiet
    complete day.
    """
    base = datetime.combine(day, time.min)
    return [
        (base + timedelta(minutes=i), gpm if i < nonzero_minutes else 0.0)
        for i in range(total_minutes)
    ]


def write_legacy_cache(cache_dir: Path, day: date, points) -> Path:
    """Write the pre-2026-07-27 on-disk format: a bare JSON array.

    This is what all 908 archived files look like. No envelope, no
    completeness record, nothing to distinguish a full day from a truncated
    one.
    """
    path = cache_dir / f"{day.isoformat()}.json"
    path.write_text(json.dumps([[ts.isoformat(), v] for ts, v in points]))
    return path


def write_envelope_cache(cache_dir: Path, day: date, points,
                         *, complete: bool) -> Path:
    """Write the current self-describing format, including `complete: false`.

    The production writer never emits `complete: false` — it refuses to
    write an unfinished day at all. This helper exists to exercise the
    *reader's* contract, which must honour the label if any writer ever
    does produce one.
    """
    path = cache_dir / f"{day.isoformat()}.json"
    path.write_text(json.dumps({
        "schema": day_cache.CACHE_SCHEMA_VERSION,
        "day": day.isoformat(),
        "complete": complete,
        "written_at": datetime.combine(day, time.min).isoformat(),
        "points": [[ts.isoformat(), v] for ts, v in points],
    }))
    return path


def nonzero_count(points) -> int:
    return sum(1 for _, gpm in points if gpm)


class FakeFlumeAPI:
    """Stand-in for `emit_segments_csv.query_data`, counting calls."""

    def __init__(self):
        self.calls = 0
        self.windows: list[tuple[datetime, datetime]] = []
        self._by_day: dict[date, list] = {}
        self._default: list | None = None

    def returns(self, points, *, day: date | None = None) -> "FakeFlumeAPI":
        if day is None:
            self._default = points
        else:
            self._by_day[day] = points
        return self

    def __call__(self, token, user_id, device_id, since, until, bucket, rate):
        self.calls += 1
        self.windows.append((since, until))
        if since.date() in self._by_day:
            return list(self._by_day[since.date()])
        if self._default is not None:
            return list(self._default)
        return minute_series(since.date(), nonzero_minutes=200)


# ───────────────────────────────── Fixtures ──────────────────────────────────


@pytest.fixture
def cache_dir(tmp_path, monkeypatch) -> Path:
    """Redirect the per-day cache at its single canonical definition."""
    d = tmp_path / "per-minute-by-day"
    d.mkdir()
    monkeypatch.setattr(day_cache, "CACHE_DIR", d)
    return d


@pytest.fixture
def api(monkeypatch) -> FakeFlumeAPI:
    """Replace the HTTP call. Also removes the 33s/request rate-limit sleep,
    which lives inside the real `query_data`."""
    fake = FakeFlumeAPI()
    monkeypatch.setattr(esc, "query_data", fake)
    return fake


def pull_day(day: date, **kwargs):
    """Run chunked_pull over exactly one local day, on the ambient clock."""
    start = datetime.combine(day, time.min)
    return list(esc.chunked_pull(
        "tok", 1, "dev", start, start + timedelta(days=1),
        esc.RateLimiter(), **kwargs,
    ))


# ════════════════════════ 1. The regression ══════════════════════════════════


@freeze_time(at_local(2026, 7, 26, 6, 30))
def test_partial_day_cached_at_0030_is_refetched_later_the_same_day(cache_dir, api):
    """The bug, exactly as it ran in production for two months.

    00:30: Flume returns 1440 buckets for a day 30 minutes old, 30 of them
    real. That lands in <today>.json. 06:30: the run must go back to the
    API and pick up the 390 minutes that have happened since. Before the
    fix it saw the file, skipped the day, and reported success.
    """
    today = date(2026, 7, 26)
    write_legacy_cache(cache_dir, today, minute_series(today, nonzero_minutes=30))
    api.returns(minute_series(today, nonzero_minutes=390))

    got = pull_day(today)

    assert api.calls == 1, (
        "an in-progress day must be re-fetched; a cache file written 30 "
        "minutes into the day is not that day"
    )
    assert nonzero_count(got) == 390, (
        "the caller must receive the freshly-fetched day, not the stale "
        "1410-zero payload"
    )


def test_every_later_run_of_the_same_day_refetches(cache_dir, api):
    """All three later runs of the timer, not just the next one."""
    today = date(2026, 7, 26)
    write_legacy_cache(cache_dir, today, minute_series(today, nonzero_minutes=30))

    for hour in (6, 12, 18):
        with freeze_time(at_local(2026, 7, 26, hour, 30)):
            pull_day(today)

    assert api.calls == 3


# ═════════════════ 2. Never persist an unfinished window ═════════════════════


@freeze_time(at_local(2026, 7, 26, 6, 30))
def test_in_progress_day_is_yielded_but_never_written_to_cache(cache_dir, api):
    """Today's partial data must still reach the caller — and so the DB —
    but must not become the cached answer for the day."""
    today = date(2026, 7, 26)
    api.returns(minute_series(today, nonzero_minutes=390))

    got = pull_day(today)

    assert len(got) == 1440, "the partial day is still yielded"
    assert not (cache_dir / "2026-07-26.json").exists(), (
        "a window that has not elapsed must not earn a cache file"
    )


@freeze_time(at_local(2026, 7, 26, 0, 30))
def test_the_0030_run_cannot_cache_the_day_it_is_standing_in(cache_dir, api):
    """The run that caused the outage, replayed."""
    today = date(2026, 7, 26)
    api.returns(minute_series(today, nonzero_minutes=30))

    pull_day(today)

    assert not (cache_dir / "2026-07-26.json").exists()


def test_write_cache_day_refuses_an_unfinished_day(cache_dir):
    today = date(2026, 7, 26)
    written = day_cache.write_cache_day(
        today, minute_series(today, nonzero_minutes=30),
        now=datetime(2026, 7, 26, 18, 30),
    )
    assert written is False
    assert not (cache_dir / "2026-07-26.json").exists()


@freeze_time(at_local(2026, 7, 27, 0, 30))
def test_a_stale_partial_file_is_replaced_once_the_day_ends(cache_dir, api):
    """The self-healing path.

    A day left behind by the old code sits on disk as a legacy partial
    capture. Once the day is over and it comes round again inside the sync
    window, the fetch must overwrite it with a recorded-complete file —
    otherwise the fix would leave its own deploy day poisoned forever.
    """
    day = date(2026, 7, 26)
    write_legacy_cache(cache_dir, day, minute_series(day, nonzero_minutes=30))
    api.returns(minute_series(day, nonzero_minutes=612))

    # The sync decides first — a legacy file proves nothing — then fetches.
    assert fds.days_needing_fetch([day]) == [day]
    pull_day(day, reuse_cache=False)

    payload = json.loads((cache_dir / "2026-07-26.json").read_text())
    assert payload["complete"] is True
    assert nonzero_count(day_cache.read_cache_day(day).points) == 612


# ═════════════════ 3. A finished day is served from cache ════════════════════


@freeze_time(at_local(2026, 7, 27, 6, 30))
def test_completed_day_is_served_from_cache_without_an_api_call(cache_dir, api):
    yesterday = date(2026, 7, 26)
    write_envelope_cache(
        cache_dir, yesterday,
        minute_series(yesterday, nonzero_minutes=612), complete=True,
    )

    got = pull_day(yesterday)

    assert api.calls == 0, "a recorded-complete day must not cost an API call"
    assert nonzero_count(got) == 612


@freeze_time(at_local(2026, 7, 27, 6, 30))
def test_legacy_file_for_a_finished_day_still_satisfies_the_resume_cache(cache_dir, api):
    """`emit_segments_csv`'s eight-hour historical pull must not re-fetch
    the 908 days it already has on disk just because they predate the
    completeness record."""
    old_day = date(2026, 3, 15)
    write_legacy_cache(cache_dir, old_day, minute_series(old_day, nonzero_minutes=311))

    got = pull_day(old_day)

    assert api.calls == 0
    assert nonzero_count(got) == 311


@freeze_time(at_local(2026, 7, 27, 0, 30))
def test_finished_day_is_cached_with_its_completeness_recorded(cache_dir, api):
    day = date(2026, 7, 26)
    api.returns(minute_series(day, nonzero_minutes=612))

    pull_day(day)

    payload = json.loads((cache_dir / "2026-07-26.json").read_text())
    assert payload["complete"] is True
    assert payload["day"] == "2026-07-26"
    assert payload["schema"] == day_cache.CACHE_SCHEMA_VERSION
    assert len(payload["points"]) == 1440

    # …and the next run of the same day costs nothing.
    pull_day(day)
    assert api.calls == 1


@freeze_time(at_local(2026, 7, 27, 0, 30))
def test_write_is_atomic_and_leaves_no_temp_file(cache_dir):
    day = date(2026, 7, 26)
    day_cache.write_cache_day(day, minute_series(day, nonzero_minutes=5))
    assert sorted(p.name for p in cache_dir.iterdir()) == ["2026-07-26.json"]


@freeze_time(at_local(2026, 7, 27, 0, 30))
def test_an_explicit_clock_overrides_the_ambient_one(cache_dir, api):
    """`now=` is threaded through the write path for callers that need to
    reason about a moment other than this one."""
    day = date(2026, 7, 26)
    pull_day(day, now=datetime(2026, 7, 26, 18, 30))
    assert not (cache_dir / "2026-07-26.json").exists()


# ═══════════════════════ 4. The local-midnight boundary ══════════════════════


def test_1830_run_does_not_mark_today_complete():
    assert day_cache.day_is_final(
        date(2026, 7, 26), now=datetime(2026, 7, 26, 18, 30)
    ) is False


def test_day_is_not_final_one_minute_before_local_midnight():
    assert day_cache.day_is_final(
        date(2026, 7, 26), now=datetime(2026, 7, 26, 23, 59)
    ) is False


def test_day_becomes_final_exactly_at_local_midnight():
    assert day_cache.day_is_final(
        date(2026, 7, 26), now=datetime(2026, 7, 27, 0, 0, 0)
    ) is True


def test_utc_date_rollover_does_not_end_the_local_day():
    """The trap a naive implementation falls into.

    At 06:30 UTC on the 27th it is 23:30 on the 26th in Los Angeles. A
    UTC-based check calls the 26th finished with half an hour still to run,
    and the last 30 minutes of the day get frozen as zeros.
    """
    utc_already_the_27th = datetime(2026, 7, 27, 6, 30, tzinfo=UTC)
    assert day_cache.local_now(utc_already_the_27th) == datetime(2026, 7, 26, 23, 30)
    assert day_cache.day_is_final(date(2026, 7, 26), now=utc_already_the_27th) is False
    assert day_cache.local_today(utc_already_the_27th) == date(2026, 7, 26)


def test_local_midnight_in_utc_terms_ends_the_day():
    """07:00 UTC = 00:00 PDT. Half an hour later than the test above."""
    at_local_midnight = datetime(2026, 7, 27, 7, 0, tzinfo=UTC)
    assert day_cache.day_is_final(date(2026, 7, 26), now=at_local_midnight) is True


def test_dst_spring_forward_day_uses_the_right_offset():
    """2026-03-08 is the PST→PDT transition; the offset differs either side
    of it, so a hardcoded -8 or -7 gets one of these wrong."""
    still_the_8th = datetime(2026, 3, 9, 6, 30, tzinfo=UTC)   # 23:30 PDT on 03-08
    assert day_cache.local_now(still_the_8th) == datetime(2026, 3, 8, 23, 30)
    assert day_cache.day_is_final(date(2026, 3, 8), now=still_the_8th) is False

    now_the_9th = datetime(2026, 3, 9, 7, 30, tzinfo=UTC)     # 00:30 PDT on 03-09
    assert day_cache.day_is_final(date(2026, 3, 8), now=now_the_9th) is True


@freeze_time(at_local(2026, 7, 26, 23, 59))
def test_the_last_minute_of_the_day_still_refetches(cache_dir, api):
    """The boundary, exercised through the real clock rather than stated."""
    today = date(2026, 7, 26)
    write_legacy_cache(cache_dir, today, minute_series(today, nonzero_minutes=30))
    pull_day(today)
    assert api.calls == 1
    assert day_cache.read_cache_day(today).legacy is True, "not overwritten"


# ═══════════════ 5. The 908 pre-existing files keep working ══════════════════


def test_legacy_bare_array_file_is_read_without_migration(cache_dir):
    day = date(2026, 3, 15)
    path = write_legacy_cache(cache_dir, day, minute_series(day, nonzero_minutes=311))
    before = path.read_bytes()

    entry = day_cache.read_cache_day(day)

    assert entry is not None
    assert entry.legacy is True
    assert entry.complete is None, "completeness is unrecorded, not false"
    assert len(entry.points) == 1440
    assert nonzero_count(entry.points) == 311
    assert isinstance(entry.points[0][0], datetime)
    assert path.read_bytes() == before, "reading must not rewrite or migrate"


def test_legacy_and_envelope_files_coexist_in_one_directory(cache_dir):
    legacy_day, new_day = date(2026, 3, 15), date(2026, 7, 26)
    write_legacy_cache(cache_dir, legacy_day,
                       minute_series(legacy_day, nonzero_minutes=311))
    day_cache.write_cache_day(new_day, minute_series(new_day, nonzero_minutes=612),
                              now=datetime(2026, 7, 27, 0, 30))

    assert day_cache.cached_days() == [legacy_day, new_day]
    samples = fds.load_cached_samples([legacy_day, new_day])
    assert len(samples) == 2880
    assert nonzero_count(samples) == 923


def test_non_day_files_in_the_cache_directory_are_ignored(cache_dir):
    (cache_dir / "README.json").write_text("[]")
    day = date(2026, 3, 15)
    write_legacy_cache(cache_dir, day, minute_series(day))
    assert day_cache.cached_days() == [day]


def test_corrupt_cache_file_is_treated_as_absent_rather_than_fatal(cache_dir):
    day = date(2026, 3, 15)
    (cache_dir / f"{day.isoformat()}.json").write_text('[["2026-03-15T00:00:00", 0.0')

    assert day_cache.read_cache_day(day) is None
    assert day_cache.cache_day_is_authoritative(
        day, now=datetime(2026, 7, 27, 6, 30)) is False
    assert fds.load_cached_samples([day]) == []


REAL_CACHE = Path("/var/lib/flume-data/cache/per-minute-by-day")


def _real_cache_is_readable() -> bool:
    """`Path.is_dir()` raises rather than answering when an ancestor is not
    traversable, which is the normal case here: /var/lib/flume-data is 0700."""
    try:
        return REAL_CACHE.is_dir() and os.access(REAL_CACHE, os.R_OK | os.X_OK)
    except OSError:
        return False


@pytest.mark.skipif(
    not _real_cache_is_readable(),
    reason="live cache dir not readable (/var/lib/flume-data is 0700; run as "
           "root or flume-data to exercise the real archive)",
)
def test_the_live_cache_archive_parses_and_is_left_untouched():
    """Every file actually on disk must load, in whatever format it is in.

    Skipped for an unprivileged run. Under `sudo -u flume-data` it walks
    the real ~908-file archive: proof that no migration is needed and that
    reading changes nothing.
    """
    days = day_cache.cached_days()
    assert days, "expected a populated archive"
    before = {d: day_cache.cache_path_for(d).stat().st_mtime_ns for d in days}

    for d in days:
        entry = day_cache.read_cache_day(d)
        assert entry is not None, f"{d} failed to parse"
        assert entry.points, f"{d} parsed to an empty series"

    after = {d: day_cache.cache_path_for(d).stat().st_mtime_ns for d in days}
    assert before == after, "reading the archive must not touch it"


# ══════════════ 6. The sync's own rule, where the bug was wired ══════════════


def test_days_needing_fetch_always_includes_today(cache_dir):
    today = date(2026, 7, 26)
    # A recorded-complete file for a day that has not ended cannot arise
    # from the writer; forge one to prove the rule holds anyway.
    write_envelope_cache(cache_dir, today, minute_series(today), complete=True)
    assert fds.days_needing_fetch(
        [today], now=datetime(2026, 7, 26, 18, 30)) == [today]


def test_days_needing_fetch_includes_a_missing_day(cache_dir):
    assert fds.days_needing_fetch(
        [date(2026, 7, 26)], now=datetime(2026, 7, 27, 6, 30)) == [date(2026, 7, 26)]


def test_days_needing_fetch_includes_a_legacy_day_in_the_window(cache_dir):
    """How the tail of the damaged window heals itself: a legacy file is
    not proof of anything, so a day inside `--days` gets pulled again."""
    day = date(2026, 7, 26)
    write_legacy_cache(cache_dir, day, minute_series(day, nonzero_minutes=30))
    assert fds.days_needing_fetch([day], now=datetime(2026, 7, 27, 6, 30)) == [day]


def test_days_needing_fetch_excludes_a_recorded_complete_day(cache_dir):
    day = date(2026, 7, 26)
    write_envelope_cache(cache_dir, day, minute_series(day, nonzero_minutes=612),
                         complete=True)
    assert fds.days_needing_fetch([day], now=datetime(2026, 7, 27, 6, 30)) == []


def test_days_needing_fetch_includes_a_day_recorded_incomplete(cache_dir):
    day = date(2026, 7, 26)
    write_envelope_cache(cache_dir, day, minute_series(day, nonzero_minutes=30),
                         complete=False)
    assert fds.days_needing_fetch([day], now=datetime(2026, 7, 27, 6, 30)) == [day]


def test_the_four_day_sync_window_settles_to_one_fetch(cache_dir):
    """Steady state after the fix: three finished days in hand, today
    pulled. Under the old rule this window fetched nothing at all."""
    today = date(2026, 7, 27)
    window = [today - timedelta(days=i) for i in range(3, -1, -1)]
    for d in window[:-1]:
        write_envelope_cache(cache_dir, d, minute_series(d, nonzero_minutes=600),
                             complete=True)
    assert fds.days_needing_fetch(
        window, now=datetime(2026, 7, 27, 6, 30)) == [today]


def test_load_cached_samples_skips_a_day_recorded_incomplete(cache_dir):
    """`--from-cache` replays the archive; a payload that labels itself a
    partial capture must not be replayed as if it were the day."""
    good, bad = date(2026, 7, 25), date(2026, 7, 26)
    write_envelope_cache(cache_dir, good, minute_series(good, nonzero_minutes=600),
                         complete=True)
    write_envelope_cache(cache_dir, bad, minute_series(bad, nonzero_minutes=30),
                         complete=False)

    samples = fds.load_cached_samples([good, bad])

    assert len(samples) == 1440
    assert {ts.date() for ts, _ in samples} == {good}


# ═══════════ 7. The repair actually reaches the database layer ═══════════════


@freeze_time(at_local(2026, 7, 26, 6, 30))
def test_ensure_cache_for_returns_the_samples_it_pulled(cache_dir, api):
    """Today is never cached, so this return value is the only route by
    which today's data reaches Postgres. The old code discarded it."""
    today = date(2026, 7, 26)
    api.returns(minute_series(today, nonzero_minutes=390))

    pulled = fds.ensure_cache_for([today], "tok", 1, "dev")

    assert nonzero_count(pulled) == 390
    assert not (cache_dir / "2026-07-26.json").exists()


@freeze_time(at_local(2026, 7, 27, 6, 30))
def test_ensure_cache_for_pulls_only_the_days_it_was_given(cache_dir, api):
    """A contiguous range would spend 33s of rate budget per complete day
    sitting between the stale ones."""
    fds.ensure_cache_for([date(2026, 7, 20), date(2026, 7, 26)], "tok", 1, "dev")
    assert api.calls == 2
    assert [w[0].date() for w in api.windows] == [date(2026, 7, 20), date(2026, 7, 26)]


def test_fresh_samples_win_over_a_stale_cached_day(cache_dir):
    """The whole repair path in one assertion: a stale partial file is on
    disk, a fresh pull happened, and what goes to the DB is the fresh
    day — time-ordered and free of duplicate timestamps."""
    today = date(2026, 7, 26)
    write_legacy_cache(cache_dir, today, minute_series(today, nonzero_minutes=30))
    fresh = minute_series(today, nonzero_minutes=390)

    merged = fds.merge_samples(fds.load_cached_samples([today]), fresh)

    assert len(merged) == 1440, "duplicate timestamps must collapse"
    assert nonzero_count(merged) == 390
    assert merged == sorted(merged), "segment detection walks this positionally"


def test_merge_collapses_the_shared_midnight_sample(cache_dir):
    """Day N-1's file ends with, and day N's file begins with, the same
    midnight timestamp."""
    d1, d2 = date(2026, 7, 25), date(2026, 7, 26)
    midnight = datetime.combine(d2, time.min)
    write_legacy_cache(cache_dir, d1, minute_series(d1) + [(midnight, 1.0)])
    write_legacy_cache(cache_dir, d2, minute_series(d2))

    merged = fds.merge_samples(fds.load_cached_samples([d1, d2]))

    assert len(merged) == 2880
    assert len({ts for ts, _ in merged}) == 2880
