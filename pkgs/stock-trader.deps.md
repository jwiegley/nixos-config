# stock-trader runtime Python dependencies

> **This is a dated audit snapshot, not a live manifest.** It was taken against
> `refs/tags/v0.1.0`; as of 2026-07-27 `flake.nix:110` pins the `stock-trader`
> input at `refs/tags/v0.2.0` (the `version = "0.1.0"` strings at
> `overlays/default.nix:775,784` were not bumped with it). Re-run the audit
> below before trusting this list for a new deployment. The "verified version"
> column likewise reflects nixpkgs as of 2026-04-26.

Generated 2026-04-26 (vulcan deployment chunk 2, task 7) from the
v0.1.0 source tree of the laptop repo at
`refs/tags/v0.1.0`. Audited via:

```
grep -rEh '^[[:space:]]*(from|import) ' \
    src/web src/agents src/data src/chat src/analysis src/utils \
    src/mcp src/config.py src/main.py
```

intersected with the laptop's `pipPackages` block in `flake.nix` and
the laptop's `pythonEnv` set. Everything below is what the
**deployed** code (web + CLI shared modules) actually imports at
runtime; dev-only deps (pytest, ruff, mypy, jupyter, ipython,
notebook, mplfinance, etc.) are excluded.

The pip-only deps in the laptop's pipPackages that are NOT
imported anywhere under `src/` were excluded from this list
(16 entries — the "four" this sentence originally claimed was
never right):
`polygon-api-client`, `finnhub-python`, `mibian`, `crewai`,
`langchain*`, `langgraph`, `chromadb`, `sentence-transformers`,
`backtrader`, `bt`, `finviz`, `newspaper3k`, `anthropic`, `respx`,
`mplfinance`, `ta`. These were superseded earlier by direct
aiohttp/httpx clients (polygon, finnhub) or by claude-agent-sdk
(crewai/langchain/langgraph/anthropic), or are dev/test only.

## In nixpkgs (use python312Packages.<name>)

| import name        | pypi name           | nixpkgs attr          | verified version |
| ------------------ | ------------------- | --------------------- | ---------------- |
| aiohttp            | aiohttp             | aiohttp               | 3.13.3           |
| aiosqlite          | aiosqlite           | aiosqlite             | 0.21.0           |
| asyncio_throttle   | asyncio-throttle    | asyncio-throttle      | 1.0.2            |
| cryptography       | cryptography        | cryptography          | 46.0.5           |
| fastapi            | fastapi             | fastapi               | 0.116.1          |
| feedparser         | feedparser          | feedparser            | 6.0.12           |
| httpx              | httpx               | httpx                 | 0.28.1           |
| mcp                | mcp                 | mcp                   | 1.15.0           |
| numpy              | numpy               | numpy                 | 2.3.4            |
| pandas             | pandas              | pandas                | 2.3.1            |
| pandas_ta          | pandas-ta           | pandas-ta             | 0.3.14           |
| pydantic           | pydantic            | pydantic              | 2.11.7           |
| pydantic_settings  | pydantic-settings   | pydantic-settings     | 2.10.1           |
| rich               | rich                | rich                  | 14.1.0           |
| scipy              | scipy               | scipy                 | 1.16.3           |
| starlette          | starlette           | starlette             | 0.47.2           |
| textblob           | textblob            | textblob              | 0.19.0           |
| typer              | typer               | typer                 | 0.19.2           |
| uvicorn            | uvicorn[standard]   | uvicorn               | 0.35.0           |
| yaml               | pyyaml              | pyyaml                | 6.0.3            |
| yfinance           | yfinance            | yfinance              | 0.2.66           |
| dotenv             | python-dotenv       | python-dotenv         | 1.1.1            |

## In existing vulcan overlay (use final.python312Packages.<name>)

The vulcan host's overlay already injects these via
`pythonPackagesExtensions` in `overlays/default.nix`:

| import name        | pypi name           | overlay attr         |
| ------------------ | ------------------- | -------------------- |
| py_vollib          | py_vollib           | py_vollib            |

Reuse rather than redefine. The overlay also provides
`py_lets_be_rational` as a transitive of `py_vollib`.

## Needs buildPythonPackage override (pkgs/python-overrides/)

| import name           | pypi name            | reason                              |
| --------------------- | -------------------- | ----------------------------------- |
| claude_agent_sdk      | claude-agent-sdk     | not in nixpkgs                      |
| fredapi               | fredapi              | not in nixpkgs                      |
| vaderSentiment        | vaderSentiment       | not in nixpkgs                      |

## Native dependency

None at runtime. The laptop dev environment uses ta-lib (C lib) for
mplfinance plotting, but the deployed code uses `pandas_ta` (pure
Python) only. No `LD_LIBRARY_PATH` ta-lib wiring needed.

## Notes on dynamic / lazy imports

- `fredapi` is imported lazily inside `FREDClient.__init__` only
  when `FRED_API_KEY` is set (`from fredapi import Fred`). It must
  still be in the python env so the import doesn't fail.
- `vaderSentiment.vaderSentiment.SentimentIntensityAnalyzer` and
  `textblob.TextBlob` are imported at module top of
  `src/analysis/sentiment.py`, used by `SentimentAnalystAgent`
  which itself is lazy-instantiated only when sentiment queries
  arrive.
- The `src/data/schwab_*` modules use `httpx` directly — no
  external `schwab-py` library is imported at runtime.
- The standalone MCP server `src/mcp/finance_tools.py` imports
  `from mcp.server import Server` and `from mcp.server.stdio import
  stdio_server`; nixpkgs `python312Packages.mcp` 1.15.0 provides
  both.
