from __future__ import annotations
import os
import subprocess
import sys
from collections import OrderedDict
from .delta import item_id
from .redact import redact

_RULE = "=" * 60
_PLATFORM_TAG = {"github": "github", "gitea": "gitea"}


def _awaiting_owner(awaiting) -> bool:
    """A thread awaits John's reply when the last human comment was not his."""
    return not awaiting.is_last_commenter_owner and not awaiting.last_actor_is_bot


def _section(title: str, lines: list[str]) -> str:
    return f"{title}\n{_RULE}\n" + ("".join(lines) if lines else "  (none)\n") + "\n"


def render_report(cfg, deltas, notifications, attention, coverage, banner, date_str):
    """Build the plain-text daily report. Returns (subject, body).

    Every rendered field is already redacted upstream; the whole body is passed
    through redact() again as a belt-and-suspenders final pass.
    """
    new_deltas = [d for d in deltas if d.change == "new"]
    reopened_deltas = [d for d in deltas if d.change == "reopened"]
    comment_deltas = [d for d in deltas if d.change == "new_comment"]
    stale_deltas = [d for d in deltas if d.change == "stale"]

    n_new = len(new_deltas)
    n_await = sum(1 for d in deltas if _awaiting_owner(d.awaiting))
    n_serious = sum(1 for a in attention if a.severity == "serious")

    subject = (f"[oss-secretary] {date_str} — "
               f"{n_new} new · {n_await} awaiting reply · {n_serious} serious")

    url_by_id = {item_id(d.thread): d.thread.html_url for d in deltas}

    parts: list[str] = []
    if banner:
        parts.append(f"! {banner}\n\n")

    # §1 Needs your attention
    att_lines = []
    for a in attention:
        att_lines.append(f"  [{a.severity}] {a.id} — {a.one_line}\n")
        url = url_by_id.get(a.id)
        if url:
            att_lines.append(f"      {url}\n")
    parts.append(_section("Needs your attention", att_lines))

    # §2 New issues / PRs — grouped by repo (host-tagged)
    parts.append(_section("New issues / PRs", _group_by_repo(new_deltas + reopened_deltas)))

    # §3 New comments on existing threads
    comment_lines = []
    for d in comment_deltas:
        t = d.thread
        comment_lines.append(
            f"  {item_id(t)} — {t.title}\n"
            f"      last comment by {t.last_commenter or 'unknown'}"
            f" · {t.comment_count} comments · {t.html_url}\n")
    parts.append(_section("New comments on existing threads", comment_lines))

    # §4 Elsewhere (notifications) — grouped by repo
    notif_groups: OrderedDict[str, list] = OrderedDict()
    for n in notifications:
        notif_groups.setdefault(n.repo_full_name, []).append(n)
    notif_lines = []
    for repo, items in notif_groups.items():
        notif_lines.append(f"  {repo} [{items[0].platform}]\n")
        for n in items:
            reason = f" ({n.reason})" if n.reason else ""
            notif_lines.append(f"      {n.subject_type}: {n.subject_title}{reason}\n")
    parts.append(_section("Elsewhere (notifications)", notif_lines))

    # §5 Quiet / stale — collapsed
    if stale_deltas:
        parts.append(_section(
            f"Quiet / stale ({len(stale_deltas)})",
            [f"  {item_id(d.thread)} — {d.thread.title}\n" for d in stale_deltas]))

    # §6 Coverage footer
    errored = ""
    if coverage.errored_repos:
        errored = "  errored repos: " + ", ".join(coverage.errored_repos) + "\n"
    cov_lines = [
        f"  repos scanned: {coverage.repos_scanned}, errored: {coverage.repos_errored}\n",
        errored,
        f"  items to triage: {coverage.items_to_triage}, omitted: {coverage.items_omitted}\n",
        f"  LLM: {coverage.llm_status}\n",
        f"  run duration: {coverage.duration_s}s\n",
    ]
    parts.append(_section("Coverage", [ln for ln in cov_lines if ln]))

    body = redact("".join(parts))
    return subject, body


def _group_by_repo(deltas) -> list[str]:
    groups: OrderedDict[str, list] = OrderedDict()
    for d in deltas:
        groups.setdefault(d.thread.repo_full_name, []).append(d)
    lines = []
    for repo, items in groups.items():
        lines.append(f"  {repo} [{items[0].thread.platform}]\n")
        for d in items:
            t = d.thread
            reopened = " (reopened)" if d.change == "reopened" else ""
            lines.append(f"      #{t.number} ({t.kind}){reopened} {t.title} · {t.html_url}\n")
    return lines


def render_baseline(cfg, gh_count, gitea_count, date_str):
    """First-run message: no per-item report, just the seeded counts."""
    subject = f"[oss-secretary] {date_str} — baseline established"
    body = redact(
        f"Baseline established: {gh_count} GitHub and {gitea_count} Gitea open "
        "threads recorded on the first run.\n\n"
        "No per-item report today — future runs will report only what changes "
        "against this baseline.\n")
    return subject, body


def build_message(subject: str, body: str, sender: str, recipient: str) -> bytes:
    """RFC 822 message with 8bit text/plain UTF-8 (preserves em-dash/`·`/`=`).

    Headers are encoded UTF-8 (not ASCII) because the subject legitimately
    carries non-ASCII separators; the 8BITMIME transport + 8bit CTE already
    declared make raw UTF-8 headers safe for local delivery.
    """
    headers = (
        f"Subject: {subject}\r\n"
        f"From: {sender}\r\n"
        f"To: {recipient}\r\n"
        "Auto-Submitted: auto-generated\r\n"
        "X-OSS-Secretary: daily\r\n"
        "MIME-Version: 1.0\r\n"
        'Content-Type: text/plain; charset="utf-8"\r\n'
        "Content-Transfer-Encoding: 8bit\r\n"
        "\r\n"
    )
    return headers.encode("utf-8") + body.encode("utf-8")


def deliver(raw: bytes, cfg) -> int:
    """Deliver a pre-built raw message. Dry-run prints to stdout and returns 0."""
    if cfg.dry_run:
        sys.stdout.write(raw.decode("utf-8"))
        sys.stdout.write("\n")
        return 0
    if not os.path.isfile(cfg.sendmail):
        sys.stderr.write(f"sendmail not found at {cfg.sendmail}\n")
        return 2
    try:
        proc = subprocess.run(
            [cfg.sendmail, "-i", "-B", "8BITMIME", "-f", cfg.sender, cfg.recipient],
            input=raw, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        sys.stderr.write(f"sendmail failed: {type(exc).__name__}\n")
        return 3
    return proc.returncode
