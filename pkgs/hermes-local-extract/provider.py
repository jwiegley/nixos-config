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
import re
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

# Anything scheme-like is scrubbed out of a reason before it is logged.
#
# WHY THIS IS NOT PARANOIA: three of the error strings this module and the
# worker produce interpolate an exception -- "fetch failed: {exc}",
# "extraction failed: {exc}", "unexpected error: {exc}" -- and urllib/requests
# exceptions routinely embed the URL that failed. The extracted URLs are the
# user's research targets; they have no business in a log file that is retained
# across four rotations and parsed by hermes-health-check. The reasons are the
# diagnostic value here, the URLs are not, so the reason text is scrubbed rather
# than trusted to be clean. Over-matching is the safe direction.
#
# The worker's own guards are already careful in the same way: its SSRF
# rejection deliberately does not echo the resolved address back to the caller
# (extract_worker.py), for the same reason.
_URL_RE = re.compile(r"[a-zA-Z][a-zA-Z0-9+.\-]*://\S+")

# A single reason must not be able to dominate the line -- an exception string
# can be arbitrarily long -- and neither must the set of them.
_MAX_REASON_CHARS = 120
_MAX_REASONS = 5


def _failure_summary(results: List[Dict[str, Any]]) -> str:
    """Distinct failure reasons, URL-scrubbed, most frequent first.

    Empty string when nothing failed, which is what lets the caller keep the
    original single-clause log line for the common all-succeeded case.
    """
    counts: Dict[str, int] = {}
    for r in results:
        if not isinstance(r, dict) or not r.get("error"):
            continue
        # Collapse whitespace: the worker's longest reason is a wrapped
        # multi-line string, and a newline inside a log line would split one
        # record into two as far as any line-oriented reader is concerned.
        reason = " ".join(_URL_RE.sub("<url>", str(r["error"])).split())
        if len(reason) > _MAX_REASON_CHARS:
            reason = reason[: _MAX_REASON_CHARS - 3] + "..."
        counts[reason] = counts.get(reason, 0) + 1

    # Frequency first, then alphabetical, so the line is stable across runs
    # with the same failures and diffable by eye.
    ordered = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    shown = [f"{reason} (x{n})" if n > 1 else reason for reason, n in ordered[:_MAX_REASONS]]
    if len(ordered) > _MAX_REASONS:
        shown.append(f"+{len(ordered) - _MAX_REASONS} more")
    return "; ".join(shown)


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
            # The only failure path that used to return in total silence -- no
            # count line, no warning -- which made a whole batch exceeding the
            # outer bound the single most severe outcome AND the least visible
            # one. Its two sibling handlers below both log; this now matches.
            logger.warning(
                "local-extract: worker timed out after %ss for %d URL(s)",
                BATCH_TIMEOUT_SECONDS,
                len(accepted),
            )
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

        # The count alone is not actionable. A partial batch is NORMAL here --
        # measured across all four agent-log rotations (2026-08-04 onward),
        # 121 of 157 URLs extracted, with 12 of 105 batches returning nothing --
        # and every one of those was a page trafilatura could not render, not a
        # broken extractor: worker-level errors over the same period were zero.
        # Without the reason the two are indistinguishable in the log, which is
        # what made HermesExtractFailing an alert nobody could act on. The
        # reasons already exist in `results`; they were simply being discarded.
        #
        # The prefix through "succeeded" is load-bearing: hermes-health-check
        # matches EXTRACT_RESULT_RE against this line with re.search, so the
        # clause is appended rather than woven in.
        failures = _failure_summary(results)
        if failures:
            logger.info(
                "Local extract: %d/%d URL(s) succeeded; reasons: %s", ok, len(results), failures
            )
        else:
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
