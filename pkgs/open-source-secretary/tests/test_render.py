from oss_secretary.render import render_report, render_baseline, build_message, deliver
from oss_secretary.models import Coverage, AttentionItem, NotificationItem
from oss_secretary.delta import compute_deltas
from tests.test_delta import _t, OWNERS
from tests.test_github import _cfg


def test_subject_and_sections_present():
    from oss_secretary.models import ThreadDelta, AwaitingBundle
    d = ThreadDelta(_t(), "new", AwaitingBundle(False, False, False, 1.0, "NONE"))
    att = [AttentionItem("gh:jwiegley/foo#3", "serious", "crash on startup")]
    subject, body = render_report(_cfg(), [d], [], att, Coverage(repos_scanned=2),
                                  banner=None, date_str="2026-07-22")
    assert subject.startswith("[oss-secretary] 2026-07-22")
    assert "Needs your attention" in body and "crash on startup" in body
    assert "Coverage" in body


def test_baseline_message_has_no_per_item():
    subject, body = render_baseline(_cfg(), 10, 5, "2026-07-22")
    assert "baseline established" in body.lower() and "10" in body and "5" in body


def test_deliver_dry_run(capsys):
    cfg = _cfg(dry_run=True)
    raw = build_message("[oss-secretary] test", "hello", cfg.sender, cfg.recipient)
    assert deliver(raw, cfg) == 0
    assert "Subject: [oss-secretary] test" in capsys.readouterr().out
