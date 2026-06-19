{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

# Memory Vault — local-first AI memory system (PostgreSQL + pgvector, hybrid
# search, MCP). Runs as TWO rootless Podman quadlet containers under the
# dedicated `memory-vault` user, both pointed at the HOST PostgreSQL instance:
#
#   memory-vault     — full app: FastAPI REST API + React dashboard + automatic
#                      DB migrations on boot. Loopback 127.0.0.1:8235 → nginx TLS
#                      at https://memory.vulcan.lan (token auth + IP allowlist).
#   memory-vault-mcp — the SAME MCP tools (recall/remember/forget/memory_status)
#                      but served over Streamable HTTP instead of stdio, so the
#                      OpenClaw + Hermes microVMs and LAN MCP clients can reach
#                      it. Loopback 127.0.0.1:8236 → nginx TLS at
#                      https://memory-mcp.vulcan.lan (IP allowlist).
#
# System-level wiring (nginx vhosts, SOPS secret/env-file, the MCP wrapper
# script, bootstrap certs, firewall) lives in
# /etc/nixos/modules/containers/memory-vault-quadlet.nix. The PostgreSQL role,
# database and pgvector extension are in /etc/nixos/modules/services/databases.nix.

let
  # Rendered KEY=value env file (DB_PASSWORD=...) produced by sops.templates in
  # memory-vault-quadlet.nix. Fixed path keeps this module decoupled from the
  # other module's evaluation.
  envFile = "/run/secrets-memory-vault/env";

  appImage = "ghcr.io/mihaibuilds/memory-vault:1.0.6";
  mcpImage = "ghcr.io/mihaibuilds/memory-vault-mcp:1.0.6";

  # PostgreSQL connection shared by both containers. slirp4netns with
  # allow_host_loopback lets `host.containers.internal` reach the host's
  # 127.0.0.1:5432 (already authorized by pg_hba 127.0.0.1/32 scram-sha-256),
  # matching the shlink/speedtest-tracker convention.
  dbEnv = {
    DB_HOST = "host.containers.internal";
    DB_PORT = "5432";
    DB_NAME = "memory_vault";
    DB_USER = "memory_vault";
    # DB_PASSWORD comes from envFile (SOPS-rendered), never from the Nix store.
    # HF model cache on a persistent named volume so all-MiniLM-L6-v2 is
    # downloaded once and shared between both containers.
    HF_HOME = "/hf";
  };

  # pg_isready gate (runs on the host as the memory-vault user) — the host
  # cluster listens on all interfaces, reachable via 127.0.0.1.
  pgGate = "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do ${config.services.postgresql.package}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 2 && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; exit 1'";
in
{
  home-manager.users.memory-vault =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      home.stateVersion = "24.11";
      home.username = "memory-vault";
      home.homeDirectory = "/var/lib/containers/memory-vault";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
        postgresql # pg_isready health gate
      ];

      # --- Full app: REST API + dashboard + migrations ---------------------
      virtualisation.quadlet.containers.memory-vault = {
        autoStart = true;

        containerConfig = {
          image = appImage;
          publishPorts = [ "127.0.0.1:8235:8000/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environments = dbEnv // {
            API_HOST = "0.0.0.0";
            API_PORT = "8000";
            API_AUTH_ENABLED = "true";
            API_CORS_ORIGINS = "https://memory.vulcan.lan";
            # Behind a single reverse-proxy source IP the per-IP limiter is
            # effectively global; keep it generous for dashboard browsing.
            API_RATE_LIMIT_PER_MIN = "600";
            LOG_LEVEL = "INFO";
          };

          environmentFiles = [ envFile ];

          volumes = [
            "memory-vault-hf:/hf"
          ];
        };

        unitConfig = {
          # Order after sops-nix so the rendered DB_PASSWORD env file exists on
          # first (cold-boot) start, mirroring vane.nix.
          After = [
            "network-online.target"
            "sops-nix.service"
          ];
          Wants = [ "sops-nix.service" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          ExecStartPre = pgGate;
          Restart = "always";
          RestartSec = "10s";
          # First boot pulls the image and downloads the embedding model.
          TimeoutStartSec = "900";
          LogLevelMax = "warning";
        };
      };

      # --- MCP server over Streamable HTTP ---------------------------------
      # Reuse the MCP-only image but override the stdio entrypoint with the
      # wrapper at /opt/mcp-http.py (mounted from /etc/memory-vault) which runs
      # the same FastMCP object with transport="streamable-http".
      virtualisation.quadlet.containers.memory-vault-mcp = {
        autoStart = true;

        containerConfig = {
          image = mcpImage;
          entrypoint = "python";
          exec = "/opt/mcp-http.py";
          publishPorts = [ "127.0.0.1:8236:8236/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environments = dbEnv // {
            MCP_HTTP_HOST = "0.0.0.0";
            MCP_HTTP_PORT = "8236";
            # Image already sets PYTHONPATH=/app; set it explicitly so the
            # wrapper's `from src.mcp.server import mcp` resolves regardless of
            # how the entrypoint is overridden.
            PYTHONPATH = "/app";
          };

          environmentFiles = [ envFile ];

          volumes = [
            "memory-vault-hf:/hf"
            "/etc/memory-vault/mcp-http.py:/opt/mcp-http.py:ro"
          ];
        };

        unitConfig = {
          # Order after sops-nix (env file) and the app container (DB migrations).
          After = [
            "network-online.target"
            "sops-nix.service"
            "podman-memory-vault.service"
          ];
          Wants = [ "sops-nix.service" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          ExecStartPre = pgGate;
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";
          LogLevelMax = "warning";
        };
      };
    };
}
