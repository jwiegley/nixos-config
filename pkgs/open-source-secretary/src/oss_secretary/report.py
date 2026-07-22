from __future__ import annotations
import logging
import sys
import time
from datetime import datetime, timezone
from .config import Config
from .state import State
from .http import Client, HttpError
from .github import GitHubCollector
from .gitea import GiteaCollector
from .delta import compute_deltas, owner_logins
from . import triage as _triage_mod
from .triage import triage, call_hermes
from .models import Coverage
from .render import render_report, render_baseline, build_message, deliver

log = logging.getLogger("oss_secretary")
CA = "/etc/ssl/certs/ca-certificates.crt"


def _sendmail(raw, cfg):
    return deliver(raw, cfg)


def _collect(cfg, state, cov):
    """Return (threads, notifications). Isolated per-repo; updates coverage."""
    threads, notifs = [], []
    gh = GitHubCollector(
        Client("https://api.github.com", {"Authorization": f"Bearer {cfg.github_token}"},
               CA, state, "github"), cfg)
    gt = GiteaCollector(
        Client(cfg.gitea_url, {"Authorization": f"token {cfg.gitea_token}"},
               CA, state, "gitea"), cfg)
    gh_since = state.get_meta("github_last_poll_utc")
    gt_since = state.get_meta("gitea_last_poll_utc")
    for collector, since in ((gh, gh_since), (gt, gt_since)):
        try:
            repos = collector.list_repos()
        except HttpError as e:
            log.warning("repo enumeration failed: %s", type(e).__name__)
            cov.repos_errored += 1
            continue
        for r in repos:
            try:
                threads.extend(collector.list_threads(r, since))
                cov.repos_scanned += 1
            except HttpError:
                cov.repos_errored += 1
                cov.errored_repos.append(r.full_name)
        try:
            notifs.extend(collector.list_notifications(since))
        except HttpError:
            log.warning("notifications fetch failed for %s", collector.__class__.__name__)
    return threads, notifs


def _triage(cfg, deltas, notifs):
    """Run triage, injecting this module's ``call_hermes`` into the triage module.

    ``triage.triage()`` resolves ``call_hermes`` from its own module globals, so a
    caller (or test) that swaps out ``report.call_hermes`` would otherwise have no
    effect. Bind report's reference into the triage module for the duration of the
    call and restore it afterward — a pollution-free dependency-injection shim that
    keeps the LLM seam patchable and the orchestration hermetic under test.
    """
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
    state.open()
    if not state.acquire_lock():
        log.info("another run holds the lock; exiting")
        return 0
    started = time.monotonic()
    now = datetime.now(timezone.utc)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    date_str = now.strftime("%Y-%m-%d")
    cov = Coverage()
    try:
        run_id = state.next_run_id()
        baseline = not state.baseline_established()
        threads, notifs = _collect(cfg, state, cov)
        deltas = compute_deltas(state, threads, run_id, baseline, cfg.stale_days,
                                owner_logins(cfg), now_iso)
        if baseline:
            gh_n = sum(1 for t in threads if t.platform == "github")
            gt_n = sum(1 for t in threads if t.platform == "gitea")
            subject, body = render_baseline(cfg, gh_n, gt_n, date_str)
            attention, banner = [], None
        else:
            cov.items_to_triage = len(deltas)
            attention, banner = _triage(cfg, deltas, notifs)
            cov.llm_status = "fallback" if banner else "ok"
            subject, body = render_report(cfg, deltas, notifs, attention, cov,
                                          banner, date_str)
        cov.duration_s = round(time.monotonic() - started, 1)
        rc = _sendmail(build_message(subject, body, cfg.sender, cfg.recipient), cfg)
        if rc == 0:
            state.set_meta("github_last_poll_utc", now_iso)
            state.set_meta("gitea_last_poll_utc", now_iso)
            if baseline:
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
