from __future__ import annotations
import logging
import time
import requests

log = logging.getLogger("oss_secretary.http")
MAX_RETRIES = 5


class HttpError(Exception):
    pass


class NullCache:
    def cache_get(self, url): return (None, None)
    def cache_set(self, url, etag, lm): pass


class Client:
    def __init__(self, base_url, auth, ca_bundle, cache, source):
        self.base_url = base_url.rstrip("/")
        self.source = source
        self.cache = cache
        self._s = requests.Session()
        self._s.headers.update(auth)
        self._s.headers["Accept"] = "application/json"
        # requests strips Authorization on cross-host redirects by default.
        self._verify = ca_bundle if ca_bundle else True

    def _url(self, path):
        return path if path.startswith("http") else f"{self.base_url}{path}"

    def get(self, path, params=None):
        url = self._url(path)
        etag, lm = self.cache.cache_get(url)
        headers = {}
        if etag:
            headers["If-None-Match"] = etag
        if lm:
            headers["If-Modified-Since"] = lm
        resp = self._request(url, params, headers)
        if resp.status_code == 304:
            return None, resp.headers
        new_etag = resp.headers.get("ETag")
        new_lm = resp.headers.get("Last-Modified")
        if new_etag or new_lm:
            self.cache.cache_set(url, new_etag, new_lm)
        return resp.json(), resp.headers

    def _request(self, url, params, headers):
        attempt = 0
        while True:
            attempt += 1
            resp = self._s.get(url, params=params, headers=headers,
                               timeout=30, allow_redirects=True, verify=self._verify)
            if resp.status_code in (429,) or 500 <= resp.status_code < 600:
                if attempt > MAX_RETRIES:
                    raise HttpError(f"{self.source}: {resp.status_code} after {attempt} tries")
                time.sleep(self._backoff(resp, attempt))
                continue
            if resp.status_code == 403 and resp.headers.get("x-ratelimit-remaining") == "0":
                if attempt > MAX_RETRIES:
                    raise HttpError(f"{self.source}: rate limited")
                time.sleep(self._backoff(resp, attempt))
                continue
            if resp.status_code >= 400 and resp.status_code != 304:
                raise HttpError(f"{self.source}: HTTP {resp.status_code}")
            return resp

    @staticmethod
    def _backoff(resp, attempt):
        ra = resp.headers.get("Retry-After")
        if ra and ra.isdigit():
            return int(ra)
        reset = resp.headers.get("x-ratelimit-reset")
        if reset and reset.isdigit():
            return max(1, int(reset) - int(time.time()))
        return min(60, 2 ** attempt)

    def paginate(self, path, params=None):
        items = []
        url, p = self._url(path), dict(params or {})
        while url:
            body, headers = self.get(url, p)
            if body is None:            # 304 — nothing changed
                break
            page = body if isinstance(body, list) else body.get("data", [])
            items.extend(page)
            url = self._next_link(headers)
            p = None                    # next URL already carries the query
            if url is None and headers.get("X-Total-Count"):
                url = self._gitea_next(path, params, headers, len(items))
        return items

    @staticmethod
    def _next_link(headers):
        link = headers.get("Link", "")
        for part in link.split(","):
            seg = part.split(";")
            if len(seg) >= 2 and 'rel="next"' in seg[1]:
                return seg[0].strip().strip("<>")
        return None

    def _gitea_next(self, path, params, headers, got):
        total = int(headers.get("X-Total-Count", "0"))
        if got >= total:
            return None
        p = dict(params or {})
        p["page"] = int(p.get("page", 1)) + 1
        # rebuild the full URL with the incremented page
        from urllib.parse import urlencode
        return f"{self._url(path)}?{urlencode(p)}"
