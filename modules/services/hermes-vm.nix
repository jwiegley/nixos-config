# Guest config for the Hermes Agent microVM.
# Imported by modules/services/hermes-microvm.nix via microvm.vms.hermes.config.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  apiServerPort,
  bridgeAddr,
  vmAddr,
  vmHostname,
  hermesUid,
  hermesGid,
  stateDir,
  tapName,
  secretsStagingDir,
  dnatPortList,
  ...
}:
let
  # Single source of truth for LLM selection: the `reasoning` tier in
  # /etc/nixos/models.nix. Edit that file to change Hermes' model.
  #
  # NOT `llm.agent`. That tier existed for a second agent VM, had no consumer
  # once Hermes moved to `reasoning`, and was removed 2026-08-05 -- but two
  # comments here (including this one) had gone on naming it, so anyone
  # following them edited a value nothing read and saw no effect.
  models = import ../../models.nix;
  agentModel = models.llm.reasoning.name;

  # System CA bundle inside the VM. security.pki.certificates (below) bakes
  # the Vulcan Step-CA root into this file at build time. The stdio MCP
  # children do NOT inherit the agent's environment — hermes-agent loads
  # ${stateDir}/env as an internal dotenv at Python startup rather than via a
  # systemd EnvironmentFile, so a child's os.environ starts effectively empty
  # except for the per-server `env` attrset below. Python `requests` (used by
  # the trader and vane MCP scripts) then resolves its trust store via the
  # nixpkgs-patched certifi, which falls back to certifi's *vendored* Mozilla
  # bundle (no Vulcan CA) unless redirected. Empirically (2026-05-29) certifi
  # honors REQUESTS_CA_BUNDLE and NIX_SSL_CERT_FILE but NOT SSL_CERT_FILE, so
  # every HTTPS-to-internal-CA server must carry these two explicitly or its
  # tool calls fail with `CERTIFICATE_VERIFY_FAILED`. OpenClaw avoids this
  # because mcporter spawns its children with the full VM env inherited.
  vulcanCaBundle = "/etc/ssl/certs/ca-certificates.crt";

  # ── Local extract provider (user plugin) ───────────────────────────────
  # Hermes splits the web capability in two: `web.search_backend` and
  # `web.extract_backend`, with providers declaring supports_search() /
  # supports_extract() independently. SearXNG (configured below) is
  # search-ONLY — its bundled provider returns supports_extract() = False and
  # its docstring says to "pair with an extract provider for web_extract
  # calls". Every extract-capable backend Hermes ships (exa, firecrawl,
  # parallel, tavily) requires a PAID api key, so without this the agent can
  # find pages but never read them.
  #
  # FULLY LOCAL, by operator requirement (2026-08-02). This briefly used hosted
  # r.jina.ai, which worked but disclosed every extracted URL and its content
  # to a third party. trafilatura keeps the whole web path on this network —
  # SearXNG is self-hosted, and now so is extraction.
  #
  # trafilatura over the alternatives: no browser (Crawl4AI and self-hosted
  # Jina Reader each want a headless Chromium per extraction, which this
  # memory-constrained aarch64 host cannot afford), native markdown output, and
  # the best boilerplate rejection of the non-browser extractors — F1 0.945 on
  # the ScrapingHub article benchmark vs readability-lxml's 0.922, and well
  # ahead of the hosted Jina Reader it replaces (~0.86 vs ~0.64 published, at
  # roughly half the character count, which is context-window budget).
  # Verified built and RUN on this aarch64 host: 2.0.0, substituted from
  # cache.nixos.org with no lxml compile.
  #
  # The worker is a SUBPROCESS in its own python env, not an import. Adding
  # trafilatura to services.hermes-agent.extraPythonPackages does not merely
  # bloat the agent — it FAILS THE BUILD. hermes-agent seals its venv and
  # hermes-agent.nix aborts when an extra package collides by name with a
  # sealed one; trafilatura's closure carries certifi, urllib3 and
  # charset-normalizer, and all three are already sealed in. Same reasoning as
  # the lightPython/financialPython MCP environments below.
  extractPython = pkgs.python3.withPackages (ps: [ ps.trafilatura ]);

  localExtractWorker = pkgs.runCommand "hermes-local-extract-worker" { } ''
    mkdir -p "$out/bin"
    # tail -n +2 drops the source file's `#!/usr/bin/env python3`, replacing it
    # with the exact interpreter so the worker never resolves python from PATH.
    {
      printf '#!%s\n' "${extractPython}/bin/python3"
      tail -n +2 ${../../pkgs/hermes-local-extract/extract_worker.py}
    } > "$out/bin/hermes-local-extract-worker"
    chmod +x "$out/bin/hermes-local-extract-worker"
  '';

  # Installed as a USER plugin rather than patched into the bundled tree, so a
  # hermes-agent version bump cannot silently drop it. Bundled `kind: backend`
  # plugins auto-load, but user plugins are opt-in — hence `plugins.enabled` in
  # settings below. Both are required; either alone is a no-op.
  # ── Qdrant memory provider (user plugin) ───────────────────────────────
  # VENDORED from github.com/qdrant-labs/hermes-agent-memory-qdrant at rev
  # c350be1e843de820966f5a1db52b29b22b7775b9 (main HEAD, 2026-06-30), with three
  # files changed. Vendored rather than fetchFromGitHub + patches because that
  # repo is five weeks old with two commits, no tags and no releases: a patch
  # stack would rot on its first push, and we rewrite enough that a fork is the
  # honest representation. Licence: pyproject.toml declares Apache-2.0, but the
  # repo ships no LICENSE file and the GitHub API reports license:null.
  #
  # What changed and why (all three are forced, not preference):
  #   embeddings.py  REWRITTEN. Upstream embeds locally with fastembed, whose
  #                  nixpkgs package is badPlatforms=[aarch64-linux] in BOTH the
  #                  pinned tree and unstable HEAD, and which would run ONNX
  #                  inference inside this guest -- something this host must
  #                  never do. Dense vectors now come from the LLM gateway's
  #                  /v1/embeddings (hera serves the model); sparse vectors are
  #                  stateless local BM25 arithmetic with Qdrant applying IDF.
  #   qdrant_rest.py NEW. Upstream uses qdrant-client, which cannot be delivered
  #                  here: hermes-agent.nix fails the build when an
  #                  extraPythonPackages entry collides by name with its sealed
  #                  venv, and qdrant-client's closure collides on fifteen. This
  #                  is an httpx-backed shim over Qdrant's REST API covering
  #                  exactly the 8 methods and 14 model classes used.
  #   store.py /     Import lines only, redirected at the shim, plus an
  #   retrieval.py   api_key_file addition so the existing SOPS `qdrant/api-key`
  #                  can be reused instead of copying it into hermes/env.
  #
  # Net effect: ZERO new Python dependencies (httpx and pyyaml are already in
  # the sealed venv) and no local inference.
  qdrantMemoryPlugin = pkgs.runCommand "hermes-qdrant-memory" { } ''
    mkdir -p "$out/src"
    cp ${../../pkgs/hermes-qdrant-memory/plugin.yaml} "$out/plugin.yaml"
    cp ${../../pkgs/hermes-qdrant-memory/__init__.py} "$out/__init__.py"
    for f in __init__.py config.py default_config.yaml embeddings.py extraction.py \
             qdrant.py qdrant_rest.py retrieval.py store.py tools.py; do
      cp ${../../pkgs/hermes-qdrant-memory/src}/$f "$out/src/$f"
    done
  '';

  # services.hermes-agent.extraPlugins symlinks each plugin as
  # nix-managed-<derivation-name>, and memory.provider is resolved by
  # find_provider_dir() as a LITERAL DIRECTORY LOOKUP (`user_dir / name`) --
  # plugin.yaml's `name:` is never parsed for this. Deriving the value from the
  # derivation itself is what stops the two from silently desyncing; a mismatch
  # produces a debug-level log line and no memory, with nothing else to see.
  qdrantMemoryProvider = "nix-managed-${lib.getName qdrantMemoryPlugin}";

  localExtractPlugin = pkgs.runCommand "hermes-local-extract-plugin" { } ''
    mkdir -p "$out"
    cp ${../../pkgs/hermes-local-extract/plugin.yaml} "$out/plugin.yaml"
    cp ${../../pkgs/hermes-local-extract/__init__.py} "$out/__init__.py"
    substitute ${../../pkgs/hermes-local-extract/provider.py} "$out/provider.py" \
      --replace-fail '@worker@' '${localExtractWorker}/bin/hermes-local-extract-worker'
  '';

  # ── Python environments for the stdio MCP servers ──────────────────────
  # Hermes spawns each MCP server as a child process running one of these
  # interpreters on an absolute store path. `lightPython` covers the simple
  # servers (vane, email-contacts, perplexity, org-db); `financialPython`
  # carries the heavy numeric stack that only stock-trader-mcp.py needs.
  #
  # The vane / email-contacts / stock-trader scripts are shared verbatim with
  # OpenClaw (same files under ../../scripts), so the interpreter package sets
  # must match what those scripts import. perplexity-mcp.py and org-db-mcp.py
  # are Hermes-only (OpenClaw has a built-in Perplexity tool and reaches org
  # through the orgDbSearch wrapper). `psycopg2` is required by org-db-mcp.py's read-only
  # org_sql (requests cannot speak the PostgreSQL wire protocol).
  lightPython = pkgs.python312.withPackages (ps: [
    ps.mcp
    ps.requests
    ps.simplejson
    ps.psycopg2
  ]);

  # canonical copy in the removed OpenClaw microVM module
  financialPython = pkgs.python312.withPackages (ps: [
    ps.mcp
    ps.pandas
    ps.numpy
    ps.scipy
    ps.matplotlib
    ps.requests
    ps.yahooquery
    ps.py_vollib
    ps.simplejson
  ]);

  # canonical copy in the removed OpenClaw microVM module
  khardFixed = pkgs.khard.overrideAttrs (_: {
    dontCheckRuntimeDeps = true;
  });

  # ── MCP server wrapper scripts ─────────────────────────────────────────
  # Each wrapper sets the env the corresponding script expects, then exec's
  # the right Python interpreter on the script's absolute store path. These
  # mirror the removed OpenClaw VM config's *McpServer wrappers; Hermes registers them via
  # services.hermes-agent.mcpServers.<name>.command below. The scripts are
  # referenced as Nix paths so they land in the store (shared into the VM
  # via the ro-store virtiofs mount).

  # Vane (Perplexica) MCP server: AI-synthesized answers with citations,
  # talking to the host vane container via nginx HTTPS. TLS is verified
  # against the Vulcan Step-CA already trusted in the VM via
  # security.pki.certificates. The script never logs the /api/config body
  # because it carries the gateway apiKey.
  vaneMcpScript = ../../scripts/vane-mcp.py;
  vaneMcpServer = pkgs.writeShellScript "vane-mcp" ''
    export VANE_BASE_URL="https://vane.vulcan.lan"
    # 10 min HTTP timeout — Vane synthesis can take several minutes when the
    # focus_mode does deep retrieval.
    export VANE_TIMEOUT_S=600
    exec ${lightPython}/bin/python3 ${vaneMcpScript}
  '';

  # Stock-trader MCP server: quotes, technical analysis, options strategies.
  # Talks to https://trader.vulcan.lan via the bridge gateway DNAT. Uses the
  # heavy financialPython interpreter (yahooquery / py_vollib / pandas).
  stockTraderMcpScript = ../../scripts/stock-trader-mcp.py;
  stockTraderMcpServer = pkgs.writeShellScript "stock-trader-mcp" ''
    export STOCK_TRADER_BASE_URL="https://trader.vulcan.lan"
    exec ${financialPython}/bin/python3 ${stockTraderMcpScript}
  '';

  # Email + contacts MCP server: IMAP read/search + SMTP send (Dovecot /
  # Postfix via the two-stage DNAT) and khard contact lookup. Puts khard on
  # PATH and points XDG_CONFIG_HOME at the read-write state share so the
  # script finds the khard.conf written by hermes-tools-setup. The IMAP
  # password is read at command time from the staged secret file.
  emailMcpScript = ../../scripts/email-contacts-mcp.py;
  emailMcpServer = pkgs.writeShellScript "email-contacts-mcp" ''
    export PATH="${khardFixed}/bin:$PATH"
    export XDG_CONFIG_HOME="${stateDir}/.config"
    exec ${lightPython}/bin/python3 ${emailMcpScript}
  '';

  # Perplexity MCP server: web answers via the public Perplexity API over
  # the already-allowed 443 egress. The API key is exported from the staged
  # secret file so it never appears in the unit env or the Nix store.
  perplexityMcpScript = ../../scripts/perplexity-mcp.py;
  perplexityMcpServer = pkgs.writeShellScript "perplexity-mcp" ''
    set -eu
    KEY_FILE="/run/hermes-secrets/perplexity-api-key"
    if [ ! -r "$KEY_FILE" ]; then
      echo "perplexity-mcp: API key not readable at $KEY_FILE" >&2
      exit 1
    fi
    export PERPLEXITY_API_KEY="$(cat "$KEY_FILE")"
    exec ${lightPython}/bin/python3 ${perplexityMcpScript}
  '';

  # org-db MCP server: read-only org-mode access. org_sql connects to
  # PostgreSQL (org database, read-only role `openclaw`) over the 5432 DNAT
  # via psycopg2/libpq; org_search shells `org db search` against the LLM gateway
  # embeddings. The PG password is exported from the staged secret; the
  # PG* defaults match the host's org-db-search wrapper. org_search also
  # needs OPENROUTER_API_KEY (the gateway key) and ORG_CONFIG. We do
  # NOT rely on inheriting OPENROUTER_API_KEY from the hermes-agent parent:
  # hermes-agent has no systemd EnvironmentFile= — it loads ${stateDir}/env
  # as an internal dotenv at Python startup, so the key is not guaranteed to
  # be in os.environ of spawned stdio MCP children (org_search would then
  # fall back to `--api-key unused` and every embedding call would 401).
  # Instead we source the SAME gateway key Hermes already holds out
  # of ${stateDir}/env (no new SOPS secret, no widened secret surface) and
  # export it ourselves — mirroring how the removed OpenClaw microVM module's orgDbSearch
  # reads its key from its own config rather than trusting env
  # inheritance. ORG_CONFIG points at the khard-style config written by
  # hermes-tools-setup.
  orgDbMcpScript = ../../scripts/org-db-mcp.py;
  orgDbMcpServer = pkgs.writeShellScript "org-db-mcp" ''
    set -eu
    # org_search shells the bare `org` binary; put org-jw on PATH so it
    # resolves (matches the removed OpenClaw microVM module's orgDbSearch wrapper).
    export PATH="${pkgs.org-jw}/bin:$PATH"
    export PGHOST=127.0.0.1
    export PGPORT=5432
    export PGDATABASE=org
    export PGUSER=openclaw
    PW_FILE="/run/hermes-secrets/org-db-password"
    if [ -r "$PW_FILE" ]; then
      export PGPASSWORD="$(cat "$PW_FILE")"
    fi
    # Source OPENROUTER_API_KEY (the gateway key) from the same
    # dotenv hermes-agent itself reads, so org_search's `org db search`
    # subprocess authenticates to the gateway regardless of whether the key is
    # present in this wrapper's inherited env. Match the first assignment
    # only; strip optional surrounding quotes with shell parameter
    # expansion (no embedded quote chars in this Nix string). Never echo
    # the value.
    ENV_FILE="${stateDir}/env"
    if [ -r "$ENV_FILE" ]; then
      _ork="$(${pkgs.gnused}/bin/sed -n \
        's/^[[:space:]]*OPENROUTER_API_KEY[[:space:]]*=[[:space:]]*//p' \
        "$ENV_FILE" | ${pkgs.coreutils}/bin/head -n1)"
      _ork="''${_ork%\"}"
      _ork="''${_ork#\"}"
      _ork="''${_ork%\'}"
      _ork="''${_ork#\'}"
      if [ -n "$_ork" ]; then
        export OPENROUTER_API_KEY="$_ork"
      fi
      unset _ork
    fi
    export ORG_CONFIG="${stateDir}/.config/org/config.yaml"
    exec ${lightPython}/bin/python3 ${orgDbMcpScript}
  '';

  # Stdio bridge from Hermes's MCP client to Home Assistant's streamable
  # HTTP MCP server. Mirrors the removed OpenClaw VM config's homeAssistantMcpBridge: we
  # use mcp-proxy with a static Bearer header rather than a direct HTTP
  # connection because clients that auto-probe OAuth metadata fail against
  # HA (no RFC 7591 dynamic client registration). The token is read from
  # the staged secret at startup so it never lands in the unit env or the
  # Nix store. It connects by IP to http://127.0.0.1:8123/api/mcp, reached
  # via the 8123 DNAT (the hass.vulcan.lan hosts entry is unused by this
  # path). The token does briefly appear in the spawned mcp-proxy argv
  # (visible to the hermes user via /proc/<pid>/cmdline only) — the same
  # accepted trade-off OpenClaw makes.
  haBridge = pkgs.writeShellScript "mcp-proxy-ha-bridge" ''
    set -eu
    TOKEN_FILE="/run/hermes-secrets/home-assistant-token"
    if [ ! -r "$TOKEN_FILE" ]; then
      echo "mcp-proxy-ha-bridge: token not readable at $TOKEN_FILE" >&2
      exit 1
    fi
    exec ${pkgs.mcp-proxy}/bin/mcp-proxy \
      --transport=streamablehttp \
      --stateless \
      --headers Authorization "Bearer $(cat "$TOKEN_FILE")" \
      "http://127.0.0.1:8123/api/mcp"
  '';

  # Python startup shims injected into the hermes-agent process via a
  # `sitecustomize.py` on PYTHONPATH — Python's `site` init auto-imports it
  # before `bin/hermes` runs, so both patches land before openai/run_agent
  # and discord.py do their work. Two shims:
  #
  #   1. httpx.Timeout workaround for upstream hermes-agent v0.13.0 timeout
  #      defaults that the configured `request_timeout_seconds` /
  #      `HERMES_STREAM_READ_TIMEOUT` don't actually override at the httpx
  #      layer. (Written against v0.13.0; the pinned flake input builds
  #      hermes-agent 0.15.1 as of 2026-07-27, so re-verify the upstream line
  #      references below — and whether the shim is still needed — against
  #      that tree.) Two paths confirmed broken in v0.13.0:
  #        - run_agent.py:7789-7794 builds the streaming `httpx.Timeout(...)`
  #          with hardcoded `connect=30.0` / `pool=30.0` — not exposed via
  #          any documented config knob.
  #        - The same site sets `read=_stream_read_timeout`, falling back to
  #          `float(os.getenv("HERMES_STREAM_READ_TIMEOUT", 120.0))`. Observed
  #          live: even with 600 set everywhere the firing timeout is ~134s.
  #      Bump only those exact documented defaults (30→600 connect/pool,
  #      120→600 read) so we don't silently lengthen user-chosen short
  #      timeouts elsewhere (e.g. the Gemini adapter's explicit 15s connect).
  #
  #   2. Discord WS heartbeat-ACK liveness stamp. discord.py 2.7.1's
  #      `KeepAliveHandler.ack()` (discord/gateway.py:217) runs on every
  #      HEARTBEAT_ACK from Discord (~every 41s while the gateway WS is
  #      healthy). The heartbeat *send* fires on a timer regardless of
  #      connection health, so only the ACK proves the socket is truly
  #      alive. We wrap ack() to atomically stamp a wall-clock timestamp
  #      into the heartbeat file; the host-side hermes-health-check reads
  #      its age. A stale stamp means acks have stopped = a genuine zombie,
  #      and — crucially — heartbeats flow even with zero message traffic,
  #      so an idle server can no longer trip the detector. Replaces the
  #      old gateway.log-idleness heuristic that forced a VM restart
  #      roughly daily on a quiet bot. Non-fatal: if discord.py's API
  #      changed, the health check falls back to the gateway.log scrape.
  hermesPyShim = pkgs.writeTextDir "sitecustomize.py" ''
    """Hermes-agent Python startup shims — see hermes-vm.nix."""
    import os
    import time

    # ---- Shim 1: httpx.Timeout workaround (hermes-agent v0.13.0) ----
    try:
        import httpx as _httpx

        _orig_init = _httpx.Timeout.__init__

        def _patched_init(self, *args, **kwargs):
            _orig_init(self, *args, **kwargs)
            try:
                if getattr(self, "connect", None) == 30.0:
                    self.connect = 600.0
                if getattr(self, "pool", None) == 30.0:
                    self.pool = 600.0
                if getattr(self, "read", None) == 120.0:
                    self.read = 600.0
            except Exception:
                pass

        _httpx.Timeout.__init__ = _patched_init
    except Exception:
        # Don't block Hermes startup if httpx isn't importable yet.
        pass

    # ---- Shim 2: Discord WS heartbeat-ACK liveness stamp ----
    _HEARTBEAT_FILE = "${stateDir}/.hermes/logs/discord_ws_heartbeat"

    def _stamp_discord_heartbeat():
        try:
            os.makedirs(os.path.dirname(_HEARTBEAT_FILE), exist_ok=True)
            tmp = _HEARTBEAT_FILE + ".tmp"
            with open(tmp, "w") as _f:
                _f.write(repr(time.time()))
            os.replace(tmp, _HEARTBEAT_FILE)
        except Exception:
            pass

    try:
        import discord.gateway as _dgw

        _orig_ack = _dgw.KeepAliveHandler.ack

        def _patched_ack(self):
            _stamp_discord_heartbeat()
            return _orig_ack(self)

        _dgw.KeepAliveHandler.ack = _patched_ack
    except Exception:
        pass
  '';

  # In-VM watchdog: detects a frozen/CPU-starved api_server and captures a
  # /proc-based per-thread stack dump of the gateway (py-spy does not build on
  # aarch64 here — see the unit below) BEFORE self-heal restarts the microVM
  # (which SIGKILLs the frozen process and destroys the evidence). Loaded from
  # a repo file so the bash is reviewable and unit-testable on its own; PATH is
  # supplied by the systemd unit below. See scripts/hermes-hang-capture.sh.
  hangCapture = pkgs.writeShellScript "hermes-hang-capture" (
    builtins.readFile ../../scripts/hermes-hang-capture.sh
  );

  # Deletes mcp_servers entries that the Nix config no longer declares.
  # Rationale in the activationScripts.hermes-prune-stale-mcp comment below.
  #
  # Same interpreter derivation as the upstream merge script, so this adds
  # nothing to the guest closure. Ownership and mode are restored explicitly:
  # upstream chowns the file immediately after merging, and this runs after
  # that, so a fresh root-owned file would otherwise be left behind.
  pruneStaleMcpServers = pkgs.writeScript "hermes-prune-stale-mcp" ''
    #!${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3
    import os, sys, yaml
    from pathlib import Path

    path, keep = Path(sys.argv[1]), set(sys.argv[2:])
    if not path.exists():
        sys.exit(0)

    cfg = yaml.safe_load(path.read_text()) or {}
    servers = cfg.get("mcp_servers")
    if not isinstance(servers, dict):
        sys.exit(0)

    stale = sorted(set(servers) - keep)
    if not stale:
        sys.exit(0)
    for name in stale:
        del servers[name]

    st = path.stat()
    tmp = path.parent / (path.name + ".prune")
    with open(tmp, "w") as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    tmp.replace(path)
    print("hermes: pruned stale mcp_servers: " + ", ".join(stale))
  '';
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  # ---- Basic guest config ----
  system.stateVersion = "25.11";
  networking.hostName = vmHostname;
  networking.useNetworkd = true;
  networking.enableIPv6 = false;
  boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  boot.kernel.sysctl."net.ipv6.conf.default.disable_ipv6" = 1;

  # Disable systemd-timesyncd. The host-side egress firewall (see
  # hermes-microvm.nix) only allows TCP/UDP 53 and 443 outbound, so NTP
  # to 0.nixos.pool.ntp.org gets dropped and floods the kernel log with
  # hermes-egress-rejected entries (~1000/day). The VM's clock is
  # driven by kvm-clock from the host, which is already accurate.
  services.timesyncd.enable = false;
  # Allow routing 127.0.0.0/8 traffic on non-loopback interfaces.
  # Required for the nftables OUTPUT DNAT below that rewrites localhost
  # connections to the host bridge IP — without this, the kernel
  # refuses to route packets with source 127.0.0.1 via eth0.
  # Matches the removed OpenClaw VM config.
  boot.kernel.sysctl."net.ipv4.conf.all.route_localnet" = 1;

  # ---- Guest resources ----
  # microvm.nix default is 512 MiB. Python+discord.py running the full
  # agent runtime has OOM-killed at 512 MiB under load (anon-rss:191 MiB
  # python3.12 on top of ~250 MiB kernel+systemd). 3 GiB gives the agent
  # process headroom AND room for the concurrent stdio MCP servers
  # (each spawns its own python3.12; financialPython for stock-trader
  # pulls in the heavy numeric stack), which add real memory pressure
  # on top of the gateway. Was 1024 before the MCP-server parity work.
  # NOTE: must NOT be exactly 2048 — microvm.nix/QEMU hangs at exactly 2 GiB
  # (microvm-nix/microvm.nix#171), so 3072 both avoids that trap and adds
  # headroom for the MCP servers.
  microvm.mem = 3072;

  # vCPU intentionally left at the microvm.nix default (1).
  #
  # A 4-vCPU bump (614b191) was tried 2026-05-31 to "fix" the recurring
  # HermesApiServerDown alert, on the theory that serial init on one core
  # pushed the api_server cold-start to ~10 min. That premise was wrong: the
  # api_server BINDS in ~8s regardless of vCPU, and deploying 4 vCPU did not
  # change the ~8-min /v1/capabilities warmup (it is gated on the gateway/MLX
  # model backend, not local CPU). The real driver was a 5-min health-check
  # sample feeding a 5-min `for:` window over that warmup; fixed by widening
  # HermesApiServerDown to `for: 15m` (see monitoring/alerts/hermes.yaml). So
  # 4 vCPU is reverted. If genuine runtime freezes under load recur on one
  # core, hermes-hang-capture (below) records the frozen thread state —
  # revisit vCPU with that evidence, not on theory.

  # ---- Guest networking ----
  microvm.interfaces = [
    {
      type = "tap";
      id = tapName; # threaded from hermes-microvm.nix via _module.args
      mac = "02:00:00:0c:1a:02";
    }
  ];
  # Match `e*` (not just `eth*`) — the kernel may assign an `en*` predictable
  # name to the virtio-net interface. OpenClaw uses the same prefix at
  # the removed OpenClaw VM config.
  systemd.network.networks."10-eth" = {
    matchConfig.Name = "e*";
    address = [ "${vmAddr}/30" ];
    routes = [ { Gateway = bridgeAddr; } ];
  };
  networking.nameservers = [ bridgeAddr ];

  # Override *.vulcan.lan hostnames to point at the bridge gateway so the
  # MCP servers reach host services directly. The host egress filter blocks
  # 192.168.0.0/16, so normal DNS resolution (the real LAN IP) is
  # unreachable; pointing these names at the gateway routes them through the
  # two-stage DNAT instead. Mirrors the removed OpenClaw VM config's networking.hosts.
  # searxng/vane/trader/imap/smtp/radicale are load-bearing (the scripts use
  # the hostnames); hass.vulcan.lan is included for consistency but is
  # unused — the HA bridge connects to 127.0.0.1:8123 by IP via the DNAT.
  networking.hosts = {
    ${bridgeAddr} = [
      "searxng.vulcan.lan" # SearXNG metasearch (native web backend, via nginx 443)
      "vane.vulcan.lan" # Vane AI answer engine (via nginx 443)
      "trader.vulcan.lan" # stock-trader service (via nginx 443)
      "imap.vulcan.lan" # Dovecot IMAPS (via DNAT 10.99.1.1:993 → 127.0.0.1:993)
      "smtp.vulcan.lan" # Postfix SMTP (via DNAT 10.99.1.1:2525 → 127.0.0.1:2525)
      "radicale.vulcan.lan" # Radicale CardDAV (via DNAT 10.99.1.1:5232 → 127.0.0.1:5232)
      "hass.vulcan.lan" # Home Assistant (HA bridge uses 127.0.0.1:8123 directly)
    ];
  };

  # ---- Two-stage DNAT (stage 1: guest OUTPUT) ----
  # Hermes (and the stdio MCP servers it spawns) target host services via
  # http://127.0.0.1:PORT unchanged. This OUTPUT chain rewrites those
  # connections to the bridge gateway IP, where the host's PREROUTING
  # rule (hermes-host-dnat.service) rewrites them back to 127.0.0.1
  # on the host. The port set is threaded from hermes-microvm.nix via
  # _module.args (dnatPortList) so it stays in sync with the host-side
  # PREROUTING/INPUT rules. Same shape as the removed OpenClaw VM config.
  networking.nftables.enable = true;
  networking.nftables.tables.hermes-dnat = {
    family = "ip";
    content = ''
      chain output {
        type nat hook output priority -100; policy accept;
        ip daddr 127.0.0.1 tcp dport { ${dnatPortList} } dnat to ${bridgeAddr}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Rewrite source 127.0.0.1 → VM eth0 IP for DNAT'ed packets.
        # Without this, the kernel refuses to route loopback-sourced
        # packets out of a non-loopback interface.
        oifname "e*" ip saddr 127.0.0.0/8 masquerade
      }
    '';
  };

  # ---- Virtio-fs shares ----
  # ro-store: Nix store from host (read-only) — standard microvm.nix idiom.
  # state:    /var/lib/hermes from host (read-write).
  # ro-store mountPoint is the host-store stage; microvm.nix's mounts.nix
  # bind-mounts /nix/.ro-store onto /nix/store at boot when
  # writableStoreOverlay is unset (which it intentionally is for Hermes —
  # uv2nix gives us a sealed venv at build time, no runtime store writes).
  microvm.shares = [
    {
      tag = "ro-store";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto = "virtiofs";
    }
    {
      tag = "state";
      source = stateDir;
      mountPoint = stateDir;
      proto = "virtiofs";
    }
    # hermes-secrets: SOPS-staged secret content from the host
    # (secretsStagingDir, threaded via _module.args). Read-only inside the
    # VM — the MCP wrappers and hermes-tools-setup read tokens/passwords
    # from here, but all GENERATED config files go under ${stateDir}/.config
    # (the read-write state share), never into /run/hermes-secrets.
    {
      tag = "hermes-secrets";
      source = secretsStagingDir;
      mountPoint = "/run/hermes-secrets";
      proto = "virtiofs";
    }
  ];

  # The Hermes activation script writes config.yaml, .env, and .managed
  # into ${stateDir}/.hermes/ at NixOS activation time (system.activationScripts).
  # Activation runs in stage 2 BEFORE local-fs.target — so without
  # `neededForBoot`, those writes land on the VM's tmpfs root and the
  # virtio-fs mount silently shadows them at multi-user.target. Forcing
  # the state share into initrd makes the mount visible to activation.
  #
  # Failure mode: if the host virtiofsd serving the state share is slow or
  # crash-looping, the guest will block in initrd waiting on
  # `dev-virtio\x2dfs-state.mount`. Check virtiofsd status on the host
  # (microvm-virtiofsd@hermes.service) before suspecting in-VM issues.
  fileSystems."${stateDir}".neededForBoot = lib.mkForce true;

  # ---- Prune MCP servers the operator has removed ----
  # The upstream activation (hermes-agent-setup, nixosModules.nix:721) runs
  # `hermes-config-merge`, which does `deep_merge(existing, nix)` into
  # ${stateDir}/.hermes/config.yaml. That merge NEVER DELETES: by design it
  # "preserves user-added keys". Right for a hand-added key like `onboarding`,
  # but it cannot tell a key the operator deleted from one they added, so
  # REMOVING an mcpServers entry below does not remove it from the running
  # agent. The state file keeps it forever and Hermes keeps launching it.
  #
  # Found 2026-08-06, a day after the fact: `github` and `gitea`, removed at the
  # operator's request in 3af2dabfb because their token cost was too high, were
  # still being launched. So was `memory-vault`, whose service was deleted
  # outright in efbd70fb5 -- 101 connection failures (Errno 111) in one retained
  # log, three retries deep on every session that touched MCP. The generated
  # config had 7 servers; the file the agent actually reads had 10. Verifying a
  # removal against the store path is therefore meaningless -- check the state
  # file.
  #
  # This makes the SET of mcp_servers authoritative while leaving every other
  # key to the upstream merge. Ordered after the script that writes the file.
  system.activationScripts.hermes-prune-stale-mcp = lib.stringAfter [ "hermes-agent-setup" ] ''
    ${pruneStaleMcpServers} ${stateDir}/.hermes/config.yaml ${lib.concatStringsSep " " (builtins.attrNames config.services.hermes-agent.mcpServers)}
  '';

  # ---- Vulcan CA bundle (HTTPS to internal services) ----
  # Embed the host's root CA at evaluation time so it lands in the
  # nss-cacert bundle at build time. The host used to stage a runtime copy at
  # ${stateDir}/vulcan-root-ca.crt via a tmpfiles `C+` entry; that entry was
  # dropped (commit a776481) because this readFile burns the cert content into
  # the store, so nothing needs the staged copy for trust any more. Same
  # pattern as the removed OpenClaw VM config.
  security.pki.certificates = [
    (builtins.readFile ../../certs/vulcan-root-ca.crt)
  ];

  # NOTE: the extract plugin is installed via services.hermes-agent.extraPlugins
  # (below), not a tmpfiles rule. An earlier revision hand-rolled an `L+` symlink
  # into ${stateDir}/.hermes/plugins; the upstream module has a first-class
  # option that does the same symlink (as nix-managed-<name>) with duplicate-name
  # assertions and correct ownership, so the hand-rolled entry was redundant.

  # ---- Hermes Agent service ----
  services.hermes-agent = {
    enable = true;
    user = "hermes";
    group = "hermes";
    createUser = false; # We declare the user explicitly below to match UID 932.
    stateDir = stateDir;
    addToSystemPackages = false; # Known bug #6044 with HERMES_HOME export.
    container.enable = false; # The microVM IS the sandbox.

    # Upstream restructured pyproject.toml so discord.py / telegram / slack
    # only install via the `messaging` extras group. Without this, the
    # gateway logs `Discord: discord.py not installed` and silently drops
    # the Discord adapter (observed 2026-05-22 after a flake.lock bump).
    # `mcp` adds the MCP-client deps so services.hermes-agent.mcpServers
    # (below) can actually connect to the stdio MCP servers.
    extraDependencyGroups = [
      "messaging"
      "mcp"
    ];

    # Shell tools the AGENT'S OWN scripts need. This option feeds the unit's
    # `path` (upstream nixosModules.nix:912-917), so it is what a no_agent cron
    # job — a bare shell script with no model and no tool registry — actually
    # resolves against.
    #
    # curl is here because its absence silently destroyed a job the operator
    # asked for. Hermes wrote ~/.hermes/scripts/econ_license_watch.sh to poll
    # `curl -s -k --user ... imaps://imap.vulcan.lan/INBOX` every 10 minutes and
    # ping when a vendor licence mail arrived. curl was on none of the unit's 18
    # PATH entries, so every run exited 127 into `2>/dev/null`, fell through the
    # script's `[ -z "$NEW_UIDS" ] && exit 0`, and recorded last_status=ok. 123
    # consecutive no-ops, zero IMAP connections from the guest, and a job that
    # looked healthy in `hermes cron list` the whole time.
    #
    # The failure mode generalises: an agent-authored script that shells out to
    # a binary NixOS never put on this PATH fails silently and reports success.
    # If another such job appears dead, check its interpreter's PATH before
    # believing the exit status. Audited against this script — grep, sed, head,
    # tr, cat and timeout all already resolve; curl was the only gap. gawk, jq
    # and python3 are still absent, and are the likely next casualties.
    extraPackages = with pkgs; [ curl ];

    # Directory-based plugin: the module symlinks this into
    # ${stateDir}/.hermes/plugins/nix-managed-<name> and asserts on duplicate
    # names. Still requires settings.plugins.enabled below — extraPlugins
    # installs the plugin, it does not activate it.
    #
    # Deliberately NOT extraPythonPackages: that option appends to PYTHONPATH,
    # and hermes-agent.nix FAILS THE BUILD when an extra package collides by
    # name with its sealed venv. trafilatura pulls certifi, urllib3 and
    # charset-normalizer, all three already sealed. The extractor therefore
    # ships as a subprocess with its own interpreter (localExtractWorker).
    extraPlugins = [
      localExtractPlugin
      qdrantMemoryPlugin
    ];

    environmentFiles = [ "${stateDir}/env" ];

    settings = {
      # Declarative agent config. The upstream module deep-merges this
      # into ~/.hermes/config.yaml; the `.managed` marker blocks
      # `hermes config set` so this file is the only source of truth.
      logging.level = "INFO";

      # Deliver scheduled-job output verbatim. Left at its default of `true`,
      # cron/scheduler.py wraps every delivery in a "Cronjob Response: <name>
      # (job_id: ...)" header and a "To stop or manage this job..." footer,
      # which is noise in the Discord channel where these land.
      #
      # The scheduler re-reads this from ~/.hermes/config.yaml at delivery time
      # rather than holding the value from startup, so it does NOT come from the
      # store path -- it only works because the upstream module deep-merges
      # `settings` into that file at activation. Verified against
      # cron/scheduler.py:640-661 in hermes-agent 0.15.1.
      cron.wrap_response = false;

      # NO NATIVE SEARCH BACKEND, deliberately (2026-08-05, operator's request):
      # web search goes through the PERPLEXITY MCP SERVER instead, which returns a
      # synthesised answer rather than a link list.
      #
      # This used to be `web.search_backend = "searxng"` with SEARXNG_URL set in
      # the unit environment. Both are gone, so no native provider is available:
      # firecrawl/parallel/tavily/exa/xai and brave-free all need API keys this
      # guest does not have, ddgs needs a Python package absent from the closure,
      # and searxng needs the URL. The agent therefore reaches for the Perplexity
      # tool when it searches.
      #
      # SearXNG is the NATIVE web-search backend, and it is ALSO what keeps
      # web_extract alive. Restored 2026-08-06 after removing it on 2026-08-05
      # broke more than intended. Read this before removing it again:
      #
      #   * Both web tools sit behind ONE gate. web_search
      #     (tools/web_tools.py:1326-1335) and web_extract (:1342) register with
      #     the SAME `check_fn=check_web_api_key`, and registry.get_definitions
      #     SKIPS any entry whose check_fn fails (tools/registry.py:358-364).
      #     A failing gate does not make the tool error when called -- the model
      #     never receives the schema and reports the tool as absent.
      #   * check_web_api_key (:1155-1163) consults `web.backend` and otherwise a
      #     HARDCODED list: exa, parallel, firecrawl, tavily, searxng, brave-free,
      #     ddgs, xai. It NEVER asks the plugin registry, so the nix-managed
      #     `local` extract provider cannot satisfy it. SEARXNG_URL is the only
      #     entry on that list this guest can satisfy without a paid key.
      #
      # So dropping SEARXNG_URL silently took page-reading with it, on every
      # platform, for a day: `extract_backend = "local"` still RESOLVED, but the
      # tool was never advertised. Interactive chat masked it (the Perplexity and
      # Vane MCP tools survived), and it surfaced only when a cron job that pinned
      # `enabled_toolsets = ["web"]` was left with an empty tool list.
      #
      # Perplexity is NOT displaced by this. It is an MCP tool
      # (mcp_perplexity_web_search) in its own `mcp-perplexity` toolset
      # (tools/mcp_tool.py:3365), so it coexists: the model picks SearXNG's
      # web_search for a link list and Perplexity when it wants a synthesised
      # answer. Forcing the backend below just stops Hermes walking its default
      # list (firecrawl→parallel→tavily→exa→searxng→brave-free→ddgs) to get here.
      #
      # Reaches the host SearXNG over 443 via the bridge DNAT; TLS verifies
      # against the Vulcan root CA already trusted in the VM.
      web.search_backend = "searxng";

      # The EXTRACT half. SearXNG cannot fetch arbitrary URLs, so without this
      # `web_extract` has no provider and the agent can find pages but never
      # read them. "local" is the trafilatura provider — see the
      # localExtractPlugin comment near the top of this file for why local
      # rather than a hosted reader or one of the bundled (uniformly paid)
      # backends. Explicit config wins over availability in
      # _get_capability_backend (:182-192), so this stays "local" even though
      # searxng is now the search backend.
      web.extract_backend = "local";

      # User plugins are OPT-IN. hermes_cli/plugins.py auto-loads bundled
      # `kind: backend` plugins but gates every other source on this
      # allow-list, and treats a missing OR malformed key as "nothing
      # enabled" — so omitting this silently disables the provider instead of
      # failing loudly.
      #
      # This is plugin.yaml's `name:`, NOT the directory name. extraPlugins
      # symlinks the plugin as nix-managed-<derivation-name>, so the
      # path-derived key differs; the loader accepts either, and the manifest
      # name is the stable one.
      plugins.enabled = [ "web-local-extract" ];

      # ---- Persistent memory: Qdrant on the host ----
      # This single key is what activates the provider. Deliberately NOT also
      # listed in plugins.enabled above: memory plugins are auto-coerced to
      # kind "exclusive" by a source-text scan for "MemoryProvider" in
      # __init__.py, and that short-circuits BEFORE the plugins.enabled gate, so
      # adding it there would be a no-op that implied it mattered. Expect
      # `hermes plugins list` to say "exclusive - activate via
      # <category>.provider config"; that is correct, not a fault.
      memory.provider = qdrantMemoryProvider;

      # The plugin reads its own config from the FIXED literal key
      # `plugins.qdrant` (src/config.py hardcodes it) -- unrelated to the
      # directory name above, which is why these two differ.
      plugins.qdrant = {
        connection = {
          # Reachable from the guest only because 6333 is in dnatPorts
          # (hermes-microvm.nix). REST only; 6334/gRPC is deliberately not
          # forwarded, matching qdrant_rest.py's REST-only implementation.
          mode = "remote";
          url = "http://127.0.0.1:6333";
          # Staged 0400 hermes:hermes by hermes-prepare-secrets from the
          # EXISTING SOPS secret `qdrant/api-key` -- the same one qdrant.nix and
          # OpenClaw use. Reading the file keeps exactly one copy of the key;
          # putting it in hermes/env would create a second that desyncs on
          # rotation.
          api_key_file = "/run/hermes-secrets/qdrant-api-key";
        };
        embedding = {
          provider = "gateway";
          # models.nix is the single source of truth. The gateway's inference
          # bridge remaps whatever is asked for onto embedding.primary anyway,
          # but keeping them equal means the logs do not lie about what ran.
          model = models.embedding.primary.name;
          sparse_model = "bm25-local";
        };
        retrieval = {
          mode = "hybrid";
          top_k = 10;
          # BOTH kinds, 2026-08-04. `fact` alone excluded every stored `turn` from
          # search: the collection held 30 turns and 3 facts, so turns were
          # embedded and indexed and then filtered out of every query -- the
          # messages WERE remembered but unreachable, which is what the operator
          # observed. Adding "turn" costs no inference; it only widens the filter
          # over points already written.
          search_kinds = [
            "fact"
            "turn"
          ];
        };
        extraction = {
          # OFF for the initial deployment so the first end-to-end check is
          # deterministic: memories appear only when explicitly written, not as a
          # side effect of the LLM distilling a session. Turn on once store and
          # recall are confirmed working.
          # ENABLED 2026-08-04, completing the staged rollout. The plugin's own
          # default_config.yaml says extraction is "Deliberately OFF for the
          # initial deployment ... Turn on once the store/recall path is
          # confirmed" -- that confirmation happened (cross-session canary recall
          # verified, hermes_memory_qdrant_reachable=1, points growing), but the
          # switch-back was never made, so Hermes correctly told the operator she
          # would not transparently remember anything.
          #
          # COST, deliberately accepted: extraction calls the LLM at session
          # boundaries to distil facts, so every session end adds one inference on
          # the shared oMLX gateway. That gateway serves serially, and interactive
          # use has already pushed the ask_hermes probe past its 60s budget
          # (HermesAskFailing, 2026-08-04) -- so expect a little more of that
          # during heavy sessions. min_turns=3 spares trivial sessions entirely.
          enabled = true;
          min_turns = 3;
        };
        # Content that must never be stored.
        #
        # The scheduled canary probes were removed 2026-08-05, and these shape
        # rules were removed with them -- which was wrong. Automation was never
        # the only source of probe traffic: an operator or an agent verifying a
        # change by hand sends the same thing. Within hours of the removal, four
        # ad-hoc "Reply with exactly HERMES_OK" round-trips landed in the store
        # (7 points), evading the then-current rules on two counts: the prompt
        # was not the "single word" phrasing, and HERMES_OK holds an underscore,
        # which [A-Z]{2,20} rejects. So the rules are back, and generalised.
        #
        # Semantics, from the deployed plugin (pkgs/hermes-qdrant-memory,
        # qdrant.py _is_ignored / _write_filter_rules) -- get these wrong and a
        # pattern silently never fires:
        #   * every pattern is compiled with re.IGNORECASE, so a case-SENSITIVE
        #     subexpression needs an explicit (?-i:...) scope;
        #   * matching is `search` against the RAW text, not a whitespace-
        #     normalised copy (only `exact` sees the normalised, casefolded form);
        #   * the filter is EXCHANGE-scoped: either side matching drops both the
        #     user and the assistant row, which is why the instruction and the
        #     bare-token reply do not each need to match.
        #
        # A bad regex here is logged and skipped, never raised -- a typo
        # disables the rule silently rather than failing the build. Changes are
        # covered by tests/hermes-write-filter, which reads THIS list and runs
        # it against every probe shape seen in the wild plus real messages that
        # must survive. Editing these patterns by hand is fine; the suite pins
        # the outcome, not the wording.
        write_filter = {
          exact = [ ];
          patterns = [
            # Manual opt-out: [nomem] anywhere in a message.
            "\\[no-?mem(ory)?\\]"
            # "Reply with exactly HERMES_OK" / "Reply only with ACK" / "Reply
            # with the single word ROVER and nothing else." The ALL-CAPS token
            # is required, and is what keeps a genuine "Reply with your thoughts
            # on the pool heater" out of the net.
            "^\\s*reply\\s+(?:with|only)\\b.{0,70}?(?-i:\\b[A-Z][A-Z0-9_]{1,30}\\b).{0,40}$"
            # The bare-token reply, in either direction: ACK, ROVER, HERMES_OK,
            # HERMES_PI_OK. Underscores and digits included -- their absence is
            # what let HERMES_OK through. This does drop a genuine one-word
            # "OK"/"YES", which carries no recall value anyway.
            "^\\s*(?-i:[A-Z][A-Z0-9_]{1,30})[.!]*\\s*$"
          ];
          min_content_chars = 0;
        };
      };

      gateway = {
        enabled = true;
        platforms = [
          "discord"
          "api_server"
        ];
      };
      discord = {
        # Token, allowlists, channel scoping come from env vars
        # (DISCORD_BOT_TOKEN, DISCORD_ALLOWED_USERS,
        # DISCORD_ALLOWED_CHANNELS, DISCORD_HOME_CHANNEL,
        # DISCORD_REQUIRE_MENTION). YAML keys below are the knobs that
        # DO NOT have env-var equivalents. If an env var IS set, it
        # overrides the YAML value at runtime — so DISCORD_REQUIRE_MENTION
        # in /var/lib/hermes/env wins over `require_mention` here.
        require_mention = true;
        # auto_thread makes Hermes answer by opening a thread ON the incoming message
        # rather than posting in the channel. Keep it -- but note the consequence for the
        # round-trip canary: a thread started from a message carries the SAME snowflake as
        # that message, and thread messages do NOT appear in the parent channel's message
        # list. the removed Discord canary script therefore polls BOTH /channels/<channel>/messages
        # and /channels/<posted_message_id>/messages. Before it did, the probe read "no
        # reply within timeout" on nine consecutive runs while Hermes was answering all
        # nine correctly (agent.log: finish_reason=stop response_len=18, exactly
        # len("CANARY OK ") + an 8-hex nonce). Do NOT "fix" a red canary by turning this
        # off; check that the probe still reads the thread.
        auto_thread = true;
        reactions = true;
        allow_mentions = {
          everyone = false;
          roles = false;
          users = true;
          replied_user = true;
        };
      };
      # Model routing — Hermes consumes OPENROUTER_API_KEY and
      # OPENROUTER_BASE_URL from the env file. The model identifier is
      # pulled from /etc/nixos/models.nix (`llm.reasoning.name`, via the
      # agentModel binding at the top of this file). This said `llm.agent.name`
      # until 2026-08-05, which was wrong: that tier had no reader at all, so
      # editing it to change Hermes' model did nothing.
      #
      # IMPORTANT: in Hermes v0.14 the model field accepts either a flat
      # string OR a dict with {default, provider, base_url, api_key, ...}.
      # (Written for v0.14; the pinned flake input builds hermes-agent 0.15.1
      # as of 2026-07-27 — the upstream file:line references below have not
      # been re-verified against that tree.)
      # We use the dict form because:
      #
      #   1. The openrouter provider profile (plugins/model-providers/
      #      openrouter/__init__.py:99) hardcodes base_url to
      #      `https://openrouter.ai/api/v1` and only honors OPENROUTER_API_KEY
      #      as an env var — it ignores OPENROUTER_BASE_URL entirely.
      #   2. The streaming-on chat path used to bypass this by reading
      #      os.environ["OPENROUTER_BASE_URL"] directly, but we have
      #      display.streaming = false below (sticky 30s timeout bug), so
      #      non-streaming traffic now flows through the provider profile
      #      and hits the hardcoded openrouter.ai URL with a gateway
      #      key — every call 401s with "Missing Authentication header".
      #   3. Setting model.provider = "custom" + model.base_url + model.api_key
      #      triggers the credential_pool custom-provider branch
      #      (agent/credential_pool.py:`model_provider == "custom"`), which
      #      routes through the supplied endpoint directly. Same fix the
      #      auxiliary block below uses for title_generation / triage_specifier.
      #   4. `${...}` syntax is expanded at config-load time by
      #      _expand_env_vars() (config.py:3838) reading from os.environ,
      #      which already has the values from environmentFiles=.../env.
      #
      # The earlier "Python reads model as a string and gets nothing"
      # warning was for an older Hermes version. v0.14's model resolver
      # (hermes_cli/dump.py:`model_cfg.get("default") or .get("model") or
      # .get("name")`) reads the name from any of those keys.
      model = {
        default = agentModel;
        provider = "custom";
        base_url = "\${OPENROUTER_BASE_URL}";
        api_key = "\${OPENROUTER_API_KEY}";
      };

      # Per-provider request timeout. The default OpenAI-wire client
      # timeout fires at 30s before the first byte arrives, which is
      # too short for a 27B MLX model that needs ~30-60s of prompt
      # evaluation on a 3-4k-token prompt. Setting both per-provider
      # and per-model (per-model has higher priority per
      # hermes_cli/timeouts.py).
      providers.openrouter = {
        request_timeout_seconds = 600;
        models.${agentModel} = {
          timeout_seconds = 600;
          stale_timeout_seconds = 600;
        };
      };

      # Disable streaming. The streaming code path's 30s "Streaming
      # failed before delivery" timeout is sticky despite all timeout
      # overrides — likely because the OpenAI SDK Stream constructor
      # has an early-response timer we haven't located. Non-streaming
      # uses the cleaner _resolved_api_call_timeout() path which
      # honors `request_timeout_seconds` above. Trade-off: Discord
      # gets the full reply at once instead of progressive chunks.
      display.streaming = false;

      # Reduce retry count — at 30s per attempt × 3 retries this was
      # spamming the Discord channel with "Retrying in X.Xs" messages
      # before each failed attempt. Single attempt fails fast and
      # cleanly.
      agent.max_retries = 1;

      # memory/skills directories: omit — the upstream module's tmpfiles
      # creates ${stateDir}/.hermes/memories and .hermes/plugins on
      # activation (see nixosModules.nix:712-713). Hermes's defaults
      # already point there. Overriding without a matching tmpfiles
      # entry would force Hermes to mkdir at runtime, which may not
      # have the right group-write bits.

      # Route auxiliary tasks (title generation, triage, etc.) through
      # our LLM gateway.  Hermes' internal `OPENROUTER_BASE_URL`
      # constant is hardcoded to `https://openrouter.ai/api/v1`
      # (hermes_constants.py:342) and the credential pool builds its
      # default base_url from that constant, NOT from the env var.
      # That means the main streaming chat path (which reads
      # `os.environ["OPENROUTER_BASE_URL"]` directly in run_agent.py)
      # works, but auxiliary tasks fail with HTTP 401 against the real
      # OpenRouter cloud using our gateway key.
      #
      # Setting both base_url+api_key here triggers the `"custom"`
      # provider branch in auxiliary_client._resolve_auxiliary_for_call
      # (auxiliary_client.py:3822-3824), which bypasses the credential
      # pool entirely and uses the supplied endpoint directly. The
      # `${VAR}` syntax is expanded at config-load time by Hermes'
      # `_expand_env_vars()` (config.py:3838) reading from os.environ,
      # which already has the values from environmentFiles=.../env.
      auxiliary = {
        title_generation = {
          base_url = "\${OPENROUTER_BASE_URL}";
          api_key = "\${OPENROUTER_API_KEY}";
        };
        triage_specifier = {
          base_url = "\${OPENROUTER_BASE_URL}";
          api_key = "\${OPENROUTER_API_KEY}";
        };
      };
    };

    # ── MCP servers (stdio) ──────────────────────────────────────────────
    # Top-level option (NOT settings.mcpServers): the upstream module maps
    # this attrset into settings.mcp_servers. Each entry's `command` is an
    # absolute store-path wrapper from the let-block above; `args`/`env`
    # follow the same contract OpenClaw uses for the SAME scripts. SearXNG
    # is intentionally absent here — it is the native web backend, not an
    # MCP server.
    #
    # NOTE for reviewers: the upstream mcpServers submodule
    # (hermes-agent nixosModules.nix:327) type-checks strictly and has NO
    # `description` field (only command/args/env/url/headers/auth/enabled/
    # timeout/connect_timeout/tools/sampling). Adding `description = ...`
    # would fail evaluation. Hermes derives each tool's doc from the MCP
    # server's own FastMCP tool docstrings, not from this option, so the
    # human-readable descriptions live as comments here (mirroring the
    # spirit of the removed OpenClaw VM config's mcporter `description` fields).
    mcpServers = {
      # Vane (Perplexica) — AI answer engine that runs SearXNG behind the
      # scenes and synthesizes a cited answer from web sources. Slower than
      # raw SearXNG but produces a written digest with linked citations.
      # Use for research-style questions.
      vane = {
        command = "${vaneMcpServer}";
        args = [ ];

        # Hermes' per-tool-call MCP timeout defaults to 120s, which is SHORTER
        # than the work this tool does: a measured /api/search for a trivial
        # query ("What is NixOS?") took 73s end-to-end on 2026-08-02, so any
        # non-trivial query overruns 120s and the caller sees a bare timeout
        # with no answer — reported from Discord that day. Vane itself was
        # healthy throughout; only the caller gave up.
        #
        # Raised to match VANE_TIMEOUT_S below, so the MCP layer and the
        # script's own HTTP timeout expire together instead of the outer one
        # firing first and orphaning an in-flight synthesis. Keep the two
        # numbers equal if either changes.
        timeout = 600;

        env = {
          VANE_BASE_URL = "https://vane.vulcan.lan";
          VANE_TIMEOUT_S = "600";
          # vane-mcp.py talks HTTPS to vane.vulcan.lan via `requests`, so it
          # needs the Vulcan CA bundle for the same reason as stock-trader
          # (see the vulcanCaBundle note above). This was a latent failure —
          # vane was never exercised in the 2026-05-28 parity smoke test.
          REQUESTS_CA_BUNDLE = vulcanCaBundle;
          NIX_SSL_CERT_FILE = vulcanCaBundle;
        };
      };

      # Home Assistant (state, services, automation, devices) via the
      # mcp-proxy stdio bridge to /api/mcp with a static long-lived access
      # token. command is the haBridge wrapper, which reads the token from
      # the staged secret at spawn time.
      home-assistant = {
        command = "${haBridge}";
        args = [ ];
      };

      # Stock quotes, technical analysis, news sentiment, options
      # strategies, and risk assessment via the stock-trader service.
      stock-trader = {
        command = "${stockTraderMcpServer}";
        args = [ ];
        env = {
          STOCK_TRADER_BASE_URL = "https://trader.vulcan.lan";
          # Without these the `requests` calls in stock-trader-mcp.py reject
          # the Vulcan Step-CA cert (certifi's vendored bundle lacks it). See
          # the vulcanCaBundle note above. SSL_CERT_FILE does NOT work here.
          REQUESTS_CA_BUNDLE = vulcanCaBundle;
          NIX_SSL_CERT_FILE = vulcanCaBundle;
        };
      };

      # Email (IMAP read/search, SMTP send) and contact lookup. khard reads
      # the contacts synced by hermes-tools-setup; the password comes from
      # the staged secret file.
      email-contacts = {
        command = "${emailMcpServer}";
        args = [ ];
        env = {
          IMAP_HOST = "imap.vulcan.lan";
          IMAP_PORT = "993";
          SMTP_HOST = "smtp.vulcan.lan";
          SMTP_PORT = "2525";
          EMAIL_ADDRESS = "johnw@vulcan.lan";
          EMAIL_USERNAME = "johnw";
          EMAIL_PASSWORD_FILE = "/run/hermes-secrets/imap-password";
          KHARD_CONFIG = "${stateDir}/.config/khard/khard.conf";
        };
      };

      # Web answers via the public Perplexity API. Parity with OpenClaw's
      # built-in Perplexity web tool; the wrapper exports PERPLEXITY_API_KEY
      # from the staged secret.
      perplexity = {
        command = "${perplexityMcpServer}";
        args = [ ];
      };

      # Read-only org-mode access: org_sql (sanitized single SELECT via
      # psycopg2 against the org database as the read-only `openclaw` role)
      # and org_search (semantic search via `org db search` over the gateway
      # bge-m3 embeddings). The wrapper exports PG*/PGPASSWORD and ORG_CONFIG,
      # and sources OPENROUTER_API_KEY (the gateway key) from
      # ${stateDir}/env so the semantic-search subprocess authenticates to
      # the gateway without relying on parent-process env inheritance.
      org-db = {
        command = "${orgDbMcpServer}";
        args = [ ];
      };

      # Drafts.app on hera via the host drafts-mcp SSE bridge (binds
      # 127.0.0.1:9082; reached over the hermes-br0 guest OUTPUT DNAT
      # 127.0.0.1:9082 → 10.99.1.1:9082 → host PREROUTING → 127.0.0.1:9082).
      #
      # READ/WRITE surface (owner decision 2026-06-10, superseding the
      # launch read-only posture): the point of giving agents Drafts access
      # is that they can MAKE drafts on request, not just see them. The
      # include allowlist below is everything drafts-mcp-server exposes
      # EXCEPT drafts_run_action — arbitrary Drafts action execution
      # (including script actions) as johnw inside hera's GUI session is
      # code execution, not draft management, and stays operator-only. The
      # bridge's stdio filter shim (drafts-tool-filter, drafts-mcp.nix)
      # enforces the same single denial server-side for every consumer;
      # this default-deny `include` list is the client-side
      # belt-and-suspenders that also pins the surface against future
      # upstream tool additions.
      # NO `description` field — the upstream mcpServers submodule (see the
      # NOTE at the top of this block) rejects it.
      #
      # URL is /mcp/ (Streamable HTTP), NOT /sse: hermes-agent's mcp_tool
      # speaks Streamable HTTP for `url` entries (it POSTs JSON-RPC to the
      # URL itself), and the submodule exposes no `transport = "sse"` knob,
      # so pointing it at mcp-proxy's /sse mount yields POST /sse → 405
      # Method Not Allowed (observed live 2026-06-10). mcp-proxy 0.8.2
      # mounts Streamable HTTP at /mcp/ — TRAILING SLASH REQUIRED (bare
      # /mcp is a 404, no redirect). Both mounts front the same filtered
      # stdio chain, so the run_action denial applies identically.
      drafts-hera = {
        url = "http://127.0.0.1:9082/mcp/";
        connect_timeout = 10;
        timeout = 60;
        tools.include = [
          # reads
          "drafts_search"
          "drafts_get_draft"
          "drafts_get_drafts"
          "drafts_get_tag"
          "drafts_get_current"
          "drafts_get_current_workspace"
          "drafts_get_workspace_drafts"
          "drafts_list_tags"
          "drafts_list_workspaces"
          "drafts_list_actions"
          "drafts_open"
          # writes (everything except drafts_run_action)
          "drafts_create_draft"
          "drafts_update_draft"
          "drafts_add_tags"
          "drafts_flag"
          "drafts_archive"
          "drafts_inbox"
          "drafts_trash"
          "drafts_open_workspace"
        ];
      };
    };
  };

  # Inject the Python startup shims (httpx.Timeout patch + Discord WS
  # heartbeat-ACK liveness stamp) into the hermes-agent service via
  # PYTHONPATH. Python's site initialization auto-imports
  # `sitecustomize.py` from any path in sys.path on startup, before the
  # main script (`bin/hermes`) runs. See `hermesPyShim` in the
  # let-block above for the why.
  systemd.services.hermes-agent.environment = {
    PYTHONPATH = "${hermesPyShim}";
    # Native SearXNG web backend. This variable is load-bearing for BOTH web
    # tools, not just search: it is the only entry on check_web_api_key's
    # hardcoded backend list that this guest can satisfy, and that one check
    # gates web_search AND web_extract together (see the settings.web comment
    # above). Removing it on 2026-08-05 silently disabled page-reading agent-wide
    # until 2026-08-06 — so if this is ever dropped again, expect to lose
    # extraction with it, and confirm against tools/registry.py:358-364 first.
    #
    # settings.web.search_backend = "searxng" (above) forces it as the provider.
    # Reaches the host SearXNG over 443 via the bridge DNAT; the SearXNG provider
    # GETs /search?format=json, which the host instance already enables. No API
    # key, no extra deps (uses core httpx).
    SEARXNG_URL = "https://searxng.vulcan.lan";
    # api_server Platform — exposes OpenAI-compatible /v1/chat/completions.
    # Consumers are host-side only: the OpenClaw↔Hermes MCP bridge
    # (hermes-mcp.service), the e2e chat probe, and Open WebUI, all of which
    # reach the guest over the /30 bridge. There is deliberately no LAN ingress
    # — see the note at the top of hermes-microvm.nix.
    # `API_SERVER_KEY` is supplied via environmentFiles=…/env (sops);
    # requests must present that key as `Authorization: Bearer …`.
    API_SERVER_ENABLED = "true";
    API_SERVER_HOST = "0.0.0.0";
    API_SERVER_PORT = toString apiServerPort;
  };

  # ---- Hang detector + forensic capture ----
  # Independent of hermes-agent (it must keep running while the gateway is
  # frozen, and it intentionally does NOT restart the gateway — capture only).
  # Probes the local api_server every 20s; after 3 consecutive non-responses
  # (~60s of a frozen loop) it writes per-thread scheduler state + kernel stacks
  # to ${stateDir}/.hermes/diag/ (host-shared, so it survives the self-heal VM
  # restart). That state distinguishes the CPU-starvation freeze (threads
  # runnable but load >> nproc — the cause the 2026-05-31 4-vCPU bump was meant
  # to address, since reverted; see the vCPU rationale block above) from a
  # blocking call / deadlock on any residual freeze.
  #
  # NB: py-spy (which would give Python frames) does NOT compile on aarch64 in
  # this nixpkgs (meta.broken = isAarch64; remoteprocess libunwind build error),
  # so the capture is /proc-based and needs no extra packages. Runs as root to
  # read /proc/<pid>/task/*/stack (privileged).
  systemd.services.hermes-hang-capture = {
    description = "Hermes api_server hang detector + forensic capture";
    wantedBy = [ "multi-user.target" ];
    after = [ "hermes-agent.service" ];
    environment = {
      HANG_PROBE_INTERVAL = "20";
      HANG_FAIL_THRESHOLD = "3";
      HANG_DIAG_DIR = "${stateDir}/.hermes/diag";
      HANG_AGENT_LOG = "${stateDir}/.hermes/logs/agent.log";
    };
    path = with pkgs; [
      curl
      procps # uptime, free, top, ps
      iproute2 # ss
      util-linux # logger
      coreutils # date, nproc, cat, tail, head, chown, chmod, mkdir, rm, ls
      gnugrep
      systemd # systemctl, journalctl
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${hangCapture}";
      Restart = "always";
      RestartSec = 10;
      # Root + CAP_SYS_PTRACE to read /proc/<pid>/task/*/stack of the gateway,
      # which runs as the unprivileged `hermes` user.
      User = "root";
      AmbientCapabilities = [ "CAP_SYS_PTRACE" ];
      Nice = 5;
    };
  };

  # ---- Tool config + contact sync (runs before hermes-agent) ----
  # Writes the per-tool config files the email-contacts and org-db MCP
  # servers need, then does a best-effort contact sync. This is the
  # relevant slice of the removed OpenClaw VM config's giant preStart, factored out into
  # its own oneshot so the hermes-agent unit stays declarative.
  #
  # All generated config goes under ${stateDir}/.config (the read-write
  # state share) — NEVER into the read-only /run/hermes-secrets mount.
  # Secrets are read from /run/hermes-secrets/* and injected into the
  # config files at write time (the sherlock config is written with a
  # placeholder, patched by jq, then chmod 600). Runs as the hermes user so
  # every file it writes is owned hermes:hermes.
  #
  # CAVEAT, corrected 2026-07-27: this comment used to claim the org-db
  # password "never appears in argv". It does. The injection in the script
  # below is `jq --arg pass "$ORG_DB_PASS" …`, so the plaintext value is in
  # jq's argv and readable from /proc/<pid>/cmdline for the life of that
  # process. Only the resulting file is protected (mode 600), not the
  # injection itself. the removed OpenClaw VM config uses the identical pattern. If that
  # exposure window matters, pass the value from the secret file rather than
  # on the command line — but that is a code change, not a comment change.
  systemd.services.hermes-tools-setup = {
    description = "Hermes MCP tool config + initial contact sync";
    before = [ "hermes-agent.service" ];
    requiredBy = [ "hermes-agent.service" ];
    after = [
      # The state share must be mounted before we write into it. microvm.nix
      # bind-mounts the virtiofs `state` share at ${stateDir}; the unit name
      # is derived from the mount point.
      "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" stateDir)}.mount"
    ];
    requires = [
      "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" stateDir)}.mount"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "hermes";
      Group = "hermes";
      WorkingDirectory = stateDir;
    };
    path = with pkgs; [
      coreutils
      jq
      vdirsyncer
      curl
    ];
    script = ''
      set -u

      # Create config directories (safe "d"-style mkdir -p — preserves
      # contents; never deletes). All under the read-write state share.
      mkdir -p ${stateDir}/.config/khard
      mkdir -p ${stateDir}/.config/vdirsyncer
      mkdir -p ${stateDir}/.config/sherlock
      mkdir -p ${stateDir}/.config/org
      mkdir -p ${stateDir}/.vdirsyncer/status
      mkdir -p ${stateDir}/contacts/contacts

      # ── vdirsyncer: sync Radicale contacts to local vCard files ───────
      # Password is fetched at command time from the staged secret so it
      # never lands in this file. Mirrors the removed OpenClaw VM config's vdirsyncer cfg.
      cat > ${stateDir}/.config/vdirsyncer/config << VDIRSYNCER_END
      [general]
      status_path = "${stateDir}/.vdirsyncer/status"

      [pair contacts]
      a = "radicale"
      b = "local"
      collections = [["contacts", "contacts", "contacts"]]

      [storage radicale]
      type = "carddav"
      url = "http://radicale.vulcan.lan:5232/"
      username = "johnw"
      password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "/run/hermes-secrets/radicale-password"]

      [storage local]
      type = "filesystem"
      path = "${stateDir}/contacts/"
      fileext = ".vcf"
      VDIRSYNCER_END
      chmod 600 ${stateDir}/.config/vdirsyncer/config

      # ── khard: CLI contact manager for the synced vCard files ─────────
      # The contacts subdir is created by vdirsyncer for the "contacts"
      # collection. KHARD_CONFIG on the email-contacts MCP entry points
      # here.
      cat > ${stateDir}/.config/khard/khard.conf << KHARD_END
      [addressbooks]
      [[contacts]]
      path = ${stateDir}/contacts/contacts/

      [general]
      default_action = show
      editor = cat
      merge_editor = cat
      KHARD_END
      chmod 600 ${stateDir}/.config/khard/khard.conf

      # ── sherlock: read-only DB query config (org connection) ──────────
      # Written with a PLACEHOLDER password, then the real org-db password
      # is injected via jq so it never appears in argv. Mode 600. Mirrors
      # the removed OpenClaw VM config's sherlock config.
      ORG_DB_PASS=""
      if [ -r /run/hermes-secrets/org-db-password ]; then
        ORG_DB_PASS=$(cat /run/hermes-secrets/org-db-password)
      fi
      cat > ${stateDir}/.config/sherlock/config.json <<'SHERLOCK_END'
      {
        "version": "2.0",
        "connections": {
          "org": {
            "type": "postgres",
            "host": "127.0.0.1",
            "port": 5432,
            "database": "org",
            "username": "openclaw",
            "password": "PLACEHOLDER"
          }
        }
      }
      SHERLOCK_END
      jq --arg pass "$ORG_DB_PASS" '.connections.org.password = $pass' \
        ${stateDir}/.config/sherlock/config.json > ${stateDir}/.config/sherlock/config.json.tmp
      mv ${stateDir}/.config/sherlock/config.json.tmp ${stateDir}/.config/sherlock/config.json
      chmod 600 ${stateDir}/.config/sherlock/config.json

      # ── org: minimal config.yaml required by the org CLI for db search ─
      # (org_search in org-db-mcp.py shells `org -c <this> db search`.)
      cat > ${stateDir}/.config/org/config.yaml << 'ORG_CONFIG_END'
      startKeywords: ["TODO", "TASK"]
      openKeywords: ["TODO", "DOING", "WAIT", "DEFER", "TASK"]
      closedKeywords: ["DONE", "CANCELED", "NOTE"]
      keywordTransitions: []
      checkFiles: false
      priorities: ["A", "B", "C"]
      propertyColumn: 11
      tagsColumn: 97
      attachmentsDir: "/tmp/org-attach"
      ORG_CONFIG_END
      chmod 644 ${stateDir}/.config/org/config.yaml

      # ── Sync contacts from Radicale (best-effort, logged, non-fatal) ──
      VDIR_LOG="${stateDir}/.hermes/logs/vdirsyncer-startup.log"
      mkdir -p "$(dirname "$VDIR_LOG")"
      echo "=== vdirsyncer startup $(date -u) ===" | tee -a "$VDIR_LOG"
      if [ -r /run/hermes-secrets/radicale-password ]; then
        echo "Testing Radicale at http://radicale.vulcan.lan:5232/ ..." | tee -a "$VDIR_LOG"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
          --connect-timeout 5 "http://radicale.vulcan.lan:5232/" 2>&1 || echo "CURL_FAILED")
        echo "Radicale HTTP response: $HTTP_CODE" | tee -a "$VDIR_LOG"

        echo "Running vdirsyncer discover..." | tee -a "$VDIR_LOG"
        vdirsyncer --config ${stateDir}/.config/vdirsyncer/config \
          discover contacts 2>&1 | tee -a "$VDIR_LOG" | head -20 || \
          echo "vdirsyncer discover failed (non-fatal)" | tee -a "$VDIR_LOG"

        echo "Running vdirsyncer sync..." | tee -a "$VDIR_LOG"
        vdirsyncer --config ${stateDir}/.config/vdirsyncer/config \
          sync 2>&1 | tee -a "$VDIR_LOG" | head -40 || \
          echo "vdirsyncer sync failed; will use cached contacts if available" | tee -a "$VDIR_LOG"
        echo "Contact count: $(ls ${stateDir}/contacts/contacts/*.vcf 2>/dev/null | wc -l) vCards" | tee -a "$VDIR_LOG"
      else
        echo "Radicale credentials not staged; skipping contact sync" | tee -a "$VDIR_LOG"
      fi

      # Never fail the unit on a flaky sync — the MCP servers can still run
      # with cached (or empty) contacts, and email/SQL parity does not
      # depend on contacts at all.
      exit 0
    '';
  };

  # User+group inside the guest — must match the host UID so the
  # virtio-fs share permissions line up.
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    createHome = true; # defensive — state share is also tmpfiles'd on host
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      # Originally an ephemeral debug key generated on the host at
      # /root/.ssh/hermes-debug for interactive debugging (Claude shelling in).
      # It has since become the nightly-report probe key it was supposed to be
      # replaced by: hermes-nightly-report.nix:30-33 documents this same key,
      # private half in SOPS as hermes/probe-ssh-private-key, as the credential
      # for its in-VM corroboration step. So do NOT remove it — that would
      # break the nightly report. Mirrors the removed OpenClaw VM config.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINYXL7oqQT3RgRbnWRQNcKNrywkP3TV2F5m8w02+eGUB claude-hermes-debug"
    ];
  };
  users.groups.hermes.gid = hermesGid;

  # ---- In-VM sshd (debug only) ----
  # Listens on the bridge IP so the host (and only the host, via the
  # extraInputRules nft restriction) can reach it.  Mirrors the removed OpenClaw VM config.
  services.openssh = {
    enable = true;
    openFirewall = false;
    listenAddresses = [
      {
        addr = vmAddr;
        port = 22;
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "hermes" ];
    };
  };
  networking.firewall = {
    enable = true;
    extraInputRules = ''
      ip saddr ${bridgeAddr} tcp dport 22 accept comment "claude debug ssh from host bridge"
      ip saddr ${bridgeAddr} tcp dport ${toString apiServerPort} accept comment "hermes api_server from host bridge (hermes-mcp.service, the e2e probe, Open WebUI)"
    '';
  };
}
