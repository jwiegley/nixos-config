from html.parser import HTMLParser
from email import policy, message_from_bytes

from oss_secretary.render import (render_report, render_baseline, build_message,
                                  deliver, build_sections, safe_href, repo_url,
                                  thread_url, comment_url, _esc, _CSS)
from oss_secretary.models import (Coverage, AttentionItem, NotificationItem,
                                  Thread, ThreadDelta, AwaitingBundle)
from oss_secretary.redact import redact
from oss_secretary.delta import compute_deltas
from tests.test_delta import _t, OWNERS
from tests.test_github import _cfg


def test_subject_and_sections_present():
    from oss_secretary.models import ThreadDelta, AwaitingBundle
    d = ThreadDelta(_t(), "new", AwaitingBundle(False, False, False, 1.0, "NONE"))
    att = [AttentionItem("gh:jwiegley/foo#3", "serious", "crash on startup")]
    subject, body, _html = render_report(_cfg(), [d], [], att, Coverage(repos_scanned=2),
                                         banner=None, date_str="2026-07-22")
    assert subject.startswith("[oss-secretary] 2026-07-22")
    assert "Needs your attention" in body and "crash on startup" in body
    assert "Coverage" in body


def test_baseline_message_has_no_per_item():
    subject, body, _html = render_baseline(_cfg(), 10, 5, "2026-07-22")
    assert "baseline established" in body.lower() and "10" in body and "5" in body


def test_deliver_dry_run(capsys):
    cfg = _cfg(dry_run=True)
    raw = build_message("[oss-secretary] test", "hello", cfg.sender, cfg.recipient)
    assert deliver(raw, cfg) == 0
    assert "Subject: [oss-secretary] test" in capsys.readouterr().out


# ===========================================================================
# HTML alternative part
# ===========================================================================
AW = AwaitingBundle(False, False, False, 1.0, "NONE")
GH42 = "https://github.com/jwiegley/ledger/issues/42"
GH43 = "https://github.com/jwiegley/ledger/pull/43"
GH99 = "https://github.com/jwiegley/ledger/issues/99"
GITEA7 = "https://gitea.vulcan.lan/johnw/priv/issues/7"
NOTIF = "https://github.com/ledger/ledger/issues/7"
BAD_REPO = "https://github.com/jwiegley/bad"
HOSTILE = '<img src=x onerror="alert(1)"> & "q" \'a\' </style><script>x</script>'
# Synthetic, never-real credential SHAPES. Their whole purpose is to prove the
# redaction path fires, so nothing here is or resembles a live secret.
SECRET_TAIL = "password=hunter2'sTail"
TOKEN_SHAPE = "ghp_abcdef1234567890"


def _cfgh(**kw):
    kw.setdefault("gitea_url", "https://gitea.vulcan.lan/api/v1")
    return _cfg(**kw)


def _thread(**kw):
    d = dict(platform="github", node_id="I_1", repo_full_name="jwiegley/ledger",
             number=42, kind="issue", title="crash on startup", html_url=GH42,
             state="open", closed_at=None, comment_count=3, last_comment_id=None,
             last_comment_at=None, last_commenter="alice",
             last_commenter_is_bot=False, author_association="NONE",
             updated_at="2026-07-25T00:00:00Z")
    d.update(kw)
    return Thread(**d)


class _Audit(HTMLParser):
    """Parser-based auditor. A naive regex is WRONG here: re.search(r'src=')
    false-positives on the correctly-escaped hostile title `&lt;img src=x`,
    which contains that literal substring as character data. A parser tells an
    attribute apart from a character sequence.

    convert_charrefs=False so text nodes keep their entity references intact:
    with the default True, `&lt;img` is handed back as `<img` and the
    "no markup leaked into text" assertion cannot be expressed. Attribute
    values are unescaped either way (parse_starttag always calls unescape),
    so an href written as `&amp;` comes back as `&`.
    """

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.tags, self.attrs, self.hrefs, self.text, self.style = [], [], [], [], []
        self._in_style = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append(tag)
        self.attrs.extend(attrs)
        self._in_style = tag == "style"
        if tag == "a" and "href" in a:
            self.hrefs.append(a["href"])

    def handle_endtag(self, tag):
        if tag == "style":
            self._in_style = False

    def handle_data(self, data):
        (self.style if self._in_style else self.text).append(data)


def _audit(doc):
    p = _Audit()
    p.feed(doc)
    return p


def _render(**kw):
    args = dict(cfg=_cfgh(), deltas=[], notifications=[], attention=[],
                coverage=Coverage(repos_scanned=1), banner=None, stale=None)
    args.update(kw)
    return render_report(args["cfg"], args["deltas"], args["notifications"],
                         args["attention"], args["coverage"], args["banner"],
                         "2026-07-27", args["stale"])


def _all_sections():
    """One fixture populating §1-§6 plus a Gitea repo. Ten linkable items."""
    deltas = [
        ThreadDelta(_thread(), "new", AW),
        ThreadDelta(_thread(platform="gitea", node_id="G_7",
                            repo_full_name="johnw/priv", number=7,
                            title="gitea thing", html_url=GITEA7), "new", AW),
        ThreadDelta(_thread(node_id="I_2", number=43, kind="pr", title="fix it",
                            html_url=GH43, last_comment_id="12345"),
                    "new_comment", AW),
    ]
    stale = [ThreadDelta(_thread(node_id="I_9", number=99, title="forgotten",
                                 html_url=GH99), "stale", AW)]
    notifs = [NotificationItem("github", "ledger/ledger", "Issue", "upstream ping",
                               "mention", NOTIF, "2026-07-25T00:00:00Z", True)]
    att = [AttentionItem("gh:jwiegley/ledger#42", "serious", "segfault")]
    cov = Coverage(repos_scanned=3, repos_errored=1, errored_repos=["jwiegley/bad"])
    cov.errored_repo_urls["jwiegley/bad"] = BAD_REPO
    return dict(deltas=deltas, notifications=notifs, attention=att, coverage=cov,
                stale=stale)


# ------------------------------ adversarial --------------------------------
def test_safe_href_rejects_hostile_urls():
    hostile = [
        "javascript:alert(1)", "JaVaScRiPt:alert(1)", "  javascript:alert(1)",
        "java\tscript:alert(1)", "java\nscript:alert(1)", "\x01javascript:alert(1)",
        "data:text/html,<script>", "vbscript:x", "//evil.example/x",
        "http:", "https://", "", None, "u",
        "https://u:p@evil.example/x",
        "https://ok.example/a\nX-Injected: 1",
        "  https://ok.example/a  ",
        f"https://github.com/o/r/issues/1?access_token={TOKEN_SHAPE}",
        # The three bracket cases are the regression guard for the ValueError
        # that would otherwise propagate to report.main(), roll back state, and
        # lose the whole day's mail.
        "http://[evil", "https://[::1", "https://[abc",
        "https://exa mple.com/x",
    ]
    assert len(hostile) == 22
    for u in hostile:
        assert safe_href(u) is None, u          # and, by getting here, no raise


def test_safe_href_accepts_and_normalizes():
    assert safe_href(GH42) == GH42
    assert safe_href("http://gitea.vulcan.lan/o/r") == "http://gitea.vulcan.lan/o/r"
    assert safe_href("https://ok.example/?a=1&b=2") == "https://ok.example/?a=1&b=2"
    assert safe_href("HTTPS://GitHub.com/O/R") == "https://GitHub.com/O/R"
    deep = f"{GH42}#issuecomment-12345"
    assert safe_href(deep) == deep


def test_redact_runs_before_escape():
    # Escape-first would yield "[REDACTED]&#x27;sTail", "[REDACTED]&lt;ret&gt;value",
    # and -- for the third -- "api_key=&lt;wholly-bracketed&gt;" with NO redaction
    # at all, because escaping turns the value's leading "<" into "&" and the
    # generic pattern's value class terminates on "&". This test is the guard
    # against someone "simplifying" _esc by swapping the two calls.
    assert _esc(SECRET_TAIL) == "[REDACTED]"
    assert _esc("api_key=sec<ret>value") == "[REDACTED]"
    assert _esc("api_key=<wholly-bracketed>") == "[REDACTED]"


def test_hostile_title_is_inert_text():
    d = ThreadDelta(_thread(title=HOSTILE), "new", AW)
    _s, text, doc = _render(deltas=[d])
    au = _audit(doc)
    assert "img" not in au.tags and "script" not in au.tags and "iframe" not in au.tags
    assert not [n for n, _v in au.attrs if n.startswith("on")]
    assert "&lt;img src=x" in doc and "<img src=x" not in doc
    assert HOSTILE in text                       # plain part unchanged, no regression


def test_javascript_url_never_becomes_an_href():
    # A NotificationItem, not a Thread: notifications carry no number, so there
    # is nothing to derive from and this really does reach the inert-text step.
    n = NotificationItem("github", "ledger/ledger", "Issue", "upstream ping",
                         "mention", "javascript:alert(1)", "2026-07-25T00:00:00Z", True)
    _s, text, doc = _render(notifications=[n])
    assert 'href="javascript:' not in doc
    assert all(h.startswith(("http://", "https://")) for h in _audit(doc).hrefs)
    assert "upstream ping" in doc and "upstream ping" in text
    for part in (doc, text):
        assert "(unlinkable url: javascript:alert(1))" in part


def test_secret_shaped_llm_line_is_redacted_in_both_parts():
    # one_line is LLM-generated from third-party issue text: the highest-risk
    # string in the mail.
    att = [AttentionItem("gh:jwiegley/ledger#42", "serious", f"leaks {SECRET_TAIL} here")]
    d = ThreadDelta(_thread(), "new", AW)
    _s, text, doc = _render(deltas=[d], attention=att)
    assert "hunter2" not in doc and "hunter2" not in text
    assert "[REDACTED]" in doc and "[REDACTED]" in text


def test_secret_bearing_url_is_never_linked():
    leaky = f"https://github.com/o/r/issues/1?access_token={TOKEN_SHAPE}"
    assert safe_href(leaky) is None
    d = ThreadDelta(_thread(repo_full_name="o/r", number=1, html_url=leaky), "new", AW)
    _s, text, doc = _render(deltas=[d])
    assert TOKEN_SHAPE not in doc and TOKEN_SHAPE not in text
    # Step 2 of the degradation: the DERIVED url, not nothing.
    assert "https://github.com/o/r/issues/1" in _audit(doc).hrefs


def test_credential_url_is_rejected_not_redacted():
    # Obviously-synthetic token: a high-entropy literal here trips gitea's
    # secret scanner and every future credential audit for no benefit.
    fake_token = "ghs_" + "deadbeef" * 3
    cred = f"https://x-access-token:{fake_token}@github.com/o/r"
    assert safe_href(cred) is None
    n = NotificationItem("github", "o/r", "Issue", "clone me", "", cred,
                         "2026-07-25T00:00:00Z", True)
    _s, text, doc = _render(notifications=[n])
    for part in (doc, text):
        # Assert on the ACTUAL fixture value. This previously checked for a
        # literal that the fixture never contained, so the test could not fail.
        assert fake_token not in part and "x-access-token" not in part
    assert 'href="[REDACTED]' not in doc


def test_no_remote_resources():
    d = ThreadDelta(_thread(title=HOSTILE), "new", AW)
    _s, _t2, doc = _render(deltas=[d], banner="LLM unavailable: TimeoutError")
    au = _audit(doc)
    assert not {"img", "script", "iframe", "link", "object", "embed"} & set(au.tags)
    assert not {"src", "srcset", "background", "poster"} & {n for n, _v in au.attrs}
    # The class-based-CSS invariant: styling never rides on an attribute.
    assert "style" not in {n for n, _v in au.attrs}
    css = "".join(au.style)
    assert "url(" not in css and "@import" not in css


def test_every_html_text_node_is_redaction_stable():
    """The class-level guard that replaces the whole-body pass the HTML part
    cannot have. Covers fields nobody has written yet."""
    att = [AttentionItem("gh:jwiegley/ledger#42", "serious", f"see {SECRET_TAIL}")]
    fx = _all_sections()
    fx["deltas"][0] = ThreadDelta(_thread(title=f"{HOSTILE} {SECRET_TAIL}"), "new", AW)
    _s, _t2, doc = _render(attention=att, **{k: v for k, v in fx.items()
                                             if k != "attention"})
    for n in _audit(doc).text:
        assert redact(n) == n, n
        assert "<" not in n, n
    assert redact(_CSS) == _CSS and "<" not in _CSS


# ----------------------------- link coverage -------------------------------
def test_every_section_links_its_items():
    _s, _t2, doc = _render(**_all_sections())
    hrefs = _audit(doc).hrefs
    assert set(hrefs) == {
        GH42,                                       # §1 attention id + §2 item
        "https://github.com/jwiegley/ledger",       # §2 GitHub heading
        "https://gitea.vulcan.lan/johnw/priv",      # §2 Gitea heading
        GITEA7,                                     # §2 Gitea item
        f"{GH43}#issuecomment-12345",               # §3 comment deep-link
        "https://github.com/ledger/ledger",         # §4 heading
        NOTIF,                                      # §4 item
        GH99,                                       # §5 stale item
        BAD_REPO,                                   # §6 errored repo
    }
    assert all(h.startswith("https://") for h in hrefs)


def test_row_urls_are_always_safe_href_output():
    """Pins the invariant that Row.url is only ever a safe_href() return."""
    fx = _all_sections()
    fx["deltas"].append(ThreadDelta(_thread(node_id="X", number=5,
                                            html_url="javascript:alert(1)"), "new", AW))
    fx["deltas"].append(ThreadDelta(_thread(node_id="Y", number=6,
                                            html_url="http://[evil"), "new", AW))
    fx["notifications"].append(NotificationItem("gitea", "johnw/priv", "Issue", "x",
                                                "", "  javascript:x  ", None, True))
    _subject, sections = build_sections(fx["coverage"] and _cfgh(), fx["deltas"],
                                        fx["notifications"], fx["attention"],
                                        fx["coverage"], "2026-07-27", fx["stale"])
    seen = 0
    for s in sections:
        for r in s.rows:
            if r.url is None:
                continue
            seen += 1
            assert r.url.startswith("http")
            assert safe_href(r.url) == r.url        # idempotent, already normalized
    assert seen >= 10


def test_plain_and_html_link_the_same_urls():
    """THE DIVERGENCE GUARD. Every href in the HTML must also be a URL in the
    plain part, so a section can never gain (or lose) a link in only one."""
    _s, text, doc = _render(**_all_sections())
    hrefs = _audit(doc).hrefs
    assert hrefs
    for h in hrefs:
        assert h in text, h


def test_anchor_count_matches_linkable_items():
    _s, _t2, doc = _render(**_all_sections())
    assert len(_audit(doc).hrefs) == 10


def test_comment_deep_link():
    assert comment_url(GH42, "12345") == f"{GH42}#issuecomment-12345"
    for junk in (None, "None", "abc", "12; DROP", "", 0):
        assert comment_url(GH42, junk) == GH42
    assert comment_url(None, "12") is None
    # A §3 row whose id was never enriched still links to the thread top.
    d = ThreadDelta(_thread(node_id="I_2", number=43, kind="pr", html_url=GH43,
                            last_comment_id=None), "new_comment", AW)
    _s, _t2, doc = _render(deltas=[d])
    assert GH43 in _audit(doc).hrefs


def test_thread_url_falls_back_on_empty_and_rejected():
    cfg = _cfgh()
    for bad in ("", "javascript:alert(1)", "http://[evil",
                "https://u:p@evil.example/x"):
        assert thread_url(cfg, _thread(html_url=bad)) == GH42, bad
    assert thread_url(cfg, _thread(kind="pr", html_url="")) == \
        "https://github.com/jwiegley/ledger/pull/42"
    gt = dict(platform="gitea", repo_full_name="johnw/priv", number=7, html_url="")
    assert thread_url(cfg, _thread(kind="pr", **gt)) == \
        "https://gitea.vulcan.lan/johnw/priv/pulls/7"
    assert thread_url(cfg, _thread(kind="issue", **gt)) == \
        "https://gitea.vulcan.lan/johnw/priv/issues/7"
    # Unusable Gitea base: no link, but the item is still rendered.
    stock = _cfg()                                   # gitea_url="u"
    assert thread_url(stock, _thread(title="orphan", **gt)) is None
    d = ThreadDelta(_thread(title="orphan", **gt), "new", AW)
    _s, text, doc = _render(cfg=stock, deltas=[d])
    assert "orphan" in doc and "orphan" in text
    assert _audit(doc).hrefs == []


def test_gitea_repo_heading_derives_from_config():
    d = ThreadDelta(_thread(platform="gitea", repo_full_name="johnw/priv", number=7,
                            html_url=GITEA7), "new", AW)
    _s, _t2, doc = _render(deltas=[d])
    assert "https://gitea.vulcan.lan/johnw/priv" in _audit(doc).hrefs
    # Self-validating: the stock test config's gitea_url="u" would otherwise
    # yield the junk string "u/johnw/priv".
    assert repo_url(_cfg(), "gitea", "johnw/priv") is None
    _s, _t2, doc2 = _render(cfg=_cfg(), deltas=[d])
    assert "u/johnw/priv" not in doc2


def test_repo_url_rejects_traversal():
    cfg = _cfgh()
    assert repo_url(cfg, "github", "../../evil") is None
    assert repo_url(cfg, "github", "a/../../b") is None
    assert repo_url(cfg, "github", "") is None
    assert repo_url(cfg, "github", "jwiegley/ledger") == "https://github.com/jwiegley/ledger"


def test_errored_repos_are_linked_from_authoritative_url():
    cov = Coverage(repos_scanned=2, repos_errored=2,
                   errored_repos=["jwiegley/bad", "jwiegley/nourl"])
    cov.errored_repo_urls["jwiegley/bad"] = BAD_REPO
    _s, text, doc = _render(coverage=cov)
    for part in (doc, text):
        assert "jwiegley/bad" in part and BAD_REPO in part
        assert "jwiegley/nourl" in part            # present, just unlinked
    assert _audit(doc).hrefs == [BAD_REPO]


def test_notification_none_url_degrades():
    n = NotificationItem("github", "ledger/ledger", "PullRequest", "no url", "",
                         None, "2026-07-25T00:00:00Z", True)
    _s, text, doc = _render(notifications=[n])
    assert "no url" in doc and "no url" in text
    assert "unlinkable url" not in doc             # absent, not rejected
    assert _audit(doc).hrefs == ["https://github.com/ledger/ledger"]


def test_attention_anchor_is_the_id_not_the_llm_prose():
    att = [AttentionItem("gh:jwiegley/ledger#42", "serious", "segfault everywhere")]
    d = ThreadDelta(_thread(), "new", AW)
    _s, text, doc = _render(deltas=[d], attention=att)
    assert f'<a href="{GH42}">gh:jwiegley/ledger#42</a>' in doc
    # Severity label and LLM prose both sit OUTSIDE the anchor.
    start = doc.index(f'<a href="{GH42}">')
    anchor = doc[start:doc.index("</a>", start)]
    assert "segfault" not in anchor and "serious" not in anchor
    assert "[serious] " + f'<a href="{GH42}">' in doc
    assert "</a> — segfault everywhere" in doc
    # ...and the plain line is unchanged by the split.
    assert "  [serious] gh:jwiegley/ledger#42 — segfault everywhere\n" in text


# ------------------------ message structure and wiring ---------------------
def _msg(subject="[oss-secretary] test", body="plain\n", html_body="<p>h</p>"):
    return message_from_bytes(
        build_message(subject, body, "s@x", "r@x", html_body), policy=policy.default)


def test_message_is_multipart_alternative_plain_first():
    body, doc = "plain body\n", "<html><body><p>hi</p></body></html>"
    raw = build_message("s", body, "s@x", "r@x", doc)
    m = message_from_bytes(raw, policy=policy.default)
    assert m.get_content_type() == "multipart/alternative"
    parts = list(m.iter_parts())
    assert [p.get_content_type() for p in parts] == ["text/plain", "text/html"]
    assert [p["Content-Transfer-Encoding"] for p in parts] == ["8bit", "quoted-printable"]
    b = m.get_boundary()
    assert b not in body and b not in doc
    assert max(len(ln) for ln in raw.split(b"\r\n")) < 998


def test_plain_part_is_8bit_not_base64():
    # The real body's "="*60 section rules make quoted-printable expensive, so
    # set_content()'s heuristic picks BASE64 without the explicit cte="8bit" --
    # which would make the plain part unreadable in a spool or dry-run.
    body = ("=" * 60) + "\n" + ("a long line well past seventy-eight columns " * 3) + "\n"
    m = message_from_bytes(build_message("s", body, "s@x", "r@x", "<p>h</p>"),
                           policy=policy.default)
    plain = list(m.iter_parts())[0]
    assert plain["Content-Transfer-Encoding"] == "8bit"
    assert ("=" * 60) in plain.get_content()


def test_subject_header_stays_raw_utf8():
    # Pins policy.SMTPUTF8 against an accidental policy.SMTP swap. The
    # follow-up commit that corrects the header encoding will invert this.
    subj = "[oss-secretary] 2026-07-27 — 3 new · 1 awaiting reply · 2 serious"
    raw = build_message(subj, "plain\n", "s@x", "r@x", "<p>h</p>")
    assert b"=?utf-8?" not in raw and b"=?UTF-8?" not in raw
    assert subj.encode("utf-8") in raw
    assert message_from_bytes(raw, policy=policy.default)["Subject"] == subj


def test_long_title_cannot_produce_an_overlong_wire_line():
    # GitHub caps titles at 256 chars; html.escape expands each apostrophe to
    # &#x27; (6x), so the HTML part carries a ~1.5 kB run with no break in it.
    d = ThreadDelta(_thread(title="'" * 256), "new", AW)
    subject, text, doc = _render(deltas=[d])
    raw = build_message(subject, text, "s@x", "r@x", doc)
    assert max(len(ln) for ln in raw.split(b"\r\n")) < 998
    got = list(message_from_bytes(raw, policy=policy.default).iter_parts())[1]
    # get_content() appends a newline and the wire form is CRLF, so an exact
    # comparison would fail for the wrong reason.
    assert got.get_content().replace("\r\n", "\n").rstrip("\n") == doc.rstrip("\n")


def test_build_message_without_html_is_single_part():
    m = message_from_bytes(build_message("s", "plain\n", "s@x", "r@x"),
                           policy=policy.default)
    assert m.get_content_type() == "text/plain"
    assert m["Content-Transfer-Encoding"] == "8bit"
    assert not m.is_multipart()


def test_html_disabled_by_config():
    subject, text, doc = _render(cfg=_cfgh(html=False), **_all_sections())
    assert doc is None
    subject2, text2, doc2 = _render(**_all_sections())
    assert doc2 is not None
    assert (subject, text) == (subject2, text2)     # plain path untouched


def test_html_render_failure_degrades_to_text(monkeypatch, caplog):
    """The test that protects the daily mail."""
    import oss_secretary.render as render

    def boom(*a, **kw):
        raise RuntimeError("secret payload must not be logged")

    monkeypatch.setattr(render, "_html_body", boom)
    with caplog.at_level("ERROR"):
        subject, text, doc = _render(**_all_sections())
    assert doc is None
    assert subject.startswith("[oss-secretary] 2026-07-27")
    assert "Coverage" in text and GH42 in text
    assert "RuntimeError" in caplog.text                     # type only...
    assert "secret payload must not be logged" not in caplog.text   # ...never the payload


def test_baseline_returns_html_sibling_with_no_anchors():
    subject, text, doc = render_baseline(_cfgh(), 10, 5, "2026-07-22")
    assert "10" in text and "5" in text
    assert "10" in doc and "5" in doc
    assert _audit(doc).hrefs == []


def test_html_flag_parses_as_an_opt_out(monkeypatch, tmp_path):
    """Guards the documented rollback path (services.…html = false, or
    OSS_SECRETARY_HTML=0 via `systemctl edit --runtime`).

    The codebase's usual bool(getenv(...)) idiom cannot express a default-ON
    flag: it makes the STRING "0" True, which would make the escape hatch a
    no-op. Every value below except the last two must disable HTML.
    """
    from oss_secretary.config import Config
    monkeypatch.setenv("OSS_SECRETARY_STATE_DB", str(tmp_path / "s.db"))
    for off in ("0", "false", "FALSE", "no", "off", "", " 0 "):
        monkeypatch.setenv("OSS_SECRETARY_HTML", off)
        assert Config.from_env().html is False, off
    for on in ("1", "true"):
        monkeypatch.setenv("OSS_SECRETARY_HTML", on)
        assert Config.from_env().html is True, on
    monkeypatch.delenv("OSS_SECRETARY_HTML")
    assert Config.from_env().html is True          # default ON, as John asked


def test_report_call_sites_stay_in_sync():
    """compute_deltas -> render_report -> build_message, the way report.main()
    wires it, so an arity drift fails here and not at 07:00."""
    from oss_secretary.state import State
    st = State(":memory:")
    st.open()
    deltas = compute_deltas(st, [_t()], run_id=1, baseline=False, owners=OWNERS,
                            now_iso="2026-07-27T00:00:00Z")
    subject, body, doc = render_report(_cfgh(), deltas, [], [], Coverage(),
                                       None, "2026-07-27", [])
    raw = build_message(subject, body, "s@x", "r@x", doc)
    assert message_from_bytes(raw, policy=policy.default).get_content_type() == \
        "multipart/alternative"
    st.close()
