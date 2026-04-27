# stock-trader: top-level derivation composing the runtime Python env,
# the React SPA bundle, and a wrapped uvicorn entry point.
#
# Output layout:
#   $out/bin/stock-trader                 — wrapped script (PYTHONPATH set)
#   $out/share/stock-trader/src/...        — Python package source
#   $out/share/stock-trader/web/dist/...   — frontend bundle
#
# The wrapper resolves $STOCK_TRADER_HOST and $STOCK_TRADER_PORT in real
# shell at run time (defaulting to 127.0.0.1:8234) before exec'ing
# uvicorn. `makeWrapper --add-flags` would not work here because it
# passes args through argv verbatim, with no shell expansion — uvicorn
# would receive the literal string `${STOCK_TRADER_HOST:-127.0.0.1}` as
# `--host`. Driving the entry point through a `writeShellScript` that
# does the env-var resolution (and `exec`s uvicorn) is the
# nixos-rebuild-friendly fix.
{
  lib,
  stdenv,
  writeShellScript,
  makeWrapper,
  python312,
  src,
  version,
  frontend,
  pythonOverrides,
  # Vulcan's overlay already provides py_vollib via pythonPackagesExtensions,
  # so it's reachable as python312Packages.py_vollib here.
}:

let
  # Compose runtime Python deps. The "in nixpkgs" set comes from the
  # audit (pkgs/stock-trader.deps.md); the override set is supplied by
  # the host overlay (pkgs/python-overrides/default.nix).
  pythonEnv = python312.withPackages (
    ps:
    with ps;
    [
      # Web framework + ASGI
      fastapi
      uvicorn
      starlette

      # Validation / config
      pydantic
      pydantic-settings

      # HTTP clients
      httpx
      aiohttp

      # Storage
      aiosqlite

      # Crypto (used by schwab_auth)
      cryptography

      # Data science
      pandas
      numpy
      scipy
      pandas-ta

      # Options analytics — comes from the existing vulcan overlay's
      # pythonPackagesExtensions (overlays/default.nix), which adds
      # py_vollib to every Python package set.
      py_vollib

      # Market data clients
      yfinance

      # News / RSS
      feedparser

      # NLP
      textblob

      # MCP server
      mcp

      # Misc
      asyncio-throttle
      python-dotenv
      pyyaml
      rich
      typer
    ]
    # Pip-only overrides (claude-agent-sdk, fredapi, vaderSentiment).
    ++ builtins.attrValues pythonOverrides
  );

  # Real shell-resolution for $STOCK_TRADER_HOST / $STOCK_TRADER_PORT,
  # then exec uvicorn. Single quotes around the env-var defaults are
  # intentional to keep `set -u` happy. The doubled-`''` (`''${...}`)
  # is Nix indented-string escaping for a literal `${...}` to keep it
  # from being interpreted as Nix antiquotation.
  uvicornStarter = writeShellScript "stock-trader-uvicorn" ''
    set -euo pipefail
    HOST="''${STOCK_TRADER_HOST:-127.0.0.1}"
    PORT="''${STOCK_TRADER_PORT:-8234}"
    exec ${pythonEnv}/bin/uvicorn \
      --factory src.web.app:create_app \
      --host "$HOST" \
      --port "$PORT"
  '';
in
stdenv.mkDerivation {
  pname = "stock-trader";
  inherit version src;

  nativeBuildInputs = [ makeWrapper ];

  # No compile step: copy source + frontend into $out and wrap the
  # uvicornStarter script.
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # Source tree: copy src/ verbatim. PYTHONPATH below points here.
    mkdir -p $out/share/stock-trader
    cp -r src $out/share/stock-trader/

    # Frontend bundle: place the SPA at share/stock-trader/web/dist/
    # so the systemd unit's STOCK_TRADER_STATIC_DIR can point at it.
    mkdir -p $out/share/stock-trader/web
    cp -r ${frontend} $out/share/stock-trader/web/dist

    # Wrap the shell starter so PYTHONPATH is set before the env-var
    # resolution + uvicorn exec runs. No LD_LIBRARY_PATH wiring needed
    # — pandas-ta is pure Python; the project does not require ta-lib
    # at runtime.
    mkdir -p $out/bin
    makeWrapper ${uvicornStarter} $out/bin/stock-trader \
      --set PYTHONPATH "$out/share/stock-trader"

    runHook postInstall
  '';

  meta = with lib; {
    description = "stock-trader web service (FastAPI + React SPA)";
    homepage = "https://gitea.vulcan.lan/johnw/stock-trader";
    license = licenses.mit;
    mainProgram = "stock-trader";
  };
}
