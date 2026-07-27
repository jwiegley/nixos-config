from __future__ import annotations
import logging
import sys
import time
from datetime import datetime, timedelta, timezone
from .config import Config
from .state import State
from .http import Client, HttpError
from .github import GitHubCollector
from .gitea import GiteaCollector
from .delta import compute_deltas, compute_stale, build_awaiting, owner_logins
from . import triage as _triage_mod
from .triage import triage, call_hermes
from .models import Coverage
from .render import render_report, render_baseline, build_message, deliver

log = logging.getLogger("oss_secretary")
CA = "/etc/ssl/certs/ca-certificates.crt"
OVERLAP = timedelta(minutes=10)
# Above this many deltas, skip the per-thread comment enrichment (N+1 fetches
# would blow TimeoutStartSec). Applies to the first-ever comprehensive run and
# to any unusually large delta day; the awaiting signal falls back to coarse.
ENRICH_CAP = 50


def _sendmail(raw, cfg):
    return deliver(raw, cfg)


def _since_with_overlap(watermark_iso):
    """Replay the stored watermark minus a 10-minute overlap so a boundary
    event isn't dropped; de-dup by (platform,node_id) absorbs the re-fetch."""
    if not watermark_iso:
        return None
    try:
        t = datetime.fromisoformat(watermark_iso.replace("Z", "+00:00")) - OVERLAP
        return t.strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return watermark_iso


def _make_collectors(cfg, state):
    gh = GitHubCollector(
        Client("https://api.github.com", {"Authorization": f"Bearer {cfg.github_token}"},
               CA, state, "github"), cfg)
    gt = GiteaCollector(
        Client(cfg.gitea_url, {"Authorization": f"token {cfg.gitea_token}"},
               CA, state, "gitea", min_interval=cfg.gitea_min_interval), cfg)
    return gh, gt


def _collect(cfg, state, cov, gh, gt):
    """Return (threads, notifications). Per-repo isolated: one bad repo (HTTP,
    transport, or malformed JSON) is logged (redacted, metadata-only), counted,
    and skipped — never aborts the run."""
    threads, notifs = [], []
    gh_since = _since_with_overlap(state.get_meta("github_last_poll_utc"))
    gt_since = _since_with_overlap(state.get_meta("gitea_last_poll_utc"))
    for collector, since in ((gh, gh_since), (gt, gt_since)):
        name = collector.__class__.__name__
        try:
            repos = collector.list_repos()
        except Exception as e:
            log.warning("repo enumeration failed for %s: %s", name, type(e).__name__)
            cov.repos_errored += 1
            continue
        for r in repos:
            try:
                threads.extend(collector.list_threads(r, since))
                cov.repos_scanned += 1
            except Exception as e:
                log.warning("repo scan failed (%s): %s", name, type(e).__name__)
                cov.repos_errored += 1
                cov.errored_repos.append(r.full_name)
                # `r` IS a Repo here and carries the authoritative html_url;
                # the render layer cannot derive one because a bare
                # `owner/name` is ambiguous between GitHub and Gitea.
                cov.errored_repo_urls[r.full_name] = r.html_url
        try:
            notifs.extend(collector.list_notifications(since))
        except Exception as e:
            log.warning("notifications fetch failed for %s: %s", name, type(e).__name__)
    return threads, notifs


def _enrich(deltas, gh, gt, owners, now_iso):
    """Replace opener-derived coarse signals with the REAL last comment for each
    changed thread (bounded to the small delta set). Rebuilds the awaiting bundle
    with the true last commenter + has_owner_response from comment history."""
    for d in deltas:
        collector = gh if d.thread.platform == "github" else gt
        try:
            sig = collector.thread_signals(d.thread.repo_full_name, d.thread.number, owners)
        except Exception:
            sig = None
        if not sig:
            continue
        t = d.thread
        t.last_commenter = sig["last_commenter"]
        t.last_commenter_is_bot = sig["last_commenter_is_bot"]
        t.last_comment_id = sig["last_comment_id"]
        t.last_comment_at = sig["last_comment_at"]
        t.body_excerpt = sig["body_excerpt"]
        d.awaiting = build_awaiting(t, owners, now_iso,
                                    has_owner_response=sig["has_owner_response"])


def _triage(cfg, deltas, notifs):
    """Run triage.triage while binding report's ``call_hermes`` into the triage
    module, so a caller/test that swaps ``report.call_hermes`` takes effect
    (triage resolves the symbol from its own globals). Pollution-free."""
    orig = _triage_mod.call_hermes
    _triage_mod.call_hermes = call_hermes
    try:
        return triage(cfg, deltas, notifs)
    finally:
        _triage_mod.call_hermes = orig


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    cfg = Config.from_env()
    state = State(cfg.state_db)
    # Take the lock BEFORE any DB write (schema DDL happens in open()).
    if not state.acquire_lock():
        log.info("another run holds the lock; exiting")
        return 0
    state.open()
    started = time.monotonic()
    now = datetime.now(timezone.utc)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    date_str = now.strftime("%Y-%m-%d")
    cov = Coverage()
    owners = owner_logins(cfg)
    gh, gt = _make_collectors(cfg, state)
    try:
        run_id = state.next_run_id()
        first_ever = not state.baseline_established()
        # Default first run is COMPREHENSIVE: an empty state means every open
        # thread is "new", so the first email is a full inventory summary. A
        # silent seed (counts only, no per-item report) is opt-in via
        # OSS_SECRETARY_BOOTSTRAP for a future flood-free re-baseline.
        silent = cfg.bootstrap
        threads, notifs = _collect(cfg, state, cov, gh, gt)
        deltas = compute_deltas(state, threads, run_id, silent, owners, now_iso)
        if silent:
            gh_n = sum(1 for t in threads if t.platform == "github" and t.state == "open")
            gt_n = sum(1 for t in threads if t.platform == "gitea" and t.state == "open")
            subject, body, html_body = render_baseline(cfg, gh_n, gt_n, date_str)
        else:
            if len(deltas) <= ENRICH_CAP:
                _enrich(deltas, gh, gt, owners, now_iso)
            else:
                log.info("skipping per-thread enrichment for %d items (large/initial run)",
                         len(deltas))
            stale = compute_stale(state, run_id, cfg.stale_days, owners, now_iso)
            cov.items_to_triage = len(deltas)
            attention, banner, omitted = _triage(cfg, deltas, notifs)
            cov.items_omitted = omitted
            cov.llm_status = "fallback" if banner else "ok"
            subject, body, html_body = render_report(cfg, deltas, notifs, attention,
                                                     cov, banner, date_str, stale)
        cov.duration_s = round(time.monotonic() - started, 1)
        rc = _sendmail(build_message(subject, body, cfg.sender, cfg.recipient,
                                     html_body), cfg)
        if rc == 0:
            state.set_meta("github_last_poll_utc", now_iso)
            state.set_meta("gitea_last_poll_utc", now_iso)
            if first_ever:
                state.mark_baseline(now_iso)
            state.save_run_summary(run_id, subject)
            state.commit()
            log.info("run %d delivered: %d deltas, %d notifs, %d repos (%d errored)",
                     run_id, len(deltas), len(notifs), cov.repos_scanned, cov.repos_errored)
            return 0
        state.rollback()
        log.error("sendmail rc=%d; state rolled back", rc)
        return 1
    except Exception as e:            # top-level: metadata only, never the payload
        from .redact import redact
        state.rollback()
        log.error("run failed: %s: %s", type(e).__name__, redact(str(e)))
        return 1
    finally:
        state.close()


if __name__ == "__main__":
    sys.exit(main())
