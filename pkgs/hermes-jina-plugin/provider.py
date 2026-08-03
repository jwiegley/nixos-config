"""Jina Reader extract — Hermes web provider plugin.

Subclasses :class:`agent.web_search_provider.WebSearchProvider` and implements
the EXTRACT half of the web capability only. Hermes splits search and extract
(``supports_search`` / ``supports_extract``, selected by ``web.search_backend``
and ``web.extract_backend``), and this host already runs SearXNG for search --
whose bundled provider is explicitly search-only and documents "pair with an
extract provider for ``web_extract`` calls". This is that pair.

Why Jina Reader rather than a bundled provider: every extract-capable backend
Hermes ships (exa, firecrawl, parallel, tavily) requires a paid API key.
``r.jina.ai`` works with NO key at roughly 20 req/min, which is the only free
extract path available, and it renders JavaScript on Jina's infrastructure --
so the agent gets modern pages without this host running headless Chrome. That
matters: vulcan is a memory-constrained aarch64 box and self-hosting Jina
Reader (or Crawl4AI) would mean a Chromium per extraction.

Setting ``JINA_API_KEY`` is optional and only raises the rate limit; the
provider works keyless and never requires the variable to exist.

PRIVACY NOTE: extraction is performed by a third party. Every URL the agent
extracts is disclosed to Jina, and so is the returned content. Nothing else in
Hermes' web path leaves the LAN (SearXNG is self-hosted), so this provider is
the one deliberate exception. It is scoped to extract only.

Config keys this provider responds to::

    web:
      extract_backend: "jina"     # explicit per-capability
      backend: "jina"             # shared fallback

Env vars::

    JINA_API_KEY=...      # optional, raises the rate limit
    JINA_READER_URL=...   # optional, point at a self-hosted Reader
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, List
from urllib.parse import quote, urlparse

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

DEFAULT_READER = "https://r.jina.ai"

# Keyless r.jina.ai is ~20 req/min. extract() is a sequential loop, so a large
# url list would both trip that and block the agent turn for minutes. Cap it
# and report the truncation in-band rather than silently returning fewer
# documents than were asked for.
MAX_URLS = 10

# Generous because Reader renders JS server-side; a heavy page legitimately
# takes several seconds. Kept well under the 60s the firecrawl provider allows
# per URL so a stalled extract cannot dominate a turn.
TIMEOUT_SECONDS = 45


def _reader_base() -> str:
    return os.getenv("JINA_READER_URL", "").strip().rstrip("/") or DEFAULT_READER


def install_availability_shim() -> None:
    """Teach the legacy availability chain about registry-backed providers.

    WITHOUT THIS THE PLUGIN LOADS BUT IS NEVER SELECTED. Registering a
    provider is not sufficient to make it reachable.

    ``tools.web_tools._is_backend_available()`` is a hardcoded
    ``if backend == "exa" / "tavily" / "searxng" / ...`` chain that ends in a
    bare ``return False``. It answers False for ANY name it does not know
    literally — which is every user-installed plugin, no matter what that
    plugin's own ``is_available()`` says.

    That matters because the extract dispatcher consults it FIRST::

        _get_capability_backend("extract")
          -> specific = "jina"                     # from web.extract_backend
          -> if specific and _is_backend_available(specific)   # False!
          -> return _get_backend()                 # falls back to "searxng"

    and the caller then finds searxng registered-but-not-extract-capable and
    returns the typed "SearXNG is a search-only backend" error, never reaching
    ``get_active_extract_provider()`` — which reads web.extract_backend and
    would have resolved jina correctly. Observed exactly that on 2026-08-02:
    plugin registered, config correct, every web_extract still refused.

    Patched here rather than in the package because the fix is one function in
    a Python file, while rebuilding hermes-agent drags in its npm/TUI closure
    (whose npmDepsHash is x86-only and pinned for aarch64 on this host).
    Scoped to this plugin, so disabling the plugin removes the shim with it.

    STRICTLY ADDITIVE: the original is consulted first and its True is
    returned unchanged, so this can only make an unknown name available — it
    can never make a known backend unavailable, and it cannot change which
    provider a host without this plugin would have picked.
    """
    try:
        import tools.web_tools as web_tools
    except Exception as exc:  # noqa: BLE001
        logger.warning("Jina: could not import tools.web_tools to install shim: %s", exc)
        return

    original = getattr(web_tools, "_is_backend_available", None)
    if original is None:
        # Upstream renamed or removed it — the dispatcher has presumably been
        # reworked, so do nothing rather than guess at the new shape.
        logger.warning(
            "Jina: tools.web_tools._is_backend_available is absent; "
            "skipping shim (web.extract_backend may not resolve to jina)"
        )
        return

    if getattr(original, "_jina_registry_shim", False):
        return  # already installed (plugin reloaded in-process)

    def _is_backend_available(backend: str) -> bool:
        try:
            if original(backend):
                return True
        except Exception:  # noqa: BLE001
            pass
        try:
            from agent.web_search_registry import get_provider

            provider = get_provider(backend)
            if provider is not None:
                return bool(provider.is_available())
        except Exception:  # noqa: BLE001
            pass
        return False

    _is_backend_available._jina_registry_shim = True  # type: ignore[attr-defined]
    web_tools._is_backend_available = _is_backend_available
    logger.info("Jina: installed registry-aware backend-availability shim")


class JinaWebProvider(WebSearchProvider):
    """Extract page content as clean Markdown via Jina Reader."""

    @property
    def name(self) -> str:
        return "jina"

    @property
    def display_name(self) -> str:
        return "Jina Reader"

    def is_available(self) -> bool:
        """Always available — Reader needs no credentials.

        Deliberately NOT gated on JINA_API_KEY. Gating on the key would make
        the provider silently vanish on a host that is using the (fully
        supported) keyless mode, and Hermes would fall through to a backend
        that cannot extract at all.
        """
        return True

    def supports_search(self) -> bool:
        """False by design.

        Jina does offer search via s.jina.ai, but that endpoint requires a
        paid key, and this host already has SearXNG configured as the search
        backend. Claiming search here would let Hermes pick an endpoint that
        would 401 in place of one that works.
        """
        return False

    def supports_extract(self) -> bool:
        return True

    def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
        """Fetch each URL through Jina Reader, returning Markdown content.

        Sync, matching the bundled providers -- the base class runs it in an
        executor. Per-URL failures become items carrying ``error`` rather than
        failing the whole batch, so one dead link cannot lose the other
        results.
        """
        import httpx

        try:
            from tools.interrupt import is_interrupted
        except Exception:  # noqa: BLE001 - interrupt support is optional

            def is_interrupted() -> bool:
                return False

        if not urls:
            return []

        results: List[Dict[str, Any]] = []
        accepted, rejected = urls[:MAX_URLS], urls[MAX_URLS:]

        base = _reader_base()
        headers = {
            "Accept": "application/json",
            # Ask Reader to drop nav/aside/footer chrome. Jina's own output is
            # noisier than a dedicated extractor (published F1 ~0.64 vs
            # trafilatura's ~0.86, and roughly double the character count), so
            # trimming server-side keeps less boilerplate out of the context
            # window.
            "X-Return-Format": "markdown",
        }
        api_key = os.getenv("JINA_API_KEY", "").strip()
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"

        for url in accepted:
            if is_interrupted():
                results.append({"url": url, "title": "", "content": "", "error": "Interrupted"})
                continue

            parsed = urlparse(url)
            if parsed.scheme not in ("http", "https"):
                results.append(
                    {
                        "url": url,
                        "title": "",
                        "content": "",
                        "error": "Only http/https URLs can be extracted",
                    }
                )
                continue

            # safe="" is required: Reader takes the target as a PATH segment,
            # so an unescaped "?" or "#" in the target would be parsed as
            # r.jina.ai's own query/fragment and the wrong page would be
            # fetched (silently, with a 200).
            try:
                resp = httpx.get(
                    f"{base}/{quote(url, safe='')}",
                    headers=headers,
                    timeout=TIMEOUT_SECONDS,
                    follow_redirects=True,
                )
                resp.raise_for_status()
                payload = resp.json()
            except httpx.HTTPStatusError as exc:
                code = exc.response.status_code
                hint = ""
                if code == 429:
                    hint = " (rate limited; set JINA_API_KEY to raise the limit)"
                logger.warning("Jina Reader HTTP %s for %s", code, url)
                results.append(
                    {
                        "url": url,
                        "title": "",
                        "content": "",
                        "error": f"Jina Reader returned HTTP {code}{hint}",
                    }
                )
                continue
            except httpx.RequestError as exc:
                logger.warning("Jina Reader request error for %s: %s", url, exc)
                results.append(
                    {"url": url, "title": "", "content": "", "error": f"Could not reach Jina Reader: {exc}"}
                )
                continue
            except Exception as exc:  # noqa: BLE001
                logger.warning("Jina Reader parse error for %s: %s", url, exc)
                results.append(
                    {"url": url, "title": "", "content": "", "error": f"Could not parse Jina response: {exc}"}
                )
                continue

            data = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(data, dict):
                results.append(
                    {"url": url, "title": "", "content": "", "error": "Unexpected Jina response shape"}
                )
                continue

            # Reader reports the ORIGIN server's status inside a 200 envelope,
            # so a 404 upstream arrives here as a successful call wrapping an
            # error page. Surface it instead of handing the agent the site's
            # "not found" body as if it were the article.
            upstream = data.get("httpStatus")
            if isinstance(upstream, int) and upstream >= 400:
                results.append(
                    {
                        "url": url,
                        "title": str(data.get("title", "")),
                        "content": "",
                        "error": f"Origin returned HTTP {upstream}",
                    }
                )
                continue

            results.append(
                {
                    "url": str(data.get("url", url)),
                    "title": str(data.get("title", "")),
                    "content": str(data.get("content", "")),
                    "description": str(data.get("description", "")),
                }
            )

        for url in rejected:
            results.append(
                {
                    "url": url,
                    "title": "",
                    "content": "",
                    "error": f"Skipped: extract is capped at {MAX_URLS} URLs per call",
                }
            )

        ok = sum(1 for r in results if not r.get("error"))
        logger.info("Jina extract: %d/%d URL(s) succeeded", ok, len(results))
        return results

    def get_setup_schema(self) -> Dict[str, Any]:
        return {
            "name": "Jina Reader",
            "badge": "free · no key required",
            "tag": "URL → clean Markdown. Works keyless (~20 req/min); JINA_API_KEY only raises the limit.",
            "env_vars": [
                {
                    "key": "JINA_API_KEY",
                    "prompt": "Jina API key (OPTIONAL — leave blank to use the free keyless tier)",
                    "url": "https://jina.ai/reader/",
                    "optional": True,
                },
            ],
        }
