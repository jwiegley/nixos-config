from __future__ import annotations
import html
import logging
import os
import re
import subprocess
import sys
from collections import OrderedDict
from dataclasses import dataclass, field
from email import policy
from email.message import EmailMessage
from urllib.parse import urlsplit, urlunsplit
from .delta import item_id
from .redact import redact

log = logging.getLogger("oss_secretary")

_RULE = "=" * 60


# ---------------------------------------------------------------------------
# Shared row model
#
# ONE traversal of the data (build_sections) produces these values; _text_body
# and _html_body are pure functions over them. Neither mail part is authored
# independently, so a section, field, or link added later is added to both by
# construction. test_plain_and_html_link_the_same_urls turns that structural
# property into a build-gate invariant.
# ---------------------------------------------------------------------------
@dataclass
class Row:
    text: str                    # primary label, RAW; the ANCHOR text when url is set
    url: str | None = None       # ALWAYS a safe_href() return value, or None
    pre: str = ""                # RAW, rendered BEFORE text and never inside the anchor
    post: str = ""               # RAW, rendered AFTER text and never inside the anchor
    sub: str = ""                # optional secondary line, RAW
    bad_url: str | None = None   # raw value that failed safe_href, for display
    place: str = "suffix"        # PLAIN-TEXT ONLY: suffix | own_line | sub_suffix
    heading: bool = False        # repo group heading (<h3>) rather than an item
    indent: int = 6              # plain-text indent


@dataclass
class Section:
    title: str
    rows: list[Row] = field(default_factory=list)


def _awaiting_owner(awaiting) -> bool:
    """A thread awaits John's reply when the last human comment was not his and
    he has not already responded in the thread."""
    return (not awaiting.is_last_commenter_owner
            and not awaiting.last_actor_is_bot
            and not awaiting.has_owner_response)


def _section(title: str, lines: list[str]) -> str:
    return f"{title}\n{_RULE}\n" + ("".join(lines) if lines else "  (none)\n") + "\n"


# --------------------------- escaping / URL safety -------------------------
def _esc(s) -> str:
    """Redact FIRST, then HTML-escape. The only door untrusted text uses.

    The order is load-bearing, not stylistic. redact.py's generic
    ``(token|password|...|access_token)=[^\\s&"]+`` value class permits ``<``
    and ``'`` but TERMINATES on ``&`` -- and html.escape injects an ``&`` at
    exactly the character where the class would have kept matching. Measured
    against the live redact():

        escape-first  redact(escape("password=hunter2'sTail"))
                      -> "[REDACTED]&#x27;sTail"      leaks the tail
        redact-first  escape(redact("password=hunter2'sTail"))
                      -> "[REDACTED]"

    Worse, when a value STARTS with ``<`` the first character becomes ``&``,
    the class cannot match at all, and escape-first redacts NOTHING:
    ``redact(escape("psk=<abc>")) == "psk=&lt;abc&gt;"``.

    html.escape("[REDACTED]") == "[REDACTED]" and redact() is idempotent, so
    redact-then-escape is lossless in the other direction. Do not "simplify"
    this by swapping the two calls.
    """
    return html.escape(redact("" if s is None else str(s)), quote=True)


# Any byte <= 0x20 or 0x7f. urlsplit strips leading whitespace, leading C0
# controls, and EMBEDDED tab/LF/CR before scheme detection -- so "java\tscript:"
# parses as scheme "javascript" and the allowlist would catch it anyway -- but
# it does NOT strip trailing whitespace, and "https://exa mple.com/x" parses
# with a space in the netloc. A real GitHub/Gitea html_url never contains a
# control character, so blanket rejection is smaller and more obviously correct
# than reasoning about which normalizations apply where.
_CTRL = re.compile(r"[\x00-\x20\x7f]")


def safe_href(u) -> str | None:
    """Normalized http(s) URL safe for an href, or None meaning 'render as text'.

    Returning None must NEVER drop the item -- callers fall back to a derived
    URL, then to inert escaped text (see thread_url and Row.bad_url).
    """
    if not u:
        return None
    u = str(u)
    if _CTRL.search(u):
        return None
    try:
        p = urlsplit(u)
        if p.scheme not in ("http", "https"):
            return None
        if not p.netloc:
            return None
        # Reject userinfo rather than redact it: redacting inside an attribute
        # produces the live dead link href="[REDACTED]github.com/o/r".
        if p.username or p.password:
            return None
        out = urlunsplit(p)
    except ValueError:
        # urlsplit RAISES on a malformed authority: urlsplit("http://[evil")
        # -> ValueError("Invalid IPv6 URL"). Uncaught, that would propagate
        # through render_report to report.main()'s top-level handler, which
        # rolls back state and returns 1 -- NO EMAIL THAT DAY. And because
        # html_url is a persisted column rehydrated for the stale section, a
        # poisoned row would repeat the failure every morning until someone
        # hand-edited SQLite. Accessing p.port raises the same way; nothing
        # here touches it, but keep any future field access inside this try.
        return None
    if redact(out) != out:
        # A URL that passes the scheme allowlist can still CARRY a secret
        # (?access_token=...). html.escape does not redact. Linking it would
        # hide it in the plain part (whole-body redact) while exposing it
        # verbatim in the href. Refuse the link; the text path redacts it.
        return None
    return out


# ".." is checked explicitly by repo_url: _REPO permits "." because real repo
# names contain it, so the character class alone does NOT exclude "../..".
_REPO = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\Z")
_DIGITS = re.compile(r"\A[0-9]{1,20}\Z")


def gitea_web_base(cfg) -> str:
    """Gitea's WEB base, derived by stripping the API suffix off gitea_url."""
    u = (getattr(cfg, "gitea_url", "") or "").rstrip("/")
    return u[: -len("/api/v1")] if u.endswith("/api/v1") else u


def repo_url(cfg, platform: str, full_name: str) -> str | None:
    """Web URL for a repo. THE ONLY INVENTED URL IN THIS MODULE.

    render_report never receives Repo objects (report.py discards them and the
    grouping keys off the repo_full_name string), so Repo.html_url is
    unreachable without new plumbing. Every constructed URL is fed back through
    safe_href, so a misconfigured Gitea base yields None -- an unlinked heading
    -- rather than a fabricated link. Item links are unaffected either way:
    they use the API's own html_url.
    """
    if not full_name or ".." in full_name or not _REPO.match(full_name):
        return None
    if platform == "github":
        return safe_href(f"https://github.com/{full_name}")
    base = gitea_web_base(cfg)
    return safe_href(f"{base}/{full_name}") if base else None


def thread_url(cfg, t) -> str | None:
    """API html_url when usable, else a derived one, else None.

    The fallback fires on REJECTED urls, not only empty ones: a javascript: or
    credential-bearing html_url is exactly the hostile class that must not
    silently lose its link when repo + kind + number reconstructs a good one.
    """
    direct = safe_href(t.html_url)
    if direct:
        return direct
    base = repo_url(cfg, t.platform, t.repo_full_name)
    if not base or not isinstance(t.number, int):
        return None
    seg = ("pulls" if t.platform == "gitea" else "pull") if t.kind == "pr" else "issues"
    return safe_href(f"{base}/{seg}/{t.number}")


def comment_url(thread_href: str | None, last_comment_id) -> str | None:
    """Deep-link to the new comment when its id is known, else the thread top.

    Both platforms use the #issuecomment-<id> fragment. An unrecognised
    fragment is ignored by the browser, so the worst case is landing at the
    top of the thread the reader wanted anyway.
    """
    if not thread_href or not last_comment_id:
        return thread_href
    if not _DIGITS.match(str(last_comment_id)):
        return thread_href
    return safe_href(f"{thread_href}#issuecomment-{last_comment_id}") or thread_href


def _bad(url: str | None, raw) -> str | None:
    """The raw value to surface as '(unlinkable url: ...)'.

    Only when the row ended up with NO link at all: the marker exists to
    explain a missing link, and a derived fallback means nothing is missing.
    """
    return None if url or not raw else str(raw)


def _group(items, key):
    groups: OrderedDict = OrderedDict()
    for it in items:
        groups.setdefault(key(it), []).append(it)
    return groups.items()


# ------------------------------- traversal --------------------------------
def build_sections(cfg, deltas, notifications, attention, coverage, date_str,
                   stale) -> tuple[str, list[Section]]:
    """The single traversal. Returns (subject, sections).

    ALL URL resolution happens here, and Row.url is only ever assigned from a
    safe_href() return value (pinned by test_row_urls_are_always_safe_href_output).
    Row.place affects the plain part's LAYOUT only; the URL itself is shared,
    which is what makes the parity test meaningful.
    """
    new_deltas = [d for d in deltas if d.change == "new"]
    reopened_deltas = [d for d in deltas if d.change == "reopened"]
    comment_deltas = [d for d in deltas if d.change == "new_comment"]

    n_new = len(new_deltas)
    n_await = sum(1 for d in deltas if _awaiting_owner(d.awaiting))
    n_serious = sum(1 for a in attention if a.severity == "serious")
    subject = (f"[oss-secretary] {date_str} — "
               f"{n_new} new · {n_await} awaiting reply · {n_serious} serious")

    thread_by_id = {item_id(d.thread): d.thread for d in deltas}
    sections: list[Section] = []

    # §1 Needs your attention. The anchor is the ID, never the one_line: that
    # field is LLM-generated from third-party issue text and is the most
    # attacker-influenceable string in the mail. Keeping it out of anchor
    # position denies an attacker control of hyperlink text.
    #
    # place="own_line" keeps this section byte-identical to the old plain text:
    # folding the URL onto the label line would produce a ~100-column line that
    # wraps mid-URL in an 80-column reader.
    att_rows = []
    for a in attention:
        t = thread_by_id.get(a.id)
        url = thread_url(cfg, t) if t is not None else None
        att_rows.append(Row(a.id, url=url, pre=f"[{a.severity}] ",
                            post=f" — {a.one_line}",
                            bad_url=_bad(url, getattr(t, "html_url", None)),
                            place="own_line", indent=2))
    sections.append(Section("Needs your attention", att_rows))

    # §2 New issues / PRs — grouped by (platform, repo). The platform is part
    # of the key because a repo name present on BOTH hosts would otherwise
    # merge into one group that takes its platform tag from items[0] — a
    # harmless mislabel until headings became links, at which point it would
    # send the heading to the wrong server.
    rows: list[Row] = []
    for (platform, repo), items in _group(
            new_deltas + reopened_deltas,
            lambda d: (d.thread.platform, d.thread.repo_full_name)):
        rows.append(Row(f"{repo} [{platform}]", url=repo_url(cfg, platform, repo),
                        heading=True, indent=2))
        for d in items:
            t = d.thread
            reopened = " (reopened)" if d.change == "reopened" else ""
            url = thread_url(cfg, t)
            rows.append(Row(f"#{t.number} ({t.kind}){reopened} {t.title}", url=url,
                            bad_url=_bad(url, t.html_url), indent=6))
    sections.append(Section("New issues / PRs", rows))

    # §3 New comments on existing threads. The section is literally named "New
    # comments", so the referenced thing is the comment: deep-link to it when
    # report._enrich populated last_comment_id.
    rows = []
    for d in comment_deltas:
        t = d.thread
        url = comment_url(thread_url(cfg, t), t.last_comment_id)
        rows.append(Row(f"{item_id(t)} — {t.title}", url=url,
                        sub=(f"last comment by {t.last_commenter or 'unknown'}"
                             f" · {t.comment_count} comments"),
                        bad_url=_bad(url, t.html_url),
                        place="sub_suffix", indent=2))
    sections.append(Section("New comments on existing threads", rows))

    # §4 Elsewhere (notifications). NotificationItem carries no number, so
    # there is nothing to derive from when html_url is missing or rejected —
    # the item degrades to text and the repo heading above it stays linked.
    rows = []
    for (platform, repo), items in _group(
            notifications, lambda n: (n.platform, n.repo_full_name)):
        rows.append(Row(f"{repo} [{platform}]", url=repo_url(cfg, platform, repo),
                        heading=True, indent=2))
        for n in items:
            reason = f" ({n.reason})" if n.reason else ""
            url = safe_href(n.html_url)
            rows.append(Row(f"{n.subject_type}: {n.subject_title}{reason}", url=url,
                            bad_url=_bad(url, n.html_url), indent=6))
    sections.append(Section("Elsewhere (notifications)", rows))

    # §5 Quiet / stale. html_url is a persisted column rehydrated by
    # delta._thread_from_row; rows stored with an empty one hit the derived
    # fallback. No comment deep-link: last_comment_id is written to SQLite
    # BEFORE _enrich populates it, so the column is always NULL — immaterial,
    # since a stale thread has no new comment to point at.
    if stale:
        rows = []
        for d in stale:
            t = d.thread
            url = thread_url(cfg, t)
            rows.append(Row(f"{item_id(t)} — {t.title}", url=url,
                            bad_url=_bad(url, t.html_url), indent=2))
        sections.append(Section(f"Quiet / stale ({len(stale)})", rows))

    # §6 Coverage footer. errored_repo_urls carries the AUTHORITATIVE
    # Repo.html_url captured in report._collect's per-repo except block, so
    # these need no derivation and are unambiguous between hosts (a bare
    # `owner/name` is not — the same name can exist on GitHub and Gitea).
    cov_rows = [Row(f"repos scanned: {coverage.repos_scanned}, "
                    f"errored: {coverage.repos_errored}", indent=2)]
    if coverage.errored_repos:
        cov_rows.append(Row("errored repos:", heading=True, indent=2))
        errored_urls = getattr(coverage, "errored_repo_urls", None) or {}
        for name in coverage.errored_repos:
            raw = errored_urls.get(name)
            url = safe_href(raw)
            cov_rows.append(Row(name, url=url, bad_url=_bad(url, raw), indent=6))
    cov_rows += [
        Row(f"items to triage: {coverage.items_to_triage}, "
            f"omitted: {coverage.items_omitted}", indent=2),
        Row(f"LLM: {coverage.llm_status}", indent=2),
        Row(f"run duration: {coverage.duration_s}s", indent=2),
    ]
    sections.append(Section("Coverage", cov_rows))

    return subject, sections


# ---------------------------- formatter: text ------------------------------
def _text_row(r: Row) -> str:
    out = " " * r.indent + r.pre + r.text + r.post
    if r.url and r.place == "suffix":
        out += f" · {r.url}"
    if r.bad_url:
        out += f" · (unlinkable url: {r.bad_url})"
    out += "\n"
    if r.sub:
        sub = "      " + r.sub
        if r.url and r.place == "sub_suffix":
            sub += f" · {r.url}"
        out += sub + "\n"
    if r.url and r.place == "own_line":
        out += f"      {r.url}\n"
    return out


def _text_body(banner, sections) -> str:
    """The plain part KEEPS its whole-body redact() pass.

    Dropping it would be a regression: last_commenter, html_url,
    repo_full_name, NotificationItem.reason, Coverage.errored_repos and the
    banner are NOT redacted upstream — only title, body_excerpt, subject_title
    and one_line are. The HTML part cannot have this pass (redact() over
    assembled markup produces dead links and eats tags), so it gets per-field
    equivalence through _esc instead.
    """
    parts: list[str] = []
    if banner:
        parts.append(f"! {banner}\n\n")
    for s in sections:
        parts.append(_section(s.title, [_text_row(r) for r in s.rows]))
    return redact("".join(parts))


# ---------------------------- formatter: html ------------------------------
# Zero interpolation, and no remote resources of any kind: no <img>, no
# <script>, no @import, no url(), no web fonts. html.escape is NO defence
# inside a raw-text element, so <style> must never carry data and <script>
# must never exist. Styling is class-based, so the dark override needs no
# !important, and no element carries a style= attribute.
_CSS = (
    "body{font:14px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,"
    "sans-serif;color:#1a1a1a;background:#fff;margin:0;padding:1em;max-width:46em}"
    "h1{font-size:1.1em;font-weight:600;margin:0 0 1em}"
    "h2{font-size:.95em;text-transform:uppercase;letter-spacing:.06em;"
    "border-bottom:1px solid #d5d5d5;padding-bottom:.2em;margin:1.7em 0 .4em}"
    "h3{font-size:.95em;font-weight:600;margin:.9em 0 .2em}"
    "ul{margin:.2em 0 .2em 1.15em;padding:0}li{margin:.35em 0}"
    ".sub{color:#666;font-size:.9em}"
    ".none{color:#888;font-style:italic}"
    ".banner{font-weight:600}"
    "a{color:#0b5fa5}"
    "@media(prefers-color-scheme:dark){body{background:#1b1b1b;color:#e8e8e8}"
    "h2{border-color:#3a3a3a}.sub{color:#9a9a9a}a{color:#7fb3e8}}"
)


def _html_label(r: Row) -> str:
    """The escaped, optionally-anchored content of one row.

    r.url is already a safe_href() output; html.escape(quote=True) is exactly
    right for a double-quoted attribute value (?a=1&b=2 -> ?a=1&amp;b=2, which
    the client decodes back). Takes no style= or cls= parameter on purpose: an
    earlier prototype's link(url, label, style, cls) shape interpolated those
    into attributes unescaped, which is safe only for as long as every caller
    happens to pass a constant.
    """
    label = _esc(r.text)
    if r.url:
        label = f'<a href="{html.escape(r.url, quote=True)}">{label}</a>'
    # pre/post stay OUTSIDE the anchor: §1's one_line is LLM-generated from
    # third-party issue text, and hyperlink text an attacker controls is a
    # phishing primitive that inert body text is not.
    label = _esc(r.pre) + label + _esc(r.post)
    if r.bad_url:
        label += f' <span class="sub">(unlinkable url: {_esc(r.bad_url)})</span>'
    if r.sub:
        # A real block element, NOT a <span class="sub"> with display:block.
        # CSS may style, never structure: in any client that strips <style>,
        # the span form runs this metadata into the title on one line.
        label += f'<div class="sub">{_esc(r.sub)}</div>'
    return label


def _html_row(r: Row) -> str:
    return f"<li>{_html_label(r)}</li>"


def _html_document(subject: str, inner: list[str]) -> str:
    return ("<!DOCTYPE html>\n"
            '<html lang="en"><head><meta charset="utf-8">'
            '<meta name="color-scheme" content="light dark">'
            f"<style>{_CSS}</style></head><body>"
            f"<h1>{_esc(subject)}</h1>"
            + "".join(inner) +
            "</body></html>")


def _html_body(subject, banner, sections) -> str:
    inner: list[str] = []
    if banner:
        inner.append(f'<p class="banner">{_esc(banner)}</p>')
    for s in sections:
        inner.append(f"<h2>{_esc(s.title)}</h2>")
        if not s.rows:
            inner.append('<p class="none">(none)</p>')
            continue
        open_ul = False
        for r in s.rows:
            if r.heading:
                if open_ul:
                    inner.append("</ul>")
                    open_ul = False
                inner.append(f"<h3>{_html_label(r)}</h3>")
                continue
            if not open_ul:
                inner.append("<ul>")
                open_ul = True
            inner.append(_html_row(r))
        if open_ul:
            inner.append("</ul>")
    return _html_document(subject, inner)


def _baseline_html(subject, line1, line2) -> str:
    return _html_document(subject, [f"<p>{_esc(line1)}</p>", f"<p>{_esc(line2)}</p>"])


def _safe_html(cfg, fn, *a, **kw):
    """Render the HTML alternative, or None. The plain part is the contract.

    An HTML bug must never cost the daily mail. Accepted downside: a persistent
    failure produces plain-text mail with only a journal line and does not fail
    the unit, so monitoring will not notice — the test suite covering the HTML
    path is the compensating control. getattr(cfg, "html", True) is defensive
    so a Config built without the field (a stale factory, a REPL stub) works.
    """
    if not getattr(cfg, "html", True):
        return None
    try:
        return fn(*a, **kw)
    except Exception as exc:
        # Exception TYPE only -- the payload is third-party text.
        log.error("HTML render failed (%s); sending text/plain only",
                  type(exc).__name__)
        return None


# ------------------------------ entry points -------------------------------
def render_report(cfg, deltas, notifications, attention, coverage, banner, date_str,
                  stale=None):
    """Build the daily report. Returns (subject, text_body, html_body).

    ``deltas`` are the new/new_comment/reopened items; ``stale`` (computed by a
    separate pass over the stored open inventory) feeds §5 only. Both bodies
    come from ONE traversal (build_sections) so they cannot diverge.
    ``html_body`` is None when cfg.html is false or the HTML render raised.
    """
    subject, sections = build_sections(cfg, deltas, notifications, attention,
                                       coverage, date_str, stale or [])
    body = _text_body(banner, sections)
    return subject, body, _safe_html(cfg, _html_body, subject, banner, sections)


def render_baseline(cfg, gh_count, gitea_count, date_str):
    """First-run message: no per-item report, just the seeded counts.

    Returns three values like render_report so the caller's arity is uniform.
    There are no items, therefore no anchors — asserted by a test.
    """
    subject = f"[oss-secretary] {date_str} — baseline established"
    line1 = (f"Baseline established: {gh_count} GitHub and {gitea_count} Gitea open "
             "threads recorded on the first run.")
    line2 = ("No per-item report today — future runs will report only what changes "
             "against this baseline.")
    body = redact(f"{line1}\n\n{line2}\n")
    return subject, body, _safe_html(cfg, _baseline_html, subject, line1, line2)


def build_message(subject: str, body: str, sender: str, recipient: str,
                  html_body: str | None = None) -> bytes:
    """RFC 5322 message: text/plain, plus a text/html alternative when given.

    multipart/alternative with text/plain FIRST and text/html LAST: RFC 2046
    §5.1.4 is MUST for composers ("in increasing order of preference... with
    the preferred format last") and receivers display the last format they can
    render. add_alternative APPENDS, so the ordering is free.

    Header encoding is UNCHANGED from the hand-rolled version this replaces:
    policy.SMTPUTF8 emits raw UTF-8 headers, so the Subject's em-dash and `·`
    go out as the same bytes they always have. Be clear about what that
    preserves: RFC 6152 (8BITMIME) scopes the message BODY only, so non-ASCII
    HEADERS additionally require RFC 6532 plus the SMTPUTF8 extension (RFC
    6531), and this host has `postconf smtputf8_enable` = no. Today's messages
    are non-conformant and merely tolerated because delivery is entirely local
    (local_transport = lmtp:unix:/var/run/dovecot2/lmtp). policy.SMTP would
    RFC 2047-encode the Subject and is strictly more correct, but it changes
    what lands in the mailbox, what dry-run prints, and what any
    Subject-matching filter sees -- and nothing currently tests a non-ASCII
    subject, so a regression would be silent. Deferred to its own commit.

    CTE, plain part: 8bit, passed EXPLICITLY. set_content()'s heuristic keys
    off policy.max_line_length (78), not ASCII-ness, and on the real rendered
    body it selects BASE64 -- the `"="*60` section rules make quoted-printable
    expensive, so base64 wins. Omitting cte= silently makes the plain part
    unreadable in any spool, mbox, or dry-run view. Measured, not guessed.

    CTE, html part: quoted-printable. Forced 8bit performs NO line wrapping; a
    realistic 30-item digest is one ~12.5 kB physical line, past RFC 5321's 998
    limit and past this host's `postconf line_length_limit` = 2048, where
    Postfix would break it mid-tag. QP folds at 78 by construction.

    Two honest notes: body line endings become CRLF (more correct on the wire,
    invisible in any MUA), and part.get_content() appends a trailing newline on
    round-trip, so "byte-identical round-trip" is false as stated.
    """
    msg = EmailMessage(policy=policy.SMTPUTF8)
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = recipient
    msg["Auto-Submitted"] = "auto-generated"
    msg["X-OSS-Secretary"] = "daily"
    msg.set_content(body, subtype="plain", charset="utf-8", cte="8bit")
    if html_body:
        # add_alternative also emits a redundant MIME-Version inside the
        # text/html subpart; MIME-Version is only meaningful at top level and
        # every client ignores it. Harmless -- do not "fix" it.
        msg.add_alternative(html_body, subtype="html", charset="utf-8",
                            cte="quoted-printable")
    return msg.as_bytes(policy=policy.SMTPUTF8)


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
