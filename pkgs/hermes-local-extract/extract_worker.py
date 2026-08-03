#!/usr/bin/env python3
"""Local URL -> Markdown extraction worker (trafilatura).

Runs in its OWN Nix python environment, spawned as a subprocess by the Hermes
plugin. It is deliberately NOT importable from the agent: hermes-agent seals its
venv and its build FAILS if anything in extraPythonPackages collides by name
with a sealed package, and trafilatura's closure carries certifi, urllib3 and
charset-normalizer -- all three of which are already in that venv. Subprocess
isolation sidesteps the collision entirely and mirrors how this host already
runs its MCP servers (lightPython / financialPython).

Protocol: read {"urls": [...]} as JSON on stdin, write a JSON list on stdout,
one object per URL in the SAME order, each {url, title, content, error?}.
Never writes anything but JSON to stdout; diagnostics go to stderr.
"""

from __future__ import annotations

import html as html_module
import ipaddress
import json
import re
import socket
import sys
from typing import Any, Dict, List
from urllib.parse import urlparse

import trafilatura
from trafilatura.settings import DEFAULT_CONFIG

# Bound a single extraction. The host is memory-constrained and one runaway
# page must not stall an agent turn. Measured on this host: 0.02s for a 20KiB
# blog post, 1.71s for a 110KiB docs page -- 20s is generous.
DOWNLOAD_TIMEOUT = "20"
MAX_FILE_SIZE = "20000000"  # 20 MB of HTML

# Cap what reaches the model. Extraction is normally small (Wikipedia's Markdown
# article came out at 30KiB) but a pathological page should not silently consume
# the context window. Truncation is REPORTED in-band, never silent.
MAX_CONTENT_CHARS = 200_000


def _config() -> Any:
    from copy import deepcopy

    cfg = deepcopy(DEFAULT_CONFIG)
    cfg["DEFAULT"]["DOWNLOAD_TIMEOUT"] = DOWNLOAD_TIMEOUT
    cfg["DEFAULT"]["MAX_FILE_SIZE"] = MAX_FILE_SIZE
    return cfg


CONFIG = _config()


def ssrf_reject_reason(url: str) -> str | None:
    """Return a rejection reason, or None if the URL is safe to fetch.

    Moving extraction in-house REINTRODUCES a risk the hosted service did not
    have: Jina fetched from its own infrastructure and structurally could not
    reach this network, whereas this worker runs inside the Hermes guest, which
    reaches host services over the bridge DNAT. Without this check, an agent
    talked into extracting http://10.99.1.1:<port>/... would proxy an internal
    service straight into a chat reply.

    Every resolved address is checked, not just the first: a hostname can
    resolve to both a public and a private address, and trafilatura picks
    whichever the resolver hands it.
    """
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return f"only http/https URLs can be extracted (got {parsed.scheme or 'no scheme'})"
    host = parsed.hostname
    if not host:
        return "URL has no host"

    try:
        infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80),
                                   proto=socket.IPPROTO_TCP)
    except OSError as exc:
        return f"could not resolve host: {exc}"

    for info in infos:
        addr = ipaddress.ip_address(info[4][0])
        if (addr.is_private or addr.is_loopback or addr.is_link_local
                or addr.is_reserved or addr.is_multicast or addr.is_unspecified):
            # Deliberately does NOT echo the resolved address back to the
            # caller -- that would turn this guard into an internal-network
            # scanner with a helpful readout.
            return "refusing to fetch a private, loopback or link-local address"
    return None


_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


def _best_title(html: str, url: str) -> str:
    """Prefer the authored <title>, falling back to trafilatura's metadata.

    Order matters and is deliberate. trafilatura's metadata title is a DOM
    HEURISTIC -- it picks a heading it believes is the title -- and it can pick
    chrome. Observed on nixos.org's Nix manual: it returned "Keyboard
    shortcuts" (a UI legend near the top of the page) while the authored
    <title> was "Introduction - Nix 2.34.9 Reference Manual". Handing the agent
    a title of "Keyboard shortcuts" for a page about the Nix language is worse
    than useless -- it is confidently wrong, and the agent will repeat it.

    <title> is authored metadata rather than a guess, so it is the primary. The
    heuristic stays as the fallback for pages that omit <title> entirely.
    """
    match = _TITLE_RE.search(html or "")
    if match:
        # Collapse the whitespace/newlines that pretty-printed HTML leaves in
        # multi-line <title> elements.
        candidate = html_module.unescape(" ".join(match.group(1).split())).strip()
        if candidate:
            return candidate[:300]

    try:
        meta = trafilatura.extract_metadata(html, default_url=url)
        if meta is not None and getattr(meta, "title", None):
            return str(meta.title)[:300]
    except Exception:  # noqa: BLE001
        pass  # a missing title never fails an otherwise good extraction
    return ""


def extract_one(url: str) -> Dict[str, Any]:
    reason = ssrf_reject_reason(url)
    if reason:
        return {"url": url, "title": "", "content": "", "error": reason}

    try:
        downloaded = trafilatura.fetch_url(url, config=CONFIG)
    except Exception as exc:  # noqa: BLE001
        return {"url": url, "title": "", "content": "", "error": f"fetch failed: {exc}"}

    if downloaded is None:
        return {"url": url, "title": "", "content": "",
                "error": "could not fetch the page (DNS, TLS, timeout, or non-200)"}

    try:
        content = trafilatura.extract(
            downloaded,
            url=url,
            output_format="markdown",  # native; no HTML->MD converter needed
            include_links=True,
            include_tables=True,
            include_comments=False,  # comment threads are context-window noise
            favor_precision=True,  # bias against boilerplate leaking through
            deduplicate=True,
            config=CONFIG,
        )
    except Exception as exc:  # noqa: BLE001
        return {"url": url, "title": "", "content": "", "error": f"extraction failed: {exc}"}

    title = _best_title(downloaded, url)

    if not content:
        # trafilatura returns None rather than emitting surrounding chrome, so
        # an empty result must be reported as an ERROR: an empty success would
        # read to the agent as "this page is blank", which is a different and
        # wrong conclusion.
        #
        # State BOTH plausible causes and commit to neither. There are two, and
        # they are indistinguishable from here: a JavaScript-only shell, or a
        # page that simply is not prose. trafilatura is tuned for articles and
        # scores poorly on index/listing pages (~0.52 on collection pages in
        # WCXB) -- blog.rust-lang.org's post index returns nothing for exactly
        # that reason, with no JavaScript involved. Naming only the JS cause
        # would hand the agent a confident misdiagnosis to repeat to the user.
        return {"url": url, "title": title, "content": "",
                "error": ("no article content could be extracted. The page is either "
                          "JavaScript-rendered (this extractor runs no browser) or is a "
                          "link index / listing rather than prose. If it is a listing, "
                          "try extracting one of the linked pages instead")}

    if len(content) > MAX_CONTENT_CHARS:
        content = content[:MAX_CONTENT_CHARS] + "\n\n[truncated by local extractor]"

    return {"url": url, "title": title, "content": content}


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        urls = payload["urls"]
        if not isinstance(urls, list):
            raise TypeError("urls must be a list")
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"error": f"bad request: {exc}"}), file=sys.stdout)
        return 2

    results: List[Dict[str, Any]] = []
    for url in urls:
        try:
            results.append(extract_one(str(url)))
        except Exception as exc:  # noqa: BLE001
            # One bad URL must never lose the other results in the batch.
            results.append({"url": str(url), "title": "", "content": "",
                            "error": f"unexpected error: {exc}"})

    json.dump(results, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
