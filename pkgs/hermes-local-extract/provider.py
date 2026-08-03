"""Local web extraction — Hermes web provider plugin.

Implements the EXTRACT half of Hermes' web capability with a FULLY LOCAL
pipeline. Nothing leaves this network: SearXNG (self-hosted) does search, and
this provider fetches the page itself and renders it to Markdown with
trafilatura. It replaces an earlier hosted r.jina.ai backend, which worked but
disclosed every extracted URL and its content to a third party.

Why trafilatura, and why in a SUBPROCESS:

  * Quality. Best-in-class boilerplate rejection among non-browser extractors
    (ScrapingHub article-extraction-benchmark F1 0.945 vs readability-lxml's
    0.922), and markedly better than the hosted Jina Reader it replaces
    (~0.86 vs ~0.64 by published comparison, at roughly half the character
    count -- which is context-window budget).
  * No browser. Crawl4AI and self-hosted Jina Reader both require a headless
    Chromium per extraction; vulcan is a memory-constrained aarch64 host that
    deliberately runs no heavy local workloads.
  * Subprocess, not an import. hermes-agent SEALS its venv and its build fails
    when anything in extraPythonPackages collides by name with a sealed
    package. trafilatura's closure carries certifi, urllib3 and
    charset-normalizer, and all three are already in that venv, so importing it
    into the agent is not merely inadvisable -- it does not build. The worker
    therefore lives in its own Nix python environment and this module speaks to
    it over JSON, using nothing but the standard library.

Config keys this provider responds to::

    web:
      extract_backend: "local"     # explicit per-capability
      backend: "local"             # shared fallback
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from typing import Any, Dict, List

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

# Substituted at build time by the Nix wrapper; see hermes-vm.nix. Falls back to
# the env var so the plugin stays testable outside Nix.
WORKER = os.environ.get("HERMES_LOCAL_EXTRACT_WORKER", "@worker@")

# One page is bounded inside the worker (20s download). This is the OUTER bound
# on a whole batch, and must exceed the worker's own budget so a per-URL timeout
# surfaces as a specific error rather than a killed batch.
BATCH_TIMEOUT_SECONDS = 180

# Keep a batch within the worker's sequential budget.
MAX_URLS = 10


def install_availability_shim() -> None:
    """Teach the legacy availability chain about registry-backed providers.

    WITHOUT THIS THE PLUGIN LOADS BUT IS NEVER SELECTED. Registering a provider
    is not sufficient to make it reachable.

    ``tools.web_tools._is_backend_available()`` is a hardcoded
    ``if backend == "exa" / "tavily" / "searxng" / ...`` chain ending in a bare
    ``return False``, so it answers False for any name it does not know
    literally -- which is every user-installed plugin, whatever that plugin's
    own ``is_available()`` says. The extract dispatcher consults it BEFORE the
    registry::

        _get_capability_backend("extract")
          -> specific = "local"                   # from web.extract_backend
          -> if specific and _is_backend_available(specific)   # False!
          -> return _get_backend()                # falls back to the search backend

    and the caller then finds SearXNG registered-but-not-extract-capable and
    returns its typed "search-only backend" error, never reaching
    ``get_active_extract_provider()``. Observed exactly that on 2026-08-02.

    STRICTLY ADDITIVE: the original is consulted first and its True returned
    unchanged, so this can only make an unknown name available. It can never
    make a known backend unavailable, nor change which provider a host without
    this plugin would pick.
    """
    try:
        import tools.web_tools as web_tools
    except Exception as exc:  # noqa: BLE001
        logger.warning("local-extract: could not import tools.web_tools for shim: %s", exc)
        return

    original = getattr(web_tools, "_is_backend_available", None)
    if original is None:
        logger.warning(
            "local-extract: tools.web_tools._is_backend_available absent; skipping shim "
            "(web.extract_backend may not resolve to 'local')"
        )
        return
    if getattr(original, "_local_extract_shim", False):
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

    _is_backend_available._local_extract_shim = True  # type: ignore[attr-defined]
    web_tools._is_backend_available = _is_backend_available
    logger.info("local-extract: installed registry-aware backend-availability shim")


class LocalWebExtractProvider(WebSearchProvider):
    """Fetch and extract page content locally, with no external service."""

    @property
    def name(self) -> str:
        return "local"

    @property
    def display_name(self) -> str:
        return "Local extraction (trafilatura)"

    def is_available(self) -> bool:
        """True when the worker exists and is executable.

        A real check, not a constant: if the Nix substitution failed or the
        store path was garbage-collected, reporting True would make every
        extraction fail with a confusing subprocess error instead of a clear
        "backend unavailable".
        """
        return bool(WORKER) and os.access(WORKER, os.X_OK)

    def supports_search(self) -> bool:
        """False -- SearXNG owns search on this host. This provider only reads
        a URL it is handed; it has no index of its own."""
        return False

    def supports_extract(self) -> bool:
        return True

    def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
        """Extract page content locally. Returns one item per input URL."""
        if not urls:
            return []

        try:
            from tools.interrupt import is_interrupted
        except Exception:  # noqa: BLE001

            def is_interrupted() -> bool:
                return False

        if is_interrupted():
            return [{"url": u, "title": "", "content": "", "error": "Interrupted"} for u in urls]

        if not self.is_available():
            return [
                {"url": u, "title": "", "content": "",
                 "error": f"local extraction worker is missing or not executable: {WORKER}"}
                for u in urls
            ]

        accepted, rejected = list(urls[:MAX_URLS]), list(urls[MAX_URLS:])

        try:
            proc = subprocess.run(
                [WORKER],
                input=json.dumps({"urls": accepted}),
                capture_output=True,
                text=True,
                timeout=BATCH_TIMEOUT_SECONDS,
                # The worker needs no ambient environment and must not inherit
                # the agent's -- it carries API keys the extractor has no use
                # for. PATH is kept minimal for the interpreter's own needs.
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                     "HOME": os.environ.get("HOME", "/tmp")},
            )
        except subprocess.TimeoutExpired:
            return [
                {"url": u, "title": "", "content": "",
                 "error": f"local extraction timed out after {BATCH_TIMEOUT_SECONDS}s"}
                for u in accepted
            ] + [self._skipped(u) for u in rejected]
        except Exception as exc:  # noqa: BLE001
            logger.warning("local-extract: worker invocation failed: %s", exc)
            return [
                {"url": u, "title": "", "content": "", "error": f"local extractor failed: {exc}"}
                for u in accepted
            ] + [self._skipped(u) for u in rejected]

        if proc.returncode != 0:
            # stderr is the worker's own diagnostics, not page content, so it is
            # safe to surface -- but trim it so a stack trace cannot dominate.
            detail = (proc.stderr or "").strip()[:300] or f"exit {proc.returncode}"
            logger.warning("local-extract: worker exit %s: %s", proc.returncode, detail)
            return [
                {"url": u, "title": "", "content": "", "error": f"local extractor error: {detail}"}
                for u in accepted
            ] + [self._skipped(u) for u in rejected]

        try:
            results = json.loads(proc.stdout)
            if not isinstance(results, list):
                raise TypeError("worker did not return a list")
        except Exception as exc:  # noqa: BLE001
            logger.warning("local-extract: could not parse worker output: %s", exc)
            return [
                {"url": u, "title": "", "content": "",
                 "error": f"could not parse local extractor output: {exc}"}
                for u in accepted
            ] + [self._skipped(u) for u in rejected]

        results.extend(self._skipped(u) for u in rejected)
        ok = sum(1 for r in results if isinstance(r, dict) and not r.get("error"))
        logger.info("Local extract: %d/%d URL(s) succeeded", ok, len(results))
        return results

    @staticmethod
    def _skipped(url: str) -> Dict[str, Any]:
        return {"url": url, "title": "", "content": "",
                "error": f"Skipped: extract is capped at {MAX_URLS} URLs per call"}

    def get_setup_schema(self) -> Dict[str, Any]:
        return {
            "name": "Local extraction",
            "badge": "free · fully local · no API key",
            "tag": ("Fetches and extracts pages on this host with trafilatura. "
                    "Nothing is sent to a third party. Cannot render JavaScript-only pages."),
            "env_vars": [],
        }
