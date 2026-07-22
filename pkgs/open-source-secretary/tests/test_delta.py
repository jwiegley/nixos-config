from oss_secretary.state import State
from oss_secretary.delta import compute_deltas, item_id, build_awaiting
from oss_secretary.models import Thread, AwaitingBundle

OWNERS = {"jwiegley", "johnw"}


def _t(node="I_1", repo="jwiegley/foo", n=3, cc=0, last="alice", bot=False,
       state="open", closed=None, kind="issue"):
    return Thread("github", node, repo, n, kind, "t", "u", state, closed, cc,
                  None, "2026-07-20T00:00:00Z", last, bot, "NONE", "2026-07-20T00:00:00Z")


def test_baseline_marks_nothing_new(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    out = compute_deltas(st, [_t()], run_id=1, baseline=True, stale_days=30,
                         owners=OWNERS, now_iso="2026-07-22T00:00:00Z")
    assert out == []
    assert st.get_thread("github", "I_1") is not None   # seeded


def test_new_item_and_new_comment(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    compute_deltas(st, [_t(cc=1)], 1, baseline=True, stale_days=30, owners=OWNERS,
                   now_iso="2026-07-22T00:00:00Z")
    # run 2: existing thread gains a comment, plus a brand-new thread appears
    out = compute_deltas(st, [_t(cc=2), _t(node="I_9", n=9, cc=0)], 2, baseline=False,
                         stale_days=30, owners=OWNERS, now_iso="2026-07-23T00:00:00Z")
    changes = {item_id(d.thread): d.change for d in out}
    assert changes["gh:jwiegley/foo#3"] == "new_comment"
    assert changes["gh:jwiegley/foo#9"] == "new"


def test_reopened_not_new(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    compute_deltas(st, [_t(state="closed", closed="2026-07-01T00:00:00Z")], 1,
                   baseline=True, stale_days=30, owners=OWNERS, now_iso="2026-07-22T00:00:00Z")
    out = compute_deltas(st, [_t(state="open")], 2, baseline=False, stale_days=30,
                         owners=OWNERS, now_iso="2026-07-23T00:00:00Z")
    assert [d.change for d in out] == ["reopened"]


def test_awaiting_bundle_bot_and_owner():
    a = build_awaiting(_t(last="dependabot[bot]", bot=True), OWNERS)
    assert a.last_actor_is_bot and not a.is_last_commenter_owner
    b = build_awaiting(_t(last="jwiegley"), OWNERS)
    assert b.is_last_commenter_owner
