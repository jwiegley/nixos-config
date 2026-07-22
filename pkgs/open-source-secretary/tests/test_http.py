import json
from urllib.parse import urlparse, parse_qs
import requests
import responses
from oss_secretary.http import Client, NullCache, _StripAuthSession


class _MemCache:
    def __init__(self):
        self._d = {}

    def cache_get(self, url):
        return self._d.get(url, (None, None))

    def cache_set(self, url, etag, lm):
        self._d[url] = (etag, lm)


@responses.activate
def test_paginate_follows_link_header():
    responses.add(responses.GET, "https://api.test/items",
                  json=[{"id": 1}], status=200,
                  headers={"Link": '<https://api.test/items?page=2>; rel="next"'})
    responses.add(responses.GET, "https://api.test/items",
                  json=[{"id": 2}], status=200)  # no Link => last page
    c = Client("https://api.test", {"Authorization": "Bearer x"}, None, NullCache(), "github")
    items = c.paginate("/items")
    assert [i["id"] for i in items] == [1, 2]


@responses.activate
def test_gitea_pagination_via_x_total_count():
    pages = {1: [{"id": 1}, {"id": 2}], 2: [{"id": 3}, {"id": 4}], 3: [{"id": 5}]}

    def cb(request):
        page = int(parse_qs(urlparse(request.url).query).get("page", ["1"])[0])
        return (200, {"X-Total-Count": "5"}, json.dumps(pages[page]))

    responses.add_callback(responses.GET, "https://gitea.test/repos", callback=cb)
    c = Client("https://gitea.test", {}, None, NullCache(), "gitea")
    items = c.paginate("/repos", {"limit": 2})
    assert [i["id"] for i in items] == [1, 2, 3, 4, 5]   # no dupes, no missed page 3


@responses.activate
def test_conditional_304_returns_none_and_reuses_etag():
    calls = {}

    def cb(request):
        calls["inm"] = request.headers.get("If-None-Match")
        return (304, {}, "")

    cache = _MemCache()
    cache.cache_set("https://api.test/x", '"abc"', None)
    responses.add_callback(responses.GET, "https://api.test/x", callback=cb)
    c = Client("https://api.test", {}, None, cache, "github")
    body, headers = c.get("/x")
    assert body is None
    assert calls["inm"] == '"abc"'


@responses.activate
def test_conditional_false_skips_etag_and_returns_body():
    seen = {}

    def cb(request):
        seen["inm"] = request.headers.get("If-None-Match")
        return (200, {}, json.dumps([{"id": 7}]))

    cache = _MemCache()
    cache.cache_set("https://api.test/repos?per_page=100", '"e"', None)
    responses.add_callback(responses.GET, "https://api.test/repos", callback=cb)
    c = Client("https://api.test", {}, None, cache, "github")
    items = c.paginate("/repos", {"per_page": 100}, conditional=False)
    assert items == [{"id": 7}]
    assert seen["inm"] is None            # enumeration never 304s into []


@responses.activate
def test_auth_never_in_url_and_backoff_on_429(monkeypatch):
    slept = []
    monkeypatch.setattr("oss_secretary.http.time.sleep", lambda s: slept.append(s))
    responses.add(responses.GET, "https://api.test/y", status=429,
                  headers={"Retry-After": "2"})
    responses.add(responses.GET, "https://api.test/y", json=[{"id": 9}], status=200)
    c = Client("https://api.test", {"Authorization": "Bearer secrettoken"}, None, NullCache(), "github")
    items = c.paginate("/y")
    assert items == [{"id": 9}]
    assert slept == [2]
    for call in responses.calls:
        assert "secrettoken" not in call.request.url


@responses.activate
def test_backoff_on_403_secondary_limit(monkeypatch):
    slept = []
    monkeypatch.setattr("oss_secretary.http.time.sleep", lambda s: slept.append(s))
    responses.add(responses.GET, "https://api.test/z", status=403,
                  headers={"Retry-After": "3", "x-ratelimit-remaining": "42"})
    responses.add(responses.GET, "https://api.test/z", json=[{"id": 1}], status=200)
    c = Client("https://api.test", {}, None, NullCache(), "github")
    items = c.paginate("/z")
    assert items == [{"id": 1}]
    assert slept == [3]                   # backed off despite non-zero remaining


@responses.activate
def test_min_interval_throttles_requests(monkeypatch):
    slept = []
    monkeypatch.setattr("oss_secretary.http.time.sleep", lambda s: slept.append(s))
    monkeypatch.setattr("oss_secretary.http.time.monotonic", lambda: 0.0)  # freeze clock
    responses.add(responses.GET, "https://g.test/a", json=[], status=200)
    responses.add(responses.GET, "https://g.test/b", json=[], status=200)
    c = Client("https://g.test", {}, None, NullCache(), "gitea", min_interval=0.3)
    c.get("/a")
    c.get("/b")
    # clock frozen at 0 => every request must wait the full interval
    assert slept and all(abs(s - 0.3) < 1e-6 for s in slept)


def test_no_throttle_by_default(monkeypatch):
    slept = []
    monkeypatch.setattr("oss_secretary.http.time.sleep", lambda s: slept.append(s))
    c = Client("https://g.test", {}, None, NullCache(), "github")  # min_interval=0.0
    c._throttle(); c._throttle()
    assert slept == []            # GitHub is not throttled (rate-limit headers handle it)


def test_strip_auth_on_scheme_downgrade():
    s = _StripAuthSession()
    resp = requests.Response()
    resp.request = requests.Request(method="GET", url="https://h/x").prepare()
    pr = requests.Request(method="GET", url="http://h/x").prepare()   # https -> http
    pr.headers["Authorization"] = "Bearer t"
    s.rebuild_auth(pr, resp)
    assert "Authorization" not in pr.headers
