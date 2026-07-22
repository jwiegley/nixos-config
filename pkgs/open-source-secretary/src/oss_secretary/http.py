from __future__ import annotations
import logging
import time
from urllib.parse import urlencode, urlparse
import requests

log = logging.getLogger("oss_secretary.http")
MAX_RETRIES = 5


class HttpError(Exception):
    pass


class NullCache:
    def cache_get(self, url):
        return (None, None)

    def cache_set(self, url, etag, lm):
        pass


class _StripAuthSession(requests.Session):
    """Session that also drops Authorization on an https→http scheme downgrade.

    requests strips Authorization on a cross-*host* redirect by default, but
    keeps it on a same-host scheme downgrade (https→http), which would leak a
    bearer token in cleartext. Close that gap (spec §7.5)."""

    def rebuild_auth(self, prepared_request, response):
        super().rebuild_auth(prepared_request, response)
        try:
            orig = urlparse(response.request.url)
            new = urlparse(prepared_request.url)
            if orig.scheme == "https" and new.scheme != "https":
                prepared_request.headers.pop("Authorization", None)
        except Exception:
            pass


class Client:
    def __init__(self, base_url, auth, ca_bundle, cache, source):
        self.base_url = base_url.rstrip("/")
        self.source = source
        self.cache = cache
        self._s = _StripAuthSession()
        self._s.headers.update(auth)
        self._s.headers["Accept"] = "application/json"
        self._verify = ca_bundle if ca_bundle else True

    def _url(self, path):
        return path if path.startswith("http") else f"{self.base_url}{path}"

    @staticmethod
    def _cache_key(url, params):
        if not params:
            return url
        return f"{url}?{urlencode(sorted(params.items()))}"

    def get(self, path, params=None, conditional=True):
        """GET one resource. Returns (json_or_None_if_304, headers).

        conditional=False disables If-None-Match/If-Modified-Since so the
        server always returns the full body — required for enumeration
        endpoints (static params) which must never silently 304 into ``[]``.
        """
        url = self._url(path)
        key = self._cache_key(url, params)
        headers = {}
        if conditional:
            etag, lm = self.cache.cache_get(key)
            if etag:
                headers["If-None-Match"] = etag
            if lm:
                headers["If-Modified-Since"] = lm
        resp = self._request(url, params, headers)
        if resp.status_code == 304:
            return None, resp.headers
        if conditional:
            new_etag = resp.headers.get("ETag")
            new_lm = resp.headers.get("Last-Modified")
            if new_etag or new_lm:
                self.cache.cache_set(key, new_etag, new_lm)
        return resp.json(), resp.headers

    def _request(self, url, params, headers):
        attempt = 0
        while True:
            attempt += 1
            try:
                resp = self._s.get(url, params=params, headers=headers,
                                   timeout=30, allow_redirects=True, verify=self._verify)
            except requests.RequestException as e:
                # Connection/timeout/DNS blips: retry then surface as HttpError
                # so per-repo isolation can skip cleanly (never leak the URL).
                if attempt > MAX_RETRIES:
                    raise HttpError(f"{self.source}: transport error {type(e).__name__}")
                time.sleep(min(60, 2 ** attempt))
                continue
            if resp.status_code == 429 or 500 <= resp.status_code < 600:
                if attempt > MAX_RETRIES:
                    raise HttpError(f"{self.source}: {resp.status_code} after {attempt} tries")
                time.sleep(self._backoff(resp, attempt))
                continue
            # 403: primary limit (remaining==0) OR secondary/abuse limit
            # (Retry-After present with non-zero remaining) — back off either way.
            if resp.status_code == 403 and (
                resp.headers.get("Retry-After")
                or resp.headers.get("x-ratelimit-remaining") == "0"
            ):
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

    def paginate(self, path, params=None, conditional=True):
        """Fetch all pages. Follows GitHub ``Link rel=next``; for Gitea uses
        ``X-Total-Count`` with an explicit page counter. A 304 on page 1
        (conditional only) yields ``[]`` — correct for since-filtered lists,
        which is why enumeration callers pass conditional=False."""
        items = []
        params = dict(params or {})
        page = int(params.get("page", 1))
        next_url = None
        while True:
            if next_url:
                body, headers = self.get(next_url, None, conditional=conditional)
            else:
                params["page"] = page
                body, headers = self.get(path, params, conditional=conditional)
            if body is None:                       # 304 — nothing changed
                break
            chunk = body if isinstance(body, list) else body.get("data", [])
            items.extend(chunk)
            link_next = self._next_link(headers)
            if link_next:                          # GitHub-style
                next_url = link_next
                continue
            total = headers.get("X-Total-Count")   # Gitea-style
            if total is not None and chunk and len(items) < int(total):
                next_url = None
                page += 1
                continue
            break
        return items

    @staticmethod
    def _next_link(headers):
        link = headers.get("Link", "")
        for part in link.split(","):
            seg = part.split(";")
            if len(seg) >= 2 and 'rel="next"' in seg[1]:
                return seg[0].strip().strip("<>")
        return None
