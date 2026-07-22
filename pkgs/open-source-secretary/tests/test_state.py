from oss_secretary.state import State


def test_schema_and_thread_upsert_roundtrip(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.baseline_established() is False
    row = dict(platform="github", node_id="I_1", repo_full_name="jwiegley/foo",
               number=1, kind="issue", title="t", html_url="u", state="open",
               closed_at=None, comment_count=2, last_comment_id="c9",
               last_comment_at="2026-07-20T00:00:00Z", last_commenter="alice",
               author_association="NONE", updated_at="2026-07-20T00:00:00Z",
               first_seen_run=1, last_seen_run=1)
    st.upsert_thread(row)
    got = st.get_thread("github", "I_1")
    assert got["comment_count"] == 2 and got["repo_full_name"] == "jwiegley/foo"
    # upsert again with a new slug updates in place (rename), same PK
    row["repo_full_name"] = "jwiegley/foo-renamed"; row["comment_count"] = 3
    st.upsert_thread(row)
    assert st.get_thread("github", "I_1")["repo_full_name"] == "jwiegley/foo-renamed"
    assert st.get_thread("github", "I_1")["comment_count"] == 3
    st.close()


def test_http_cache_and_meta(tmp_path):
    st = State(str(tmp_path / "s.db")); st.open()
    assert st.cache_get("http://x") == (None, None)
    st.cache_set("http://x", '"e"', "lm")
    assert st.cache_get("http://x") == ('"e"', "lm")
    st.set_meta("k", "v"); assert st.get_meta("k") == "v"
    assert st.next_run_id() == 1 and st.next_run_id() == 2
    st.close()


def test_flock_prevents_second_run(tmp_path):
    p = str(tmp_path / "s.db")
    a = State(p); a.open(); assert a.acquire_lock() is True
    b = State(p); b.open(); assert b.acquire_lock() is False
    a.close(); b.close()


def test_commit_gating(tmp_path):
    p = str(tmp_path / "s.db")
    st = State(p); st.open()
    st.upsert_thread(dict(platform="gitea", node_id="7", repo_full_name="johnw/x",
        number=7, kind="pr", title="t", html_url="u", state="open", closed_at=None,
        comment_count=0, last_comment_id=None, last_comment_at=None, last_commenter=None,
        author_association=None, updated_at=None, first_seen_run=1, last_seen_run=1))
    st.rollback()                       # simulate failed send
    st.close()
    st2 = State(p); st2.open()
    assert st2.get_thread("gitea", "7") is None   # rolled back, not persisted
    st2.close()
