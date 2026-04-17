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
  networking.hosts = {
    ${bridgeAddr} = [
      "hass.vulcan.lan"
      "qdrant.vulcan.lan"
      "litellm.vulcan.lan"
      "imap.vulcan.lan" # Dovecot IMAPS (via DNAT 10.99.0.1:993 → 127.0.0.1:993)
      "smtp.vulcan.lan" # Postfix SMTP (via DNAT 10.99.0.1:2525 → 127.0.0.1:2525)
      "radicale.vulcan.lan" # Radicale CardDAV (via DNAT 10.99.0.1:5232 → 127.0.0.1:5232)
      "drafts-mcp.vulcan.lan" # Drafts MCP (via nginx → hera:8808)
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
            #  - Embedding URL: rewrite localhost:8080 → localhost:4000 (LiteLLM)
            #  - Schema migration: flatten tools.web.search.<provider>.apiKey → tools.web.search.apiKey
            #    (openclaw >=2026.3.28 rejects nested provider config as "Unrecognized key")
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

            # Set up mcporter config symlink if present
            if [ -d "${openclawDir}/.mcporter" ]; then
              ln -sfn ${openclawDir}/.mcporter ${stateDir}/.mcporter
            fi

            # ────────────────────────────────────────────────────────────────
            # Inject email-contacts MCP server into mcporter.json
            # ────────────────────────────────────────────────────────────────
            MCPORTER_JSON="${openclawDir}/.mcporter/mcporter.json"
            if [ -f "$MCPORTER_JSON" ]; then
              ${pkgs.jq}/bin/jq --arg cmd "${emailMcpServer}" '
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
              ' "$MCPORTER_JSON" > "$MCPORTER_JSON.tmp"
              mv "$MCPORTER_JSON.tmp" "$MCPORTER_JSON"
              chmod 600 "$MCPORTER_JSON"

              # ──────────────────────────────────────────────────────────────
              # Inject Drafts MCP server (remote, on hera via nginx proxy)
              # ──────────────────────────────────────────────────────────────
              ${pkgs.jq}/bin/jq '
                .mcpServers["drafts"] = {
                  "url": "https://drafts-mcp.vulcan.lan/sse",
                  "description": "Create and manage Drafts notes (Drafts app on hera)"
                }
              ' "$MCPORTER_JSON" > "$MCPORTER_JSON.tmp"
              mv "$MCPORTER_JSON.tmp" "$MCPORTER_JSON"
              chmod 600 "$MCPORTER_JSON"
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
