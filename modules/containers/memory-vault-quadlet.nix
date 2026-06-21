{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

# Memory Vault — system-level integration. The containers themselves are
# rootless and defined in /etc/nixos/modules/users/home-manager/memory-vault.nix.
# This module wires the SOPS DB password + rendered env file, the two nginx TLS
# vhosts (dashboard/API and the MCP Streamable-HTTP endpoint), the MCP wrapper
# script, bootstrap self-signed certs, and the loopback firewall openings.
#
# The PostgreSQL role/database/pgvector extension are in
# /etc/nixos/modules/services/databases.nix.

let
  common = import ../lib/common.nix { inherit secrets; };

  apiPort = 8235; # 127.0.0.1 — REST API + dashboard (container :8000)
  mcpPort = 8236; # 127.0.0.1 — MCP Streamable HTTP

  # LAN + microVM + VPN subnets only. The dashboard additionally enforces its own
  # bearer-token auth; the MCP endpoint has no app-level auth, so this allow
  # list is its only access control (per design decision).
  lanOnly = ''
    allow 192.168.0.0/16;
    allow 10.99.0.0/16;
    allow 10.6.0.0/24;
    allow 127.0.0.1/8;
    deny all;
  '';
in
{
  ##########################################################################
  # SOPS: bare PostgreSQL password.
  #   - host postgres role is set from this value via mkPostgresUserSetup
  #     (databases.nix), which reads the path below as the postgres user.
  #   - the container receives it as DB_PASSWORD via the rendered env file.
  # The operator must add the key `memory-vault/db-password` with
  #   sops /etc/nixos/secrets.yaml
  ##########################################################################
  sops.secrets."memory-vault/db-password" = {
    sopsFile = common.secretsPath;
    owner = "root";
    group = "postgres";
    mode = "0440";
    restartUnits = [
      "postgresql-memory_vault-setup.service"
    ];
  };

  # Render the container env file from the bare secret. sops-nix deploys this
  # early (before the rootless user manager starts), so the quadlet
  # environmentFiles is present on first start.
  sops.templates."memory-vault-env" = {
    content = ''
      DB_PASSWORD=${config.sops.placeholder."memory-vault/db-password"}
    '';
    path = "/run/secrets-memory-vault/env";
    owner = "memory-vault";
    group = "memory-vault";
    mode = "0400";
    # No restartUnits: the containers are rootless *user* units, which sops-nix
    # (running in the system manager) cannot restart cross-manager (it would log
    # "Unit not found"). They order After=sops-nix.service so they pick up the
    # rendered env on (re)start; after rotating the password, restart them with
    # `systemctl --user -M memory-vault@ restart podman-memory-vault podman-memory-vault-mcp`.
  };

  # MCP Streamable-HTTP wrapper, mounted into the memory-vault-mcp container.
  # Reuses the upstream FastMCP server object (identical recall/remember/forget/
  # memory_status tools) and serves Streamable HTTP instead of stdio so it can
  # sit behind nginx. Bind host/port come from MCP_HTTP_HOST / MCP_HTTP_PORT.
  environment.etc."memory-vault/mcp-http.py".text = ''
    import os

    from src.mcp.server import mcp

    mcp.settings.host = os.environ.get("MCP_HTTP_HOST", "0.0.0.0")
    mcp.settings.port = int(os.environ.get("MCP_HTTP_PORT", "8000"))
    mcp.run(transport="streamable-http")
  '';

  ##########################################################################
  # nginx: dashboard + REST API. The app enforces bearer-token auth; this
  # vhost additionally restricts to the LAN/microVM subnets.
  ##########################################################################
  services.nginx.virtualHosts."memory.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/memory.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/memory.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString apiPort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 100M;
        ${lanOnly}
      '';
    };
  };

  ##########################################################################
  # nginx: MCP Streamable-HTTP endpoint.
  #
  # FastMCP enables DNS-rebinding protection and rejects a proxied Host header
  # with 421 "Invalid Host header"; it only accepts the loopback bind it serves
  # on. So we MUST rewrite Host to 127.0.0.1:<mcpPort> here and must NOT enable
  # recommendedProxySettings / forward $host. proxy_buffering off + HTTP/1.1 are
  # required for the SSE/streaming responses.
  ##########################################################################
  services.nginx.virtualHosts."memory-mcp.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/memory-mcp.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/memory-mcp.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString mcpPort}";
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Host "127.0.0.1:${toString mcpPort}";
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 50M;
        ${lanOnly}
      '';
    };
  };

  ##########################################################################
  # Bootstrap self-signed certs so nginx can start before the real step-ca
  # certs are minted (mirrors budgetboard-certificate). Prints the exact
  # renew-certificate.sh command the operator should run.
  ##########################################################################
  systemd.services.memory-vault-certificate = {
    description = "Bootstrap TLS certificates for Memory Vault vhosts";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [
      pkgs.openssl
      pkgs.step-cli
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      for host in memory.vulcan.lan memory-mcp.vulcan.lan; do
        CRT="$CERT_DIR/$host.crt"
        KEY="$CERT_DIR/$host.key"

        if [ -f "$CRT" ] && [ -f "$KEY" ] \
          && ${pkgs.openssl}/bin/openssl x509 -in "$CRT" -noout -checkend 2592000; then
          echo "Certificate for $host is still valid (>30d); leaving it."
          continue
        fi

        echo "Creating temporary self-signed certificate for $host"
        echo "Generate the real step-ca certificate with:"
        echo "  sudo /etc/nixos/certs/renew-certificate.sh $host -o /var/lib/nginx-certs -d 365 --owner nginx:nginx --cert-perms 644 --key-perms 600"

        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
          -keyout "$KEY" -out "$CRT" -days 365 -nodes \
          -subj "/CN=$host" -addext "subjectAltName=DNS:$host"

        chmod 644 "$CRT"
        chmod 600 "$KEY"
        chown nginx:nginx "$CRT" "$KEY"
      done
    '';
  };

  # nginx → loopback app/mcp ports (loopback is unfiltered by default, but keep
  # an explicit opening for clarity, matching the vane pattern).
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    apiPort
    mcpPort
  ];
}
