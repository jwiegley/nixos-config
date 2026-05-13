# hermes-mcp: OpenClaw↔Hermes MCP bridge.
#
# Wraps the hermes-mcp package (pkgs/hermes-mcp, wired via
# overlays/default.nix) as a hardened systemd service. The service
# exposes an MCP Streamable HTTP/SSE endpoint on 127.0.0.1:9081
# that OpenClaw's microVM reaches via the existing two-stage DNAT
# chain (see modules/services/openclaw-microvm.nix): the VM connects
# to 10.99.0.1:9081, which is host-PREROUTING-DNAT'ed to
# 127.0.0.1:9081 on the br-openclaw interface.
#
# The bridge talks to the Hermes Agent microVM at 10.99.1.2:8080
# (api_server platform) using Authorization: Bearer ${API_SERVER_KEY}.
# That key already lives in the SOPS-encrypted `hermes/env` secret
# used by the Hermes microVM staging job, so we reuse it directly via
# `EnvironmentFile` rather than declaring a duplicate sops block.
# systemd loads EnvironmentFile as PID 1 (root) before dropping to
# User=hermes-mcp, so the service user does NOT need read access to
# the secret itself — only the manager does.
#
# Modeled on modules/services/stock-trader.nix for the hardening and
# packaging patterns. Differences vs stock-trader.nix:
#
#   - No nginx vhost or TLS termination. The bridge is loopback-only
#     and only reachable via the openclaw-microvm DNAT chain; LAN
#     hosts on 192.168.0.0/16 cannot reach it.
#   - Static User= (not DynamicUser=) because we need a stable
#     identity that owns /var/lib/hermes-mcp/sessions.db across
#     rebuilds and runs.
#   - EnvironmentFile= reuses /run/secrets/hermes/env directly; no
#     LoadCredential bridge script.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hermes-mcp;
in
{
  options.services.hermes-mcp = {
    enable = lib.mkEnableOption "the hermes-mcp MCP bridge";

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Bind address for the SSE endpoint. The default 127.0.0.1
        keeps the service unreachable from the LAN; OpenClaw's
        microVM accesses it via the two-stage DNAT chain in
        openclaw-microvm.nix.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9081;
      description = "TCP port for the SSE endpoint.";
    };

    hermesApiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://10.99.1.2:8080";
      description = ''
        Base URL for the Hermes Agent api_server, exposed on the
        hermes microVM bridge IP. The bridge interface accepts
        :8080 only from the host bridge address (see
        modules/services/hermes-vm.nix firewall rules).
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "hera/omlx/Qwen3.6-27B-MLX-8bit";
      description = ''
        Default model identifier passed to Hermes' /v1/chat/completions
        when the MCP caller does not override it. The string must be
        a route the Hermes-side LLM router accepts.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes-mcp";
      description = ''
        Directory holding the SQLite session store. Owned by the
        hermes-mcp service user; persists across rebuilds (created
        via tmpfiles `d` directive, NOT `D`).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- Static service user/group ----
    # Static (not DynamicUser) because /var/lib/hermes-mcp/sessions.db
    # must be owned consistently across rebuilds. No supplementary
    # groups: systemd reads EnvironmentFile as root (PID 1) before
    # User= takes effect, so the runtime user never needs the
    # hermes group's secret-read permission.
    users.users.hermes-mcp = {
      isSystemUser = true;
      group = "hermes-mcp";
      home = cfg.stateDir;
      description = "hermes-mcp MCP bridge runtime user";
    };
    users.groups.hermes-mcp = { };

    # Persistent state directory. `d` (not `D`) is critical here —
    # `D` would empty sessions.db on every rebuild. See CLAUDE.md
    # "Data Loss Prevention" notes.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 hermes-mcp hermes-mcp -"
    ];

    # Make sure secret rotation propagates to this service too. The
    # base declaration lives in modules/services/hermes-microvm.nix
    # and lists the microVM staging units; this appends ours.
    sops.secrets."hermes/env".restartUnits = [ "hermes-mcp.service" ];

    systemd.services.hermes-mcp = {
      description = "OpenClaw↔Hermes MCP bridge (SSE)";
      # microvm@hermes.service must be up for the api_server to answer.
      # We don't `requires=` it (the bridge should start cleanly even
      # if the VM is briefly down and recover on its own retry), but
      # we order ourselves after it so cold boot ordering is sane.
      after = [
        "network-online.target"
        "sops-install-secrets.service"
        "microvm@hermes.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        HERMES_API_URL = cfg.hermesApiUrl;
        HERMES_MCP_HOST = cfg.host;
        HERMES_MCP_PORT = toString cfg.port;
        HERMES_MCP_MODEL = cfg.model;
        HERMES_MCP_DB_PATH = "${cfg.stateDir}/sessions.db";
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.hermes-mcp}/bin/hermes-mcp";
        Restart = "on-failure";
        RestartSec = "5s";

        User = "hermes-mcp";
        Group = "hermes-mcp";

        # API_SERVER_KEY (and any other vars the Hermes config sets)
        # arrive via the SOPS-decrypted file. systemd loads this as
        # root before the User= switch, so 0640 hermes:hermes is fine.
        EnvironmentFile = config.sops.secrets."hermes/env".path;

        # State + runtime dirs are bind-mounted in by systemd.
        StateDirectory = "hermes-mcp";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "hermes-mcp";
        RuntimeDirectoryMode = "0750";

        # Hardening — match stock-trader.nix; no SageMath caveats apply.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        # Same caveat as stock-trader: Python's runtime needs W^X off.
        MemoryDenyWriteExecute = false;

        MemoryMax = "512M";
      };
    };
  };
}
