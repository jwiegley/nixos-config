# Guest NixOS configuration for the OpenClaw microVM.
# This file is imported by openclaw-microvm.nix via microvm.vms.openclaw.config.
# Variables are passed from the host module via specialArgs.
{
  config,
  pkgs,
  lib,
  openclawVmArgs,
  khardFixed,
  financialPython,
  orgDbSearch,
  ...
}:

let
  inherit (openclawVmArgs)
    openclawPkg
    mcporterPkg
    claudeCodePkg
    bridgeAddr
    vmCidr
    stateDir
    secretsStagingDir
    dnatPortList
    servicePort
    tapName
    vmHostname
    vmVcpu
    vmMem
    openclawUid
    openclawGid
    ;

  openclawDir = "${stateDir}/.openclaw";

  # Model selection comes from models.nix so the SOPS-encrypted openclaw.json
  # does not pin model IDs.  The preStart jq pipeline rewrites the relevant
  # fields in the decrypted config before OpenClaw reads it.  OpenClaw is an
  # agent runtime, so it uses the `agent` tier, which is tuned for
  # long-running tool-using sessions.
  models = import ../../models.nix;
  agentModel = models.llm.agent.name;
  embeddingModel = models.embedding.primary.name;

  # The MCP script is referenced as a Nix path so it lands in the nix store
  # (shared with the VM via virtiofs).
  emailMcpScript = ../../scripts/email-contacts-mcp.py;

  # Wrapper script that sets PATH and XDG_CONFIG_HOME so khard finds its
  # config, then exec's the Python MCP server.
  emailMcpServer = pkgs.writeShellScript "email-contacts-mcp" ''
    export PATH="${khardFixed}/bin:$PATH"
    export XDG_CONFIG_HOME="${stateDir}/.config"
    exec ${financialPython}/bin/python3 ${emailMcpScript}
  '';

  # Wrapper for the stock-trader MCP server.  Sets the base URL so the
  # script can be tested elsewhere by overriding the env var, then
  # exec's the Python MCP server with financialPython's interpreter
  # (which already provides `mcp` and `requests`).
  stockTraderMcpScript = ../../scripts/stock-trader-mcp.py;
  stockTraderMcpServer = pkgs.writeShellScript "stock-trader-mcp" ''
    export STOCK_TRADER_BASE_URL="https://trader.vulcan.lan"
    exec ${financialPython}/bin/python3 ${stockTraderMcpScript}
  '';

  # SearXNG MCP server: privacy-respecting metasearch via the host
  # nginx-proxied SearXNG instance. The base URL goes through nginx so
  # TLS validation uses the Vulcan Step-CA root that's already trusted
  # in the VM via security.pki.certificates.
  searxngMcpScript = ../../scripts/searxng-mcp.py;
  searxngMcpServer = pkgs.writeShellScript "searxng-mcp" ''
    export SEARXNG_BASE_URL="https://searxng.vulcan.lan"
    exec ${financialPython}/bin/python3 ${searxngMcpScript}
  '';

  # Vane (Perplexica) MCP server: AI-synthesized answers with citations,
  # using SearXNG behind the scenes. Talks to the host vane container
  # via nginx HTTPS. Provider/model selection is discovered at first
  # call by GET-ing /api/config — the script never logs the response
  # body because it contains the LiteLLM apiKey.
  vaneMcpScript = ../../scripts/vane-mcp.py;
  vaneMcpServer = pkgs.writeShellScript "vane-mcp" ''
    export VANE_BASE_URL="https://vane.vulcan.lan"
    # 10 min HTTP timeout — Vane synthesis can take several minutes when
    # the focus_mode does deep retrieval. Callers must also pass
    # `mcporter --timeout 600000` (or set MCPORTER_CALL_TIMEOUT) so
    # mcporter's per-call cap doesn't trip first.
    export VANE_TIMEOUT_S=600
    exec ${financialPython}/bin/python3 ${vaneMcpScript}
  '';

  # Stdio bridge from mcporter to Home Assistant's streamable HTTP MCP
  # server.  We can't connect mcporter directly to HA's SSE/HTTP MCP
  # endpoint because mcporter (0.10.1 when this was diagnosed; the locked
  # llm-agents input supplies 0.12.4 as of 2026-07-27, not re-tested since)
  # always probes OAuth metadata and
  # then attempts RFC 7591 dynamic client registration — which HA does
  # not implement, so the connection fails with "Incompatible auth
  # server: does not support dynamic client registration".  Static
  # `Authorization` headers, the `bearerToken` convenience field, and
  # the explicit `transport: "http"` setting all fail to prevent this
  # auto-OAuth behaviour.
  #
  # `mcp-proxy` is the upstream-recommended bridge: it runs as a stdio
  # client to mcporter and as a streamable HTTP client to HA, with a
  # static Bearer token passed via --headers.  The token is read from
  # the staged secret at startup so it never appears in the unit's env
  # or the Nix store.  It does briefly appear in argv of the spawned
  # mcp-proxy process (visible via /proc/<pid>/cmdline to the openclaw
  # user only); this is an accepted trade-off to keep the wrapper thin.
  homeAssistantMcpBridge = pkgs.writeShellScript "mcp-proxy-ha-bridge" ''
    set -eu
    TOKEN_FILE="/run/openclaw-secrets/home-assistant-token"
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

  # Memory Vault MCP — unauthenticated (the host nginx vhost + IP-allowlist
  # gate it; the MCP container itself has no auth). Connect to the host's
  # memory-vault-mcp streamable-http endpoint over the 8236 loopback DNAT and
  # present it to mcporter as stdio: mcporter's `url` entries assume SSE and
  # auto-probe OAuth, both of which the stdio bridge sidesteps. FastMCP serves
  # at /mcp with NO trailing slash (/mcp/ 307-redirects).
  memoryVaultMcpBridge = pkgs.writeShellScript "mcp-proxy-memory-vault-bridge" ''
    set -eu
    exec ${pkgs.mcp-proxy}/bin/mcp-proxy \
      --transport=streamablehttp \
      --stateless \
      "http://127.0.0.1:8236/mcp"
  '';

  # TOOLS.MD content sections — kept as writeText derivations so they don't
  # affect Nix's indentation stripping of the preStart ''...'' block.
  toolsSherlockMd = pkgs.writeText "tools-sherlock.md" ''

    ---

    ## Sherlock Database Tool

    You have read-only access to an Org-mode task database via `sherlock` (in PATH).

    ### Quick Reference

    ```bash
    sherlock -c org tables               # List tables
    sherlock -c org introspect           # Full schema (cached)
    sherlock -c org describe <table>     # Table schema
    sherlock -c org query "SELECT ..." -f markdown  # Run a query
    sherlock -c org sample <table> -n 5  # Sample rows
    sherlock -c org stats <table>        # Data profiling
    ```

    ### The `org` Database

    Key tables: `entries`, `entry_tags`, `entry_stamps`, `entry_log_entries`, `entry_properties`, `entry_links`, `entry_embeddings`, `entry_body_blocks`, `entry_categories`, `entry_relationships`, `files`

    - `entries.keyword_value` contains TODO state: TODO, DONE, CANCELED, TASK, DOING, WAIT, DEFER, etc.
    - `entries.keyword_type` indicates state type: `open`, `closed`, or null
    - **Timestamps are Modified Julian Day integers.** Convert with: `DATE '1858-11-17' + day` (e.g. today 2026-04-11 = MJD 61141)
    - The `entries` table has a `tsv` column (tsvector) for full-text search
    - The `entry_embeddings` table has an `embedding` column (pgvector) for semantic search
    - Always use LIMIT to avoid large result sets
    - Use `sherlock -c org introspect` first to learn the full schema
  '';

  toolsOrgSearchMd = pkgs.writeText "tools-org-search.md" ''

    ---

    ## Org Semantic Search

    You can perform semantic (vector similarity) search over org-mode entries using `org-db-search`:

    ```bash
    org-db-search "QUERY" [-n LIMIT]
    ```

    This searches the `entry_embeddings` table using pgvector cosine similarity. The query text is embedded via the same model (bge-m3) used to generate the stored embeddings, so results are semantically relevant rather than keyword-matched.

    ### Examples

    ```bash
    org-db-search "tax preparation deadlines"
    org-db-search "home automation projects" -n 5
    org-db-search "budget review meetings" -n 20
    ```

    ### Options

    - First argument: the search query (required)
    - `-n N`: maximum results (default: 10)
    - `-f FORMAT`: output format — `text` (default), `json`, `csv`

    ### When to use Sherlock vs org-db-search

    - **Sherlock**: SQL queries — filtering by date, keyword state, tags, properties, exact matches
    - **org-db-search**: Finding entries by meaning — "tasks about home renovation", "meetings with accountant"

    Combine both: use `org-db-search` to find relevant entries, then use Sherlock SQL to get detailed properties, timestamps, or related data for those entries.
  '';

  toolsWebSearchMd = pkgs.writeText "tools-web-search.md" ''

    ---

    ## Web Search & Research

    You have **three** complementary web tools. Each has different strengths — use the right one for the question, and **combine them** when stakes are high or accuracy matters.

    ### Built-in `web_search` (Perplexity)

    The default `web_search` tool routes through Perplexity. Best for:
    - Quick paraphrased answers to factual questions
    - When you want a summarized response with a few citations
    - Conversational follow-ups where Perplexity's prior context helps

    ### `searxng` MCP — raw metasearch

    Direct access to the Vulcan SearXNG instance, which aggregates DuckDuckGo, Bing, Wikipedia, Startpage, and more. No tracking, no LLM in the loop — you get the unfiltered hits.

    ```bash
    mcporter list searxng                 # list available SearXNG tools
    mcporter list searxng --schema        # full tool docs
    mcporter call searxng.web_search query="NixOS flakes" num_results=10
    mcporter call searxng.web_search query="!wp Erlang" num_results=5     # !bang shortcuts work
    mcporter call searxng.search_news query="Apple silicon" time_range=week
    ```

    Useful args: `categories` (`general`, `news`, `science`, `it`, `videos`, `images`, ...), `time_range` (`day`/`week`/`month`/`year`/empty), `language`, `page`. Returns a JSON list of titles + URLs + content snippets + which engines surfaced each result.

    Best for:
    - Inspecting the raw landscape of results before forming a hypothesis
    - Cross-checking a Perplexity answer against the underlying sources
    - Topics where you need *engine diversity* (e.g., something controversial where Bing and DuckDuckGo might disagree)
    - Searching specific domains via bangs (`!gh`, `!wp`, `!so`, `!arxiv`, ...)

    ### `vane` MCP — AI answer engine with citations

    Vane (a Perplexica fork at vane.vulcan.lan) runs SearXNG behind the scenes, fetches the top pages, and synthesizes a cited answer. Slow — typical runs take 1–5 minutes; deep queries can take longer.

    **Always pass `--timeout 600000` (10 min) to mcporter for vane calls.** mcporter's default per-call timeout is 60s, which Vane will almost always exceed. The MCP server itself has a matching 10-min HTTP timeout so the call won't be cut short server-side.

    ```bash
    mcporter list vane --schema
    mcporter call vane.web_research --timeout 600000 query="tradeoffs between BTRFS and ZFS for home NAS" focus_mode=webSearch optimization_mode=speed
    mcporter call vane.web_research --timeout 600000 query="recent papers on speculative decoding" focus_mode=academicSearch optimization_mode=quality
    ```

    `focus_mode` accepts `webSearch` (default), `academicSearch`, `writingAssistant`, `wolframAlphaSearch`, `youtubeSearch`, `redditSearch`. `optimization_mode` is `speed` / `balanced` / `quality` (quality follows more links and takes longer).

    Best for:
    - "What does the web *currently* say about X?" with a written summary
    - Research questions where you want citations baked into the answer
    - Academic-style queries (use `focus_mode=academicSearch`)

    ### Combining sources for high-stakes research

    When the question matters — a bug-fix decision, a security claim, anything you'll act on — **don't trust a single source**. Run two or three in parallel and reconcile:

    1. Fire `web_search` (Perplexity) and `mcporter call searxng.web_search` together in the same turn. Tool calls run in parallel.
    2. Compare the result sets: if Perplexity claims X and SearXNG's top hits don't support X, treat that as a red flag and dig deeper.
    3. For deep research, follow up with `mcporter call vane.web_research` with `optimization_mode=quality` to get a synthesized digest, then verify any specific claim against the SearXNG hits you already have.
    4. Cite *which* tool surfaced each fact in your reply, so the user can audit the chain.

    Quick decision tree:

    - "Just tell me X" → built-in `web_search` (Perplexity)
    - "Show me the actual sources" → `searxng.web_search`
    - "Research this and write me a summary with citations" → `vane.web_research`
    - "I'm going to act on this answer" → run at least two of the above and reconcile
  '';

  # The two sections below document invariants that an agent-authored health
  # check got wrong (recorded 2026-07-27), reporting three designed behaviours
  # as outages: the VM's inability to SSH to the host (explained as "you're not
  # on the home network"), memory-qdrant's absence from `mcporter list`, and a
  # refused connection to localhost:8080.  All three are correct behaviour.
  # There is no Nix-declared check making those assertions — the check is the
  # agent improvising — so the durable fix is to put the real invariants where
  # the agent reads them, via the same TOOLS.md mechanism as the sections
  # above, rather than to change the system to satisfy a false requirement.
  toolsNetworkIsolationMd = pkgs.writeText "tools-network-isolation.md" ''

    ---

    ## Network Isolation — What You Can and Cannot Reach

    You run inside a microVM on vulcan, not on vulcan itself. This VM is
    ${vmCidr}; the host is the bridge gateway ${bridgeAddr}. Access to the host
    is an explicit allow-list, so several things that look like outages are the
    designed state. Do not report these as faults.

    ### SSH to the host does not work, and never has

    `ssh vulcan.lan`, `ssh ${bridgeAddr}`, or any probe of port 22 on the host
    will **time out**. Two independent reasons, both deliberate:

    - Port 22 is not on the host's allow-list (`dnatPorts` in
      `modules/services/openclaw-microvm.nix`). Anything not on that list falls
      through to `-j DROP` at the end of the `openclaw-isolate` chain. It is
      DROP rather than REJECT, which is exactly why the symptom is a timeout
      and not "connection refused".
    - The bare name `vulcan.lan` is not in this VM's `/etc/hosts`, so it
      resolves to the host's LAN address — and the host drops VM traffic to
      RFC1918 destinations other than the bridge gateway.

    This VM's own boot-time diagnostic (the `network-diag` unit; output in
    `${stateDir}/.openclaw/netdiag.txt`) probes port 22 on the host's LAN
    address and records `PASS: ...:22 blocked`. A health check that reports the
    same condition as a failure is asserting a requirement that does not exist.

    SSH is provisioned only in the opposite direction: the host connects to
    *this VM* on port 22, source-restricted to ${bridgeAddr} and to a single
    key, for the `openclaw-nightly-report` probe.

    ### An SSH timeout tells you nothing about where John is

    "Cannot reach vulcan.lan:22" is not evidence that John is travelling or off
    the home network. You are inside vulcan; this probe fails identically with
    John sitting next to the machine. Never infer his location from it, and
    never infer from it that Home Assistant, email, or SearXNG/Vane are
    unreachable — those cross the bridge on their own allow-listed ports and
    are unaffected by anything port 22 does.

    ### What you can reach

    These names are mapped to the bridge gateway in this VM's `/etc/hosts`:
    `hass.vulcan.lan`, `qdrant.vulcan.lan`, `litellm.vulcan.lan`,
    `imap.vulcan.lan`, `smtp.vulcan.lan`, `radicale.vulcan.lan`,
    `searxng.vulcan.lan`, `vane.vulcan.lan`, `trader.vulcan.lan`.

    The bare apex `vulcan.lan` is deliberately absent from that list. To judge
    host health, probe one of the mapped names above, or the DNAT'd localhost
    ports (127.0.0.1:4000 LiteLLM, :6333 Qdrant, :8123 Home Assistant, :5432
    PostgreSQL). Do not invent new probes and do not treat an unlisted
    port/name failing as an incident.
  '';

  toolsMemoryQdrantMd = pkgs.writeText "tools-memory-qdrant.md" ''

    ---

    ## memory-qdrant Health Signals

    `memory-qdrant` is an OpenClaw **plugin** — its `openclaw.plugin.json`
    declares `"kind": "memory"` — not an MCP server. It is configured on the
    plugin surface (`plugins.allow`, `plugins.load.paths`,
    `plugins.slots.memory`, `plugins.entries."memory-qdrant"`) and exposes
    `memory_store`, `memory_search` and `memory_forget` as in-process gateway
    tools.

    ### The correct signals

    1. Prometheus `openclaw_channel_plugin_loaded{channel="memory-qdrant"} == 1`
       (published by the openclaw-canary on the host; Nagios mirrors it as the
       service "OpenClaw Memory-Qdrant Plugin Loaded").
    2. Qdrant reachable at `http://127.0.0.1:6333` (DNAT'd to the host). Qdrant
       runs with an API key, so an unauthenticated probe answering **401 means
       the server is alive** — that is a healthy result, not a fault.
    3. Embeddings via LiteLLM: `POST http://127.0.0.1:4000/v1/embeddings`,
       model `${embeddingModel}`, expecting a 1024-dimension vector. This is
       the plugin's only embedding dependency.

    ### Stale probes that produce false alarms — do not use

    - **`mcporter list`.** mcporter enumerates MCP servers only; a plugin never
      appears there. memory-qdrant's absence from that list is expected and
      correct, and says nothing about whether the memory tools work. Note that
      `memory-vault` *is* a real MCP server — do not confuse the two names and
      conclude that memory is half-registered.
    - **`http://localhost:8080/v1/embeddings`.** Nothing in this deployment
      uses :8080. llama-swap listens there on the host and is deliberately
      excluded from the allow-list, because this VM reaches those models
      through LiteLLM on :4000. The `network-diag` unit records
      `PASS: 127.0.0.1:8080 not reachable (correct)`: a refused or timed-out
      connection on :8080 is the designed steady state, not an outage.
    - **Adding an embedding-endpoint setting to the plugin config.** There is
      no such key. The manifest's `configSchema` sets
      `"additionalProperties": false` and declares exactly seven properties
      (`autoCapture`, `autoRecall`, `captureMaxChars`, `collectionName`,
      `maxMemorySize`, `qdrantApiKey`, `qdrantUrl`); adding one would fail
      schema validation.
  '';

in
{
  networking.hostName = vmHostname;
  system.stateVersion = "25.11";

  # ========================================================================
  # Trust local Vulcan Certificate Authority
  # ========================================================================
  # The VM needs to trust the Vulcan Step-CA so that rustls (used by himalaya
  # and other TLS clients) can verify certificates signed by it (e.g., the
  # Dovecot IMAPS certificate at imap.vulcan.lan:993).
  # The CA cert is public and tracked in git; it's safe to embed here.
  security.pki.certificates = [
    (builtins.readFile ../../certs/vulcan-root-ca.crt)
  ];

  # Explicitly export SSL_CERT_FILE and NIX_SSL_CERT_FILE system-wide so that
  # rustls-platform-verifier (used by himalaya) and other TLS clients find the
  # patched CA bundle that includes the Vulcan Root CA.
  # security.pki.certificates patches the nss-cacert derivation but does NOT
  # automatically add these env vars to the systemd service environment.
  environment.variables = {
    SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
  };

  # ========================================================================
  # Imports
  # ========================================================================

  imports = [
    ./openclaw-health-check.nix
  ];

  # ========================================================================
  # System-wide packages (available in exec PATH for Claw agent commands)
  # ========================================================================
  # These must be in environment.systemPackages (not just the systemd service
  # path) so that Claw's exec commands can find them via the default PATH.

  environment.systemPackages = with pkgs; [
    mcporterPkg
    claudeCodePkg
    financialPython
    nodejs_22
    pnpm
    git
    curl
    jq
    himalaya
    vdirsyncer
    khardFixed
    sherlock-db
    org-jw
    orgDbSearch
  ];

  # ========================================================================
  # microvm hardware configuration
  # ========================================================================

  microvm = {
    # QEMU is the safest hypervisor for aarch64 Asahi with 16K pages.
    hypervisor = "qemu";

    vcpu = vmVcpu;
    mem = vmMem;

    shares = [
      {
        proto = "virtiofs";
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
      }
      {
        proto = "virtiofs";
        tag = "state";
        source = stateDir;
        mountPoint = stateDir;
      }
      {
        proto = "virtiofs";
        tag = "secrets";
        source = secretsStagingDir;
        mountPoint = "/run/openclaw-secrets";
      }
      {
        proto = "virtiofs";
        tag = "claude-config";
        source = "/home/johnw/.claude";
        mountPoint = "/run/claude-host-config";
      }
    ];

    writableStoreOverlay = "/nix/.rw-store";

    interfaces = [
      {
        type = "tap";
        id = tapName;
        mac = "02:00:00:0c:1a:01";
      }
    ];
  };

  # ========================================================================
  # Guest networking
  # ========================================================================

  # Disable IPv6 — host NAT is IPv4 only, and Node.js undici's
  # Happy Eyeballs algorithm causes connection delays when IPv6 is
  # available but doesn't work.
  networking.enableIPv6 = false;
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
    # Allow routing 127.0.0.0/8 traffic on non-loopback interfaces.
    # Required for the nftables OUTPUT DNAT that rewrites localhost
    # connections to the host bridge IP — without this, the kernel
    # refuses to route packets with source 127.0.0.1 via eth0.
    "net.ipv4.conf.all.route_localnet" = 1;
  };

  # CVE-2026-31431 "CopyFail" — disable AF_ALG userspace crypto sockets.
  # Rationale: the OpenClaw VM runs a Claude Code agent that can fetch and
  # exec untrusted code, so an unpatched AF_ALG is a real LPE risk inside the
  # VM. The microVM runs the nixpkgs 25.11 default kernel (6.12.x LTS).
  # Verified 2026-07-27 against the kernel.org CNA record for CVE-2026-31431
  # (cveawg.mitre.org/api/cve/CVE-2026-31431): the 6.12.x series is fixed as
  # of 6.12.85, and both the evaluated guest config and the deployed runner
  # under /var/lib/microvms/openclaw/current are on 6.12.93 — so that one CVE
  # is patched in the guest. Do NOT drop the blacklist on that basis alone:
  # it is a standing mitigation for the AF_ALG surface generally, and removal
  # needs a human who has checked that nothing in the guest uses AF_ALG.
  # `install /bin/false` is required in addition to `blacklist` to block
  # kernel request_module() autoload.
  boot.blacklistedKernelModules = [
    "algif_aead"
    "algif_skcipher"
    "algif_hash"
    "algif_rng"
  ];
  boot.extraModprobeConfig = ''
    install algif_aead ${pkgs.coreutils}/bin/false
    install algif_skcipher ${pkgs.coreutils}/bin/false
    install algif_hash ${pkgs.coreutils}/bin/false
    install algif_rng ${pkgs.coreutils}/bin/false
  '';

  # Static IP via systemd-networkd
  systemd.network.enable = true;
  systemd.network.networks."10-eth" = {
    matchConfig.Name = "e*";
    addresses = [ { Address = vmCidr; } ];
    routes = [ { Gateway = bridgeAddr; } ];
  };

  # DNS: use the host bridge IP (Technitium on host binds to 0.0.0.0:53)
  networking.nameservers = [ bridgeAddr ];

  # Override *.vulcan.lan hostnames to point to the bridge gateway so the
  # AI agent reaches host services directly. The egress filter blocks
  # 192.168.0.0/16, so normal DNS resolution (192.168.1.2) is unreachable.
  #
  # The bare apex `vulcan.lan` is deliberately NOT in this list: only the
  # specific service names below are reachable, and each one corresponds to a
  # port in `dnatPorts` (openclaw-microvm.nix) or to nginx on 443. Mapping the
  # apex here would make `vulcan.lan` resolve to the gateway while most ports
  # on it — port 22 in particular — still hit the `openclaw-isolate` DROP, i.e.
  # it would swap an honest "unreachable" for a misleading silent timeout.
  # An agent health check misread exactly that timeout as "John is not on the
  # home network"; see the Network Isolation section of TOOLS.md.
  networking.hosts = {
    ${bridgeAddr} = [
      "hass.vulcan.lan"
      "qdrant.vulcan.lan"
      "litellm.vulcan.lan"
      "imap.vulcan.lan" # Dovecot IMAPS (via DNAT 10.99.0.1:993 → 127.0.0.1:993)
      "smtp.vulcan.lan" # Postfix SMTP (via DNAT 10.99.0.1:2525 → 127.0.0.1:2525)
      "radicale.vulcan.lan" # Radicale CardDAV (via DNAT 10.99.0.1:5232 → 127.0.0.1:5232)
      "searxng.vulcan.lan" # SearXNG metasearch (via nginx → 127.0.0.1:8890)
      "vane.vulcan.lan" # Vane AI answer engine (via nginx → 127.0.0.1:3007)
      "trader.vulcan.lan" # stock-trader service (via nginx 443 → 127.0.0.1:8234)
    ];
  };

  # ========================================================================
  # Guest-side DNAT (stage 1 of two-stage DNAT)
  # ========================================================================
  # Rewrite outgoing connections from 127.0.0.1:PORT to the host bridge IP
  # so that OpenClaw's existing config (which uses localhost) works unchanged.

  networking.nftables.enable = true;

  # NAT table: rewrite localhost connections to the host bridge IP so
  # OpenClaw's existing 127.0.0.1 config works unchanged.
  networking.nftables.tables.openclaw-dnat = {
    family = "ip";
    content = ''
      chain output {
        type nat hook output priority -100; policy accept;
        # Redirect localhost-bound traffic for host services to bridge gateway
        ip daddr 127.0.0.1 tcp dport { ${dnatPortList} } dnat to ${bridgeAddr}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Rewrite source 127.0.0.1 → VM eth0 IP for DNAT'ed packets.
        # Without this, Linux refuses to route loopback-sourced packets
        # out of a non-loopback interface.
        oifname "e*" ip saddr 127.0.0.0/8 masquerade
      }
    '';
  };

  # Filter table: block all private-network access except the explicitly
  # allowed host services (DNS + DNAT ports). Internet access is preserved.
  networking.nftables.tables.openclaw-egress = {
    family = "ip";
    content = ''
      chain output {
        type filter hook output priority 0; policy accept;

        # Allow established/related traffic
        ct state established,related accept

        # Allow DNS (UDP+TCP) to bridge gateway
        ip daddr ${bridgeAddr} udp dport 53 accept
        ip daddr ${bridgeAddr} tcp dport 53 accept

        # Allow DNAT service ports to bridge gateway
        ip daddr ${bridgeAddr} tcp dport { ${dnatPortList} } accept

        # Block all other traffic to RFC 1918 private networks
        ip daddr 10.0.0.0/8 drop
        ip daddr 172.16.0.0/12 drop
        ip daddr 192.168.0.0/16 drop
      }
    '';
  };

  # ========================================================================
  # Guest user (pinned UID/GID to match host for virtiofs)
  # ========================================================================

  users.users.openclaw = {
    isSystemUser = true;
    uid = openclawUid;
    group = "openclaw";
    home = stateDir;
    shell = pkgs.bashInteractive;
    description = "OpenClaw AI Gateway service user";
    openssh.authorizedKeys.keys = [
      # Public half of the SSH key used by openclaw-nightly-report on the
      # host to probe HOST_BLIND_SERVERS from inside the VM. Private half
      # lives in secrets.yaml under openclaw.probe-ssh-private-key.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxaud1Pwm4ggrgqcmqvBN/iEW/uEVqHJFd0/zRpeN6N openclaw-nightly-report-probe"
    ];
  };
  users.groups.openclaw = {
    gid = openclawGid;
  };

  # ========================================================================
  # Guest tmpfiles
  # ========================================================================
  # Safe "d" directive only — preserves contents.

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 openclaw openclaw -"
  ];

  # ========================================================================
  # In-VM sshd
  # ========================================================================
  # Used exclusively by openclaw-nightly-report on the host to probe MCP
  # servers whose credentials live inside the VM (google-calendar-*,
  # home-assistant). Listening only on the bridge IP and gated by the guest
  # firewall to source 10.99.0.1.

  services.openssh = {
    enable = true;
    # CRITICAL: default is true, which would add TCP/22 to
    # networking.firewall.allowedTCPPorts (unrestricted), defeating the
    # source-scoped extraInputRules below. Source-restrict via nftables
    # only.
    openFirewall = false;
    listenAddresses = [
      {
        addr = "10.99.0.2";
        port = 22;
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "openclaw" ];
    };
  };

  # ========================================================================
  # OpenClaw systemd service
  # ========================================================================
  # NO systemd hardening needed — the VM IS the isolation boundary.

  systemd.services.openclaw = {
    description = "OpenClaw AI Gateway";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      nodejs_22
      pnpm
      git
      curl
      financialPython
      mcporterPkg
      claudeCodePkg
      coreutils
      bashInteractive
      gnugrep
      gnused
      jq
      socat
      himalaya
      vdirsyncer
      khardFixed
      sherlock-db
      org-jw
      orgDbSearch
    ];

    environment = {
      HOME = stateDir;
      NODE_ENV = "production";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
      HIMALAYA_CONFIG = "${stateDir}/.config/himalaya/config.toml";
      # Point bundled plugin discovery at the full source checkout so that
      # plugins like whatsapp expose their complete runtime files (e.g.
      # light-runtime-api.ts).  In openclaw >=2026.3.23 the dist-runtime stub
      # only ships index.js + setup-entry.js; the actual runtime modules live
      # in extensions/.  Without this override the whatsapp plugin fails with
      # "missing light-runtime-api for plugin 'whatsapp'".
      OPENCLAW_BUNDLED_PLUGINS_DIR = "${openclawPkg}/lib/openclaw/extensions";

      # TEMPORARY, 2026-07-31 -- revert once the Discord canary question is settled.
      #
      # openclaw's Discord preflight logs the exact reason it drops an inbound message
      # (extensions/discord/src/monitor/message-handler.preflight.ts), e.g.
      #   "discord: drop bot message (allowBots=false)"
      #   "discord: drop bot message (allowBots=mentions, missing mention)"
      # but each goes through logVerbose(), gated on
      # shouldLogVerbose() = isVerbose() || isFileLogLevelEnabled("debug")
      # (src/globals.ts:7). At the default "info" file level they are discarded.
      #
      # A full day went into INFERRING why bot-authored canary probes go unanswered --
      # allowBots, allowFrom, guild users, per-channel scoping, version skew -- each
      # costing a deploy/restart/wait cycle, and each one wrong. The program reports the
      # answer directly; it simply was not being written down. OPENCLAW_LOG_LEVEL is the
      # documented override for both file and console levels and takes precedence over
      # config (docs/help/environment.md:243).
      #
      # REVERTED 2026-07-31 after it did its job in one run. With debug on, the guest wrote
      # `[discord-preflight] pass: channel allowed` x16 and ZERO
      # `[discord-preflight] drop: member not allowed`, which is what confirmed that the
      # guilds.<id>.users fix opened the gate -- a positive/negative pair no amount of
      # inference had produced in a day of trying.
      #
      # Left off by default for two reasons: debug is verbose (gateway-vm.log was already
      # 27MB, gateway-vm.err.log 53MB), and at debug level openclaw can write outbound
      # request bodies, which for a Discord/LLM gateway means tokens landing in a log file.
      #
      # To turn it back on for canary triage, set BOTH of these and restart
      # microvm@openclaw, then read the drop reason instead of guessing at allowlists:
      #   here:                        OPENCLAW_LOG_LEVEL = "debug";
      #   openclaw-config.nix:         logging.file = ".../logs/openclaw-debug.log";
      # See docs/DISCORD_CANARY_SETUP.md for the drop-reason table.
      # OPENCLAW_LOG_LEVEL = "debug";

      # MCP tool-call timeout (ms). claude-code defaults to 60_000, which is
      # too short for the local-LLM Hermes bridge (`mcpServers.hermes`):
      # Hermes is itself an agent that invokes its own internal tools
      # (yfinance, execute_code, web search…) during analytical queries.
      # Real Hermes runs in /var/lib/hermes/.hermes/logs/agent.log show
      # 15-20 minute end-to-end times for tool-heavy financial analysis
      # prompts. 1_800_000 ms = 30 minutes covers the observed worst case
      # with headroom. Pair this with the MCP progress-notification
      # heartbeats sent by hermes-mcp's tool_ask_hermes — when the
      # client honors `resetTimeoutOnProgress` (claude-code does), the
      # timer resets on each notification and effectively never expires
      # while Hermes is making forward progress.
      MCP_TOOL_TIMEOUT = "1800000";
    };

    serviceConfig = {
      User = "openclaw";
      Group = "openclaw";
      Type = "simple";
      # systemd creates /run/openclaw (owned by openclaw) before preStart runs
      RuntimeDirectory = "openclaw";
      # Load secrets env file written by preStart from the SOPS-staged tokens
      EnvironmentFile = [ "-/run/openclaw/claude.env" ];
      Restart = "always";
      RestartSec = "10s";
      # preStart syncs contacts via vdirsyncer + registers plugins (~2-3 min)
      TimeoutStartSec = "5min";

      WorkingDirectory = stateDir;

      # Bind to LAN (all local interfaces) — the VM IS the isolation boundary.
      # Valid --bind modes: loopback, lan, tailnet, auto, custom
      ExecStart = "${openclawPkg}/bin/openclaw gateway run --bind lan --port ${toString servicePort} --auth token";

      # Log stdout/stderr to the shared state directory for host-side debugging
      StandardOutput = "append:${stateDir}/.openclaw/logs/gateway-vm.log";
      StandardError = "append:${stateDir}/.openclaw/logs/gateway-vm.err.log";

      # Resource limits
      MemoryMax = "4G";
      CPUQuota = "400%";
      TasksMax = 512;
      LimitNOFILE = 65536;
      LimitNPROC = 512;
    };

    preStart = ''
            # Create directory structure for OpenClaw state
            mkdir -p ${openclawDir}/agents/main/sessions
            mkdir -p ${openclawDir}/logs
            mkdir -p ${openclawDir}/cron
            mkdir -p ${openclawDir}/delivery-queue
            mkdir -p ${openclawDir}/workspace
            mkdir -p ${openclawDir}/.config/google-calendar-mcp
            mkdir -p ${stateDir}/.config/himalaya
            mkdir -p ${stateDir}/.config/vdirsyncer
            mkdir -p ${stateDir}/.config/khard
            mkdir -p ${openclawDir}/.vdirsyncer/status
            mkdir -p ${openclawDir}/contacts
            mkdir -p ${openclawDir}/contacts/contacts

            # ────────────────────────────────────────────────────────────────
            # Claude Code: set up ~/.claude for the openclaw user
            # ────────────────────────────────────────────────────────────────
            # /run/claude-host-config is a read-only virtiofs mount of the
            # host user's ~/.claude directory.  We symlink the read-only
            # content (commands, agents, skills) and copy writable state
            # (credentials, settings) from the secrets staging area.
            CLAUDE_DIR="${stateDir}/.claude"
            mkdir -p "$CLAUDE_DIR"

            # Symlink read-only content from the host's ~/.claude
            for subdir in commands agents skills; do
              if [ -d "/run/claude-host-config/$subdir" ]; then
                ln -sfn "/run/claude-host-config/$subdir" "$CLAUDE_DIR/$subdir"
              fi
            done

            # Copy private files from secrets staging (host prepare-secrets stages
            # these because the originals are mode 0600 on the host, not readable
            # through the virtiofs share).
            for pair in \
              "claude-config.json:.claude.json" \
              "claude-settings.json:settings.json"; do
              src="/run/openclaw-secrets/''${pair%%:*}"
              dst="$CLAUDE_DIR/''${pair##*:}"
              if [ -f "$src" ]; then
                cp -f "$src" "$dst"
                chmod 600 "$dst"
              fi
            done

            # Write secrets env file from SOPS-staged tokens.
            # This file is loaded by EnvironmentFiles in the service config.
            # Using an env file (rather than the environment block) keeps
            # secrets out of the nix store and the systemd unit.
            mkdir -p /run/openclaw
            : > /run/openclaw/claude.env

            CLAUDE_TOKEN="/run/openclaw-secrets/claude-code-token"
            if [ -f "$CLAUDE_TOKEN" ]; then
              printf 'ANTHROPIC_API_KEY=%s\n' "$(cat "$CLAUDE_TOKEN")" \
                >> /run/openclaw/claude.env
            fi

            PERPLEXITY_TOKEN="/run/openclaw-secrets/perplexity-api-key"
            if [ -f "$PERPLEXITY_TOKEN" ]; then
              printf 'PERPLEXITY_API_KEY=%s\n' "$(cat "$PERPLEXITY_TOKEN")" \
                >> /run/openclaw/claude.env
            fi

            chmod 0400 /run/openclaw/claude.env

            # Create writable directories that Claude Code expects
            mkdir -p "$CLAUDE_DIR/projects"
            mkdir -p "$CLAUDE_DIR/todos"

            # Copy secret from virtiofs-mounted staging directory
            cp -f /run/openclaw-secrets/openclaw-config ${openclawDir}/openclaw.json

            # Patch runtime config for the VM environment:
            #  - CORS: allow host-header origin fallback (VM is the isolation boundary)
            #  - Embedding URL: rewrite localhost:8080 → localhost:4000 (LiteLLM).
            #    Legacy safety net only: openclaw-config.nix contains no :8080,
            #    so this gsub is a no-op on the current Nix-rendered config. It
            #    also only touches this JSON — it cannot rewrite a URL that a
            #    plugin hardcodes in its own JavaScript.
            #  - Schema migration: flatten tools.web.search.<provider>.apiKey → tools.web.search.apiKey
            #    (openclaw >=2026.3.28 rejects nested provider config as "Unrecognized key")
            #  - Schema migration: openclaw 2026.5.x requires channels.<x>.streaming
            #    to be an object; older configs may have a boolean. Coerce to {}.
            ${pkgs.jq}/bin/jq \
              --arg agent "${agentModel}" \
              --arg agentRef "vulcan/${agentModel}" \
              --arg embeddingRef "vulcan/${embeddingModel}" '
              .gateway.controlUi = {"dangerouslyAllowHostHeaderOriginFallback": true}
              | walk(if type == "string" then gsub("http://localhost:8080"; "http://127.0.0.1:4000") else . end)
              | .acp = {"enabled": true, "backend": "acpx", "defaultAgent": "claude", "allowedAgents": ["claude"]}
              | if (.tools.web.search.provider // null) != null then
                  .tools.web.search |= (
                    . as $s |
                    ($s[$s.provider] | if type == "object" then .apiKey else null end) as $nestedKey |
                    if $nestedKey != null then
                      .apiKey = ($s.apiKey // $nestedKey)
                      | del(.[$s.provider])
                    else . end
                  )
                else . end
              | if (.channels // null) | type == "object" then
                  .channels |= with_entries(
                    .value |= (
                      if (type == "object") and has("streaming") and (.streaming | type) != "object"
                      then .streaming = {}
                      else . end
                    )
                  )
                else . end
              | del(.agents.defaults.instructions)
              | .agents.defaults.model.primary = $agentRef
              | .agents.defaults.models = { ($agentRef): {} }
              | .agents.defaults.memorySearch.model = $embeddingRef
              | if (.models.providers.vulcan.models | type) == "array"
                   and (.models.providers.vulcan.models | length) > 0 then
                     .models.providers.vulcan.models[0].id = $agent
                     | .models.providers.vulcan.models[0].name = $agent
                 else . end
            ' ${openclawDir}/openclaw.json > ${openclawDir}/openclaw.json.tmp
            mv ${openclawDir}/openclaw.json.tmp ${openclawDir}/openclaw.json

            chmod 600 ${openclawDir}/openclaw.json

            # Discard openclaw's "last-known-good" snapshot before doctor runs.
            # On model/template changes our jq output lacks the runtime-only
            # `.meta` block, so doctor treats the config as invalid and
            # restores `openclaw.json` from `openclaw.json.last-good` —
            # which still holds the previous model. Removing `.last-good`
            # short-circuits `recoverConfigFromLastKnownGood` (it returns
            # false when the file is missing), letting doctor keep our
            # rewrite. openclaw repopulates `.last-good` after a successful
            # start, so the safety net regenerates on its own.
            ${pkgs.coreutils}/bin/rm -f \
              ${openclawDir}/openclaw.json.last-good \
              ${openclawDir}/logs/config-health.json

            # ────────────────────────────────────────────────────────────────
            # Auto-migrate runtime state on every boot. doctor is idempotent:
            # if there's nothing to migrate, it's a no-op (~2 s). When openclaw
            # bumps, this catches new schema/state migrations before any alert
            # fires.  Failures are non-fatal — gateway still boots so we can
            # diagnose.
            # ────────────────────────────────────────────────────────────────
            (
              export OPENCLAW_STATE_DIR="${openclawDir}"
              export OPENCLAW_CONFIG_PATH="${openclawDir}/openclaw.json"
              export HOME="${stateDir}"
              ${pkgs.coreutils}/bin/timeout 120s \
                ${openclawPkg}/bin/openclaw doctor --fix --non-interactive --yes \
                || ${pkgs.coreutils}/bin/echo "openclaw doctor --fix failed (non-fatal); see journal"
            )

            # ────────────────────────────────────────────────────────────────
            # GC stale plugin-runtime-deps subdirs.  The upstream
            # stageBundledPluginRuntimeDeps mechanism was dropped in openclaw
            # 2026.5.x (numtide/llm-agents.nix d9cdb33), so subdirs named
            # after older versions are dead weight forever.  mv-not-rm
            # pattern: deleted entries become .bak-<ts>, purged later by the
            # host-side openclaw-plugin-deps-bak-purge weekly timer.
            # ────────────────────────────────────────────────────────────────
            DEPS_DIR="${openclawDir}/plugin-runtime-deps"
            CURRENT_VER=$(${openclawPkg}/bin/openclaw --version 2>/dev/null \
                          | ${pkgs.gnused}/bin/sed -nE 's/.*OpenClaw ([0-9.]+).*/\1/p' \
                          | ${pkgs.coreutils}/bin/head -n1)
            if [ -n "$CURRENT_VER" ] && [ -d "$DEPS_DIR" ]; then
              BAK_TS=$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)
              for entry in "$DEPS_DIR"/*; do
                [ -d "$entry" ] || continue
                base=$(${pkgs.coreutils}/bin/basename "$entry")
                case "$base" in
                  openclaw-"$CURRENT_VER"-*)  : ;;
                  openclaw-*)
                    ${pkgs.coreutils}/bin/mv "$entry" \
                      "$DEPS_DIR/.bak-$BAK_TS-$base" || true
                    ;;
                esac
              done
            fi

            # Set up mcporter config symlink if present
            if [ -d "${openclawDir}/.mcporter" ]; then
              ln -sfn ${openclawDir}/.mcporter ${stateDir}/.mcporter
            fi

            # ────────────────────────────────────────────────────────────────
            # Inject managed MCP server entries into mcporter.json
            # ────────────────────────────────────────────────────────────────
            # Helper: apply a jq filter to mcporter.json in place at mode 600.
            # Args are passed verbatim to jq (so callers supply --arg/--rawfile
            # and the filter expression). Refactored from three near-identical
            # mv/chmod tails per the 2026-05-05 review (mem 1776).
            MCPORTER_JSON="${openclawDir}/.mcporter/mcporter.json"
            apply_mcporter_jq() {
              ${pkgs.jq}/bin/jq "$@" "$MCPORTER_JSON" > "$MCPORTER_JSON.tmp" \
                && mv "$MCPORTER_JSON.tmp" "$MCPORTER_JSON" \
                && chmod 600 "$MCPORTER_JSON"
            }

            if [ -f "$MCPORTER_JSON" ]; then
              # Email + contacts (local stdio)
              apply_mcporter_jq --arg cmd "${emailMcpServer}" '
                .mcpServers["email-contacts"] = {
                  "command": $cmd,
                  "args": [],
                  "env": {
                    "IMAP_HOST": "imap.vulcan.lan",
                    "IMAP_PORT": "993",
                    "SMTP_HOST": "smtp.vulcan.lan",
                    "SMTP_PORT": "2525",
                    "EMAIL_ADDRESS": "johnw@vulcan.lan",
                    "EMAIL_USERNAME": "johnw",
                    "EMAIL_PASSWORD_FILE": "/run/openclaw-secrets/imap-password",
                    "KHARD_CONFIG": "${stateDir}/.config/khard/khard.conf"
                  },
                  "description": "Email (IMAP read/search, SMTP send) and contact lookup"
                }
              '

              # Drafts on hera via the host drafts-mcp SSE bridge (re-added
              # 2026-06 after the 2026-05-18 removal; binds 127.0.0.1:9082,
              # reached over the guest OUTPUT DNAT 127.0.0.1:9082 →
              # 10.99.0.1:9082 → host PREROUTING → 127.0.0.1:9082, same
              # loopback pattern as the hermes entry below). The bridge's
              # stdio filter shim (drafts-tool-filter, drafts-mcp.nix) is the
              # SOLE enforcement point for this autonomous VM. READ/WRITE
              # surface (owner decision 2026-06-10, superseding the launch
              # read-only posture): agents are meant to MAKE drafts on
              # request, not just see them. The shim's single remaining
              # denial is drafts_run_action — arbitrary Drafts action
              # execution (incl. script actions) as johnw inside hera's GUI
              # session is code execution, not draft management, and stays
              # operator-only. The description states that surface honestly
              # (advertising run_action would cause wasted denied calls).
              apply_mcporter_jq '
                .mcpServers["drafts-hera"] = {
                  "url": "http://127.0.0.1:9082/sse",
                  "description": "Drafts.app (macOS, on hera) via the host drafts-mcp SSE bridge. READ/WRITE surface: list/search/get drafts, tags, workspaces, and actions (drafts_search, drafts_get_draft, drafts_get_drafts, drafts_get_current, drafts_get_current_workspace, drafts_get_workspace_drafts, drafts_get_tag, drafts_list_tags, drafts_list_workspaces, drafts_list_actions, drafts_open) PLUS create/update/manage (drafts_create_draft, drafts_update_draft, drafts_add_tags, drafts_flag, drafts_archive, drafts_inbox, drafts_trash, drafts_open_workspace). The ONLY unavailable tool is drafts_run_action (arbitrary action execution) — the bridge filters it out."
                }
              '

              # Hermes Agent bridge — same loopback pattern as the
              # home-assistant entry above. The host hermes-mcp service
              # binds 127.0.0.1:9081, and the guest nftables OUTPUT
              # chain (see openclaw-vm.nix:447, dnatPortList) rewrites
              # 127.0.0.1:9081 → 10.99.0.1:9081, which the host's
              # PREROUTING DNAT then maps back to 127.0.0.1:9081 on
              # br-openclaw. Using 127.0.0.1 here (rather than the
              # bridge gateway IP) means the agent sees a "normal"
              # localhost URL with no IP to fixate on or ping-test.
              # ICMP to the loopback always succeeds, so the agent's
              # default connectivity heuristics behave sensibly.
              apply_mcporter_jq '
                .mcpServers["hermes"] = {
                  "url": "http://127.0.0.1:9081/sse",
                  "description": "Ask the Hermes Agent (NousResearch hermes-agent, a separate household LLM). USAGE: call ask_hermes(prompt=...). Responses may take 1–5 minutes because Hermes is a local 27B model; this is normal, not a failure — the MCP client is configured to wait up to 10 minutes. If a call returns an error, retry — do not declare Hermes offline. Tools: ask_hermes(prompt, session_id?), start_session(name?), continue_session(session_id, prompt), list_sessions(limit?), summarize_session(session_id), delete_session(session_id)."
                }
              '

              # Stock-trader (local stdio, talks to https://trader.vulcan.lan
              # via the bridge gateway DNAT)
              apply_mcporter_jq --arg cmd "${stockTraderMcpServer}" '
                .mcpServers["stock-trader"] = {
                  "command": $cmd,
                  "args": [],
                  "env": {
                    "STOCK_TRADER_BASE_URL": "https://trader.vulcan.lan"
                  },
                  "description": "Stock quotes, technical analysis, news sentiment, options strategies, and risk assessment via the stock-trader service"
                }
              '

              # Home Assistant via mcp-proxy stdio bridge.
              #
              # mcporter cannot talk directly to HA's MCP endpoint because
              # mcporter 0.10.1 auto-probes OAuth metadata for any HTTP/SSE
              # transport and tries RFC 7591 dynamic client registration,
              # which HA does not support.  Setting transport=http,
              # bearerToken, headers.Authorization, and auth=none all fail
              # to suppress this — mcporter ignores them once OAuth is
              # detected.  See homeAssistantMcpBridge above for the bridge
              # script that reads the staged token at spawn time and execs
              # mcp-proxy with --transport=streamablehttp + Bearer header.
              apply_mcporter_jq --arg cmd "${homeAssistantMcpBridge}" '
                .mcpServers["home-assistant"] = {
                  "command": $cmd,
                  "args": [],
                  "description": "Home Assistant (state, services, automation, devices) via mcp-proxy stdio bridge to /api/mcp with static long-lived access token"
                }
              '

              # Memory Vault — long-term memory store (see memoryVaultMcpBridge above).
              apply_mcporter_jq --arg cmd "${memoryVaultMcpBridge}" '
                .mcpServers["memory-vault"] = {
                  "command": $cmd,
                  "args": [],
                  "description": "Long-term memory (Memory Vault): semantic + keyword recall over saved notes/decisions/context, and store new memories across sessions. Tools: recall(query, spaces?, since?, limit?), remember(text, space?), forget(chunk_id), memory_status()."
                }
              '

              # SearXNG metasearch (local stdio, talks to
              # https://searxng.vulcan.lan via the bridge gateway DNAT
              # to host nginx). Returns lists of search results — use
              # this when you want raw hits to inspect.
              apply_mcporter_jq --arg cmd "${searxngMcpServer}" '
                .mcpServers["searxng"] = {
                  "command": $cmd,
                  "args": [],
                  "description": "Privacy-respecting web metasearch via SearXNG (DuckDuckGo, Bing, Wikipedia, etc.) — returns ranked result lists with titles, URLs, and snippets. Use for raw search results."
                }
              '

              # Vane (Perplexica) AI answer engine (local stdio, talks to
              # https://vane.vulcan.lan via the bridge gateway DNAT to
              # host nginx). Vane runs SearXNG behind the scenes and
              # synthesizes a cited answer — use this when you want a
              # researched digest rather than a list of hits.
              apply_mcporter_jq --arg cmd "${vaneMcpServer}" '
                .mcpServers["vane"] = {
                  "command": $cmd,
                  "args": [],
                  "description": "AI answer engine (Vane / Perplexica) — synthesizes a cited response from web sources. Slower than searxng but produces a written answer with linked citations. Use for research-style questions."
                }
              '
            fi

            # ────────────────────────────────────────────────────────────────
            # Himalaya email client configuration
            # ────────────────────────────────────────────────────────────────
            # Config is written on every start so it reflects the current
            # staging directory layout. Password is read at command time.
            # Read IMAP password at preStart time so we can embed it as auth.raw.
            # himalaya's process-lib hardcodes "sh -c" for auth.cmd which fails when sh
            # is not in PATH; auth.raw avoids spawning a subprocess entirely.
            IMAP_PASS=$(cat /run/openclaw-secrets/imap-password)
            cat > ${stateDir}/.config/himalaya/config.toml << HIMALAYA_END
      [accounts.johnw]
      email = "johnw@vulcan.lan"
      display-name = "John Wiegley"
      default = true

      # IMAP: Dovecot at imap.vulcan.lan:993 via two-stage DNAT
      # TLS verified against Vulcan Step-CA (added to VM trust store via security.pki.certificates)
      backend.type = "imap"
      backend.host = "imap.vulcan.lan"
      backend.port = 993
      backend.encryption.type = "tls"
      backend.login = "johnw"
      backend.auth.type = "password"
      backend.auth.raw = "$IMAP_PASS"

      # SMTP: Postfix port 2525 via two-stage DNAT
      # Plain/no-TLS, permit_mynetworks (VM IP 10.99.0.2 ∈ 10.0.0.0/8)
      # Auth via Dovecot SASL (same credentials as IMAP)
      message.send.backend.type = "smtp"
      message.send.backend.host = "smtp.vulcan.lan"
      message.send.backend.port = 2525
      message.send.backend.encryption.type = "none"
      message.send.backend.login = "johnw"
      message.send.backend.auth.type = "password"
      message.send.backend.auth.raw = "$IMAP_PASS"
      message.send.save-copy = false
      HIMALAYA_END
            chmod 600 ${stateDir}/.config/himalaya/config.toml

            # ────────────────────────────────────────────────────────────────
            # vdirsyncer: sync Radicale contacts to local vCard files
            # ────────────────────────────────────────────────────────────────
            # Use root URL + explicit collection so vdirsyncer can discover it.
            # Full cat path ensures the password.fetch command works regardless of PATH.
            cat > ${stateDir}/.config/vdirsyncer/config << VDIRSYNCER_END
      [general]
      status_path = "${openclawDir}/.vdirsyncer/status"

      [pair contacts]
      a = "radicale"
      b = "local"
      collections = [["contacts", "contacts", "contacts"]]

      [storage radicale]
      type = "carddav"
      url = "http://radicale.vulcan.lan:5232/"
      username = "johnw"
      password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "/run/openclaw-secrets/radicale-password"]

      [storage local]
      type = "filesystem"
      path = "${openclawDir}/contacts/"
      fileext = ".vcf"
      VDIRSYNCER_END
            chmod 600 ${stateDir}/.config/vdirsyncer/config

            # ────────────────────────────────────────────────────────────────
            # khard: CLI contact manager for vCard files
            # contacts subdirectory is created by vdirsyncer for the "contacts" collection
            # ────────────────────────────────────────────────────────────────
            cat > ${stateDir}/.config/khard/khard.conf << KHARD_END
      [addressbooks]
      [[contacts]]
      path = ${openclawDir}/contacts/contacts/

      [general]
      default_action = show
      editor = cat
      merge_editor = cat
      KHARD_END
            chmod 600 ${stateDir}/.config/khard/khard.conf

            # ────────────────────────────────────────────────────────────────
            # Sherlock: read-only database query tool configuration
            # ────────────────────────────────────────────────────────────────
            # Sherlock connects to PostgreSQL on host via two-stage DNAT
            # (127.0.0.1:5432 → 10.99.0.1:5432 → host 127.0.0.1:5432).
            # Password is read from the SOPS-staged secret at preStart time.
            SHERLOCK_DIR="${stateDir}/.config/sherlock"
            mkdir -p "$SHERLOCK_DIR"
            ORG_DB_PASS=""
            if [ -f /run/openclaw-secrets/org-db-password ]; then
              ORG_DB_PASS=$(cat /run/openclaw-secrets/org-db-password)
            fi
            cat > "$SHERLOCK_DIR/config.json" <<'SHERLOCK_END'
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
            # Inject the actual password (avoids shell quoting issues in heredoc)
            ${pkgs.jq}/bin/jq --arg pass "$ORG_DB_PASS" '.connections.org.password = $pass' \
              "$SHERLOCK_DIR/config.json" > "$SHERLOCK_DIR/config.json.tmp"
            mv "$SHERLOCK_DIR/config.json.tmp" "$SHERLOCK_DIR/config.json"
            chmod 600 "$SHERLOCK_DIR/config.json"

            # Append Sherlock section to TOOLS.md (idempotent)
            TOOLS_MD="${openclawDir}/workspace/TOOLS.md"
            if [ -f "$TOOLS_MD" ] && ! grep -q '## Sherlock Database Tool' "$TOOLS_MD"; then
              cat ${toolsSherlockMd} >> "$TOOLS_MD"
            fi

            # ────────────────────────────────────────────────────────────────
            # org db search: semantic search over org-mode entries
            # ────────────────────────────────────────────────────────────────
            # Minimal config.yaml required by the org CLI even for db commands.
            ORG_CONF_DIR="${stateDir}/.config/org"
            mkdir -p "$ORG_CONF_DIR"
            cat > "$ORG_CONF_DIR/config.yaml" << 'ORG_CONFIG_END'
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
            chmod 644 "$ORG_CONF_DIR/config.yaml"

            # Append org db search section to TOOLS.md (idempotent)
            if [ -f "$TOOLS_MD" ] && ! grep -q '## Org Semantic Search' "$TOOLS_MD"; then
              cat ${toolsOrgSearchMd} >> "$TOOLS_MD"
            fi

            # Append web search section (searxng + vane + how to combine
            # with the built-in Perplexity tool) — idempotent.
            if [ -f "$TOOLS_MD" ] && ! grep -q '## Web Search & Research' "$TOOLS_MD"; then
              cat ${toolsWebSearchMd} >> "$TOOLS_MD"
            fi

            # Append the network-isolation and memory-qdrant invariants so the
            # agent stops reporting designed behaviour (no SSH to the host,
            # memory-qdrant absent from mcporter, :8080 refused) as outages.
            # Idempotent; note the grep guard means editing the section text
            # above will NOT re-append over an existing TOOLS.md — change the
            # heading, or remove the stale block by hand, to force a refresh.
            if [ -f "$TOOLS_MD" ] && ! grep -q '## Network Isolation' "$TOOLS_MD"; then
              cat ${toolsNetworkIsolationMd} >> "$TOOLS_MD"
            fi

            if [ -f "$TOOLS_MD" ] && ! grep -q '## memory-qdrant Health Signals' "$TOOLS_MD"; then
              cat ${toolsMemoryQdrantMd} >> "$TOOLS_MD"
            fi

            # ────────────────────────────────────────────────────────────────
            # Sync contacts from Radicale (best-effort at service start)
            # ────────────────────────────────────────────────────────────────
            VDIR_LOG="${openclawDir}/logs/vdirsyncer-startup.log"
            echo "=== vdirsyncer startup $(date -u) ===" | tee -a "$VDIR_LOG"
            if [ -f /run/openclaw-secrets/radicale-password ]; then
              # Test Radicale connectivity
              echo "Testing Radicale at http://radicale.vulcan.lan:5232/ ..." | tee -a "$VDIR_LOG"
              HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 5 "http://radicale.vulcan.lan:5232/" 2>&1 || echo "CURL_FAILED")
              echo "Radicale HTTP response: $HTTP_CODE" | tee -a "$VDIR_LOG"

              echo "Running vdirsyncer discover..." | tee -a "$VDIR_LOG"
              ${pkgs.vdirsyncer}/bin/vdirsyncer \
                --config ${stateDir}/.config/vdirsyncer/config \
                discover contacts 2>&1 | tee -a "$VDIR_LOG" | head -20 || \
                echo "vdirsyncer discover failed" | tee -a "$VDIR_LOG"

              echo "Running vdirsyncer sync..." | tee -a "$VDIR_LOG"
              ${pkgs.vdirsyncer}/bin/vdirsyncer \
                --config ${stateDir}/.config/vdirsyncer/config \
                sync 2>&1 | tee -a "$VDIR_LOG" | head -40 || \
                echo "vdirsyncer sync failed; will use cached contacts if available" | tee -a "$VDIR_LOG"
              echo "Contact count: $(ls ${openclawDir}/contacts/contacts/*.vcf 2>/dev/null | wc -l) vCards" | tee -a "$VDIR_LOG"
            else
              echo "Radicale credentials not staged; skipping contact sync" | tee -a "$VDIR_LOG"
            fi

            # ────────────────────────────────────────────────────────────────
            # Install acpx plugin to a writable location
            # ────────────────────────────────────────────────────────────────
            # The stock extensions live in the read-only nix store; npm install
            # fails there. Copy the extension to the writable state dir so
            # OpenClaw can install its npm dependencies.
            ACPX_SRC="${openclawPkg}/lib/openclaw/extensions/acpx"
            ACPX_DST="${openclawDir}/plugins/acpx"
            if [ -d "$ACPX_SRC" ] && [ ! -d "$ACPX_DST/node_modules/acpx/node_modules" ]; then
              echo "Installing acpx plugin to writable location..."
              mkdir -p "${openclawDir}/plugins"
              rm -rf "$ACPX_DST"
              cp -a "$ACPX_SRC" "$ACPX_DST"
              chmod -R u+w "$ACPX_DST"
              cd "$ACPX_DST"
              ${pkgs.nodejs_22}/bin/npm install --omit=dev 2>&1 || echo "acpx npm install failed (non-fatal)"
              cd "${stateDir}"
            fi

            # Register the writable acpx plugin with OpenClaw's plugin system
            cd "${stateDir}"
            ${openclawPkg}/bin/openclaw plugins install --link "${openclawDir}/plugins/acpx" 2>&1 || \
              echo "acpx plugin registration failed (non-fatal)"

            # Rebuild sharp native module for aarch64-linux if needed
            SHARP_REL="${openclawDir}/workspace/skills/memory-qdrant/node_modules/sharp/build/Release"
            if [ -d "$SHARP_REL" ] && \
               [ ! -f "$SHARP_REL/sharp-linux-arm64v8.node" ]; then
              echo "Installing sharp linux-arm64 binary..."
              cd "${openclawDir}/workspace/skills/memory-qdrant"
              ${pkgs.nodejs_22}/bin/npm rebuild sharp 2>&1 || true
              cd "${stateDir}"
            fi
    '';
  };

  # ========================================================================
  # Guest firewall
  # ========================================================================

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ servicePort ];
    extraInputRules = ''
      ip saddr 10.99.0.1 tcp dport 22 accept comment "openclaw-nightly-report probe from host bridge"
    '';
  };

  # ========================================================================
  # Network isolation diagnostic (runs once at boot, writes to shared dir)
  # ========================================================================

  systemd.services.network-diag = {
    description = "Network isolation connectivity test";
    after = [
      "network-online.target"
      "nftables.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      curl
      nftables
      iproute2
      coreutils
    ];
    script = ''
      OUT="${stateDir}/.openclaw/netdiag.txt"
      echo "=== Network Isolation Diagnostic ===" > "$OUT"
      echo "Time: $(date -u)" >> "$OUT"
      echo "" >> "$OUT"

      # Dump guest nftables rules
      echo "--- Guest nftables rules ---" >> "$OUT"
      nft list ruleset >> "$OUT" 2>&1
      echo "" >> "$OUT"

      # Dump guest routing table
      echo "--- Guest routes ---" >> "$OUT"
      ip route >> "$OUT" 2>&1
      echo "" >> "$OUT"

      # Dump /etc/hosts
      echo "--- Guest /etc/hosts ---" >> "$OUT"
      cat /etc/hosts >> "$OUT" 2>&1
      echo "" >> "$OUT"

      echo "--- Connectivity Tests ---" >> "$OUT"

      # MUST BE BLOCKED: 192.168.1.2 (any port)
      # Port 22 is in this list because VM -> host SSH is meant to fail: it is
      # not in dnatPorts, so `openclaw-isolate` DROPs it. "PASS: ...:22 blocked"
      # here is the assertion that the isolation boundary holds — it is not an
      # outage, and it carries no information about whether John is at home.
      for port in 443 993 25 80 22; do
        if curl -sk --connect-timeout 3 "https://192.168.1.2:$port/" >/dev/null 2>&1; then
          echo "FAIL: 192.168.1.2:$port REACHABLE (should be blocked)" >> "$OUT"
        else
          echo "PASS: 192.168.1.2:$port blocked" >> "$OUT"
        fi
      done

      # MUST BE BLOCKED: other 192.168.x.x hosts
      for host in 192.168.1.4 192.168.1.5 192.168.3.16; do
        if curl -sk --connect-timeout 3 "https://$host:443/" >/dev/null 2>&1; then
          echo "FAIL: $host:443 REACHABLE (should be blocked)" >> "$OUT"
        else
          echo "PASS: $host:443 blocked" >> "$OUT"
        fi
      done

      # MUST WORK: DNS resolution
      echo "--- DNS Tests ---" >> "$OUT"
      DNS_RESULT=$(${pkgs.dig}/bin/dig +short +timeout=3 @${bridgeAddr} example.com A 2>&1)
      if [ -n "$DNS_RESULT" ] && echo "$DNS_RESULT" | grep -qE '^[0-9]+\.[0-9]+'; then
        echo "PASS: DNS resolution works (example.com -> $DNS_RESULT)" >> "$OUT"
      else
        echo "FAIL: DNS resolution broken (result: $DNS_RESULT)" >> "$OUT"
      fi

      # MUST WORK: bridge gateway services (TCP connect test)
      echo "--- Bridge Gateway Services ---" >> "$OUT"
      for port in 443 4000 6333 8123; do
        if curl -sk --connect-timeout 3 "https://${bridgeAddr}:$port/" >/dev/null 2>&1 || \
           curl -s --connect-timeout 3 "http://${bridgeAddr}:$port/" >/dev/null 2>&1; then
          echo "PASS: ${bridgeAddr}:$port reachable (HTTP)" >> "$OUT"
        else
          # Raw TCP connect test using /dev/tcp
          if (echo > /dev/tcp/${bridgeAddr}/$port) 2>/dev/null; then
            echo "PASS: ${bridgeAddr}:$port reachable (TCP)" >> "$OUT"
          else
            echo "WARN: ${bridgeAddr}:$port not reachable" >> "$OUT"
          fi
        fi
      done

      # MUST WORK: internet by IP (bypasses DNS)
      echo "--- Internet Tests ---" >> "$OUT"
      if curl -s --connect-timeout 5 "http://93.184.215.14/" >/dev/null 2>&1; then
        echo "PASS: Internet by IP (93.184.215.14) reachable" >> "$OUT"
      else
        echo "FAIL: Internet by IP (93.184.215.14) NOT reachable" >> "$OUT"
      fi

      # Internet by name (tests DNS + connectivity)
      if curl -s --connect-timeout 5 "https://example.com" >/dev/null 2>&1; then
        echo "PASS: Internet by name (example.com) reachable" >> "$OUT"
      else
        echo "FAIL: Internet by name (example.com) NOT reachable" >> "$OUT"
      fi

      # MUST NOT WORK: localhost:8080 (old embedding server)
      # llama-swap binds 127.0.0.1:8080 on the host and is deliberately absent
      # from dnatPorts; the VM reaches those models through LiteLLM on :4000,
      # which is what the memory-qdrant plugin actually calls. A refused
      # connection here is the designed steady state, so any health check
      # reporting "embedding server down on :8080" is probing a retired path.
      echo "--- Negative Tests ---" >> "$OUT"
      if curl -s --connect-timeout 3 "http://127.0.0.1:8080/" >/dev/null 2>&1; then
        echo "INFO: 127.0.0.1:8080 reachable (unexpected)" >> "$OUT"
      else
        echo "PASS: 127.0.0.1:8080 not reachable (correct)" >> "$OUT"
      fi

      echo "" >> "$OUT"
      echo "=== Done ===" >> "$OUT"
    '';
  };

  # Allow password-less root login on serial console for debugging.
  # The VM is only accessible from the host via the bridge network;
  # this is safe because the serial console is only reachable by root
  # on the host (via the microvm journal).
  users.users.root.initialHashedPassword = "";
}
