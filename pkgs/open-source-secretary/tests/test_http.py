import responses
from oss_secretary.http import Client, NullCache


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
def test_conditional_304_returns_none_and_reuses_etag():
    calls = {}

    def cb(request):
        calls["inm"] = request.headers.get("If-None-Match")
        return (304, {}, "")
    cache = _MemCache(); cache.cache_set("https://api.test/x", '"abc"', None)
    responses.add_callback(responses.GET, "https://api.test/x", callback=cb)
    c = Client("https://api.test", {}, None, cache, "github")
    body, headers = c.get("/x")
    assert body is None
    assert calls["inm"] == '"abc"'


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
    # token must never appear in any recorded request URL
    for call in responses.calls:
        assert "secrettoken" not in call.request.url


class _MemCache:
    def __init__(self): self._d = {}
    def cache_get(self, url): return self._d.get(url, (None, None))
    def cache_set(self, url, etag, lm): self._d[url] = (etag, lm)
