from oss_secretary.state import State
from oss_secretary.delta import compute_deltas, compute_stale, item_id, build_awaiting
from oss_secretary.models import Thread

OWNERS = {"jwiegley", "johnw"}


def _t(node="I_1", repo="jwiegley/foo", n=3, cc=0, last="alice", bot=False,
       state="open", closed=None, kind="issue", upd="2026-07-20T00:00:00Z"):
    return Thread("github", node, repo, n, kind, "t", "u", state, closed, cc,
                  None, upd, last, bot, "NONE", upd)


def test_baseline_marks_nothing_new(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    out = compute_deltas(st, [_t()], run_id=1, baseline=True,
                         owners=OWNERS, now_iso="2026-07-22T00:00:00Z")
    assert out == []
    assert st.get_thread("github", "I_1") is not None   # seeded


def test_new_item_and_new_comment(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    compute_deltas(st, [_t(cc=1)], 1, baseline=True, owners=OWNERS,
                   now_iso="2026-07-22T00:00:00Z")
    # run 2: existing thread gains a comment, plus a brand-new thread appears
    out = compute_deltas(st, [_t(cc=2), _t(node="I_9", n=9, cc=0)], 2, baseline=False,
                         owners=OWNERS, now_iso="2026-07-23T00:00:00Z")
    changes = {item_id(d.thread): d.change for d in out}
    assert changes["gh:jwiegley/foo#3"] == "new_comment"
    assert changes["gh:jwiegley/foo#9"] == "new"


def test_reopened_via_state_all(tmp_path):
    # A close→reopen is only visible because collectors fetch state=all: the
    # thread is first recorded closed, then reappears open with prior=closed.
    st = State(str(tmp_path / "s.db")); st.open()
    compute_deltas(st, [_t(state="closed", closed="2026-07-01T00:00:00Z")], 1,
                   baseline=True, owners=OWNERS, now_iso="2026-07-22T00:00:00Z")
    assert st.get_thread("github", "I_1")["state"] == "closed"  # recorded closed
    out = compute_deltas(st, [_t(state="open")], 2, baseline=False,
                         owners=OWNERS, now_iso="2026-07-23T00:00:00Z")
    assert [d.change for d in out] == ["reopened"]


def test_closed_item_recorded_but_not_reported(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    compute_deltas(st, [_t(cc=0)], 1, baseline=True, owners=OWNERS,
                   now_iso="2026-07-22T00:00:00Z")
    # thread closes with a new comment: recorded closed, but NOT a reported delta
    out = compute_deltas(st, [_t(cc=2, state="closed", closed="2026-07-23T00:00:00Z")],
                         2, baseline=False, owners=OWNERS, now_iso="2026-07-23T00:00:00Z")
    assert out == []
    assert st.get_thread("github", "I_1")["state"] == "closed"


def test_compute_stale_flags_quiet_open_threads(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    # An open thread last active in January, recorded in run 1.
    compute_deltas(st, [_t(node="I_5", n=5, upd="2026-01-01T00:00:00Z")], run_id=1,
                   baseline=True, owners=OWNERS, now_iso="2026-01-01T00:00:00Z")
    # Run 2 in July with no activity on it → stale (>30 days quiet).
    stale = compute_stale(st, run_id=2, stale_days=30, owners=OWNERS,
                          now_iso="2026-07-22T00:00:00Z")
    assert "gh:jwiegley/foo#5" in [item_id(d.thread) for d in stale]
    # A thread seen THIS run is fresh, never stale.
    compute_deltas(st, [_t(node="I_6", n=6, upd="2026-01-01T00:00:00Z")], run_id=3,
                   baseline=False, owners=OWNERS, now_iso="2026-07-22T00:00:00Z")
    stale2 = compute_stale(st, run_id=3, stale_days=30, owners=OWNERS,
                           now_iso="2026-07-22T00:00:00Z")
    assert "gh:jwiegley/foo#6" not in [item_id(d.thread) for d in stale2]


def test_awaiting_bundle_bot_and_owner():
    a = build_awaiting(_t(last="dependabot[bot]", bot=True), OWNERS)
    assert a.last_actor_is_bot and not a.is_last_commenter_owner
    b = build_awaiting(_t(last="jwiegley"), OWNERS)
    assert b.is_last_commenter_owner
    # has_owner_response overrides the coarse proxy when supplied.
    c = build_awaiting(_t(last="alice"), OWNERS, has_owner_response=True)
    assert c.has_owner_response is True
