# Always-running CloudFlare Tunnels for external service access
#
# Provides persistent CloudFlare Tunnel connections for:
# - data.newartisans.com → localhost:18080 (static-nginx container; 18080 is
#   owned by static-nginx-http.socket. The copyparty-backed secure-nginx.nix
#   that also claims 18080 is imported by nothing, and the live copyparty
#   container listens on 127.0.0.1:13923 instead.)
# - gitea.newartisans.com → localhost:3005 (Gitea)
# - s.newartisans.com → localhost:8580 (Shlink)
# - calendar.newartisans.com → localhost:8090 (Sacramento Cluster .ics)

{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Ensure cloudflared user and group exist
  users.users.cloudflared = {
    group = "cloudflared";
    isSystemUser = true;
  };

  users.groups.cloudflared = { };

  # SOPS secrets for tunnel credentials
  sops.secrets."cloudflared/data" = {
    owner = "cloudflared";
    group = "cloudflared";
    mode = "0400";
    restartUnits = [ "cloudflared-tunnel-data.service" ];
  };

  # CloudFlare Tunnel service configuration
  services.cloudflared = {
    enable = true;
    tunnels = {
      # Data tunnel: serves multiple external domains
      "data" = {
        credentialsFile = config.sops.secrets."cloudflared/data".path;
        default = "http_status:404";

        ingress = {
          "data.newartisans.com" = "http://localhost:18080";
          "gitea.newartisans.com" = "http://localhost:3005";
          # DISABLED 2026-07-31: shlink has an unpatched security advisory; re-enable only after upgrading.
          # Route removed so the public hostname resolves to nothing rather than a dead
          # backend. shlink was the ONLY cloudflared-ingress podman image.
          # "s.newartisans.com" = "http://localhost:8580";
          "calendar.newartisans.com" = "http://localhost:8090";
        };
      };
    };
  };

  # Ensure tunnels start automatically and stay running
  # Added resilience for boot timing: delays between restarts and higher burst limit
  systemd.services."cloudflared-tunnel-data" = {
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nss-lookup.target"
      # Wait for the LOCAL resolver (Technitium) to actually be SERVING. dns.nix
      # now makes technitium Before=nss-lookup.target with a readiness probe, so
      # After=nss-lookup.target genuinely means "DNS answers" — this explicit edge
      # is belt-and-suspenders.
      "technitium-dns-server.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "network-online.target" ];
    description = "CloudFlare Tunnel for data.newartisans.com";

    # Expose cloudflared's Prometheus metrics endpoint so the tunnel's health is
    # actually observable. Without this, the public tunnel had ZERO metric
    # visibility — it was only watched via the systemd-unit-active check, which
    # cannot see a tunnel that is "running" but has lost all its edge (HA)
    # connections. The upstream nixpkgs cloudflared module hardcodes ExecStart
    # and exposes no metrics option, but cloudflared honours TUNNEL_METRICS
    # identically to the `--metrics` flag, so we set it on the unit environment
    # (merges with the module's own `environment` block — no ExecStart override).
    # 127.0.0.1:9301 is loopback-only (scraped locally by Prometheus, see
    # modules/monitoring/services/self-scrape.nix); port registered in
    # docs/ports.txt. Yields cloudflared_tunnel_ha_connections and the rest of
    # the cloudflared_* metric family.
    environment.TUNNEL_METRICS = "127.0.0.1:9301";

    serviceConfig = {
      # Wait 10 seconds between restart attempts to allow network to stabilize
      RestartSec = 10;
    };
    unitConfig = {
      # Never permanently give up. cloudflared is the SOLE hard consumer of
      # network-online.target and serves a public tunnel, so it must always
      # recover. With the DNS-readiness ordering above it should not crash-loop at
      # boot; StartLimitIntervalSec=0 disables the burst ceiling so a transient
      # (resolver still warming, brief network blip) can never leave it
      # permanently dead — it keeps retrying every RestartSec=10s until DNS
      # answers. (Audit 2026-06-08: it had been exhausting StartLimitBurst=10
      # ~8s before Technitium became ready and staying down ~9.5min on cold boot.)
      StartLimitIntervalSec = 0;
    };
  };

  # Helper scripts for tunnel management
  environment.systemPackages = [
    (pkgs.writeScriptBin "cloudflare-tunnel-status" ''
      #!${pkgs.bash}/bin/bash
      echo "=== CloudFlare Tunnel Status ==="
      echo ""
      echo "Data Tunnel (data.newartisans.com → localhost:18080):"
      systemctl status cloudflared-tunnel-data --no-pager | head -3
      echo ""
      echo "Use 'cloudflare-tunnel-logs data' for detailed logs"
    '')

    (pkgs.writeScriptBin "cloudflare-tunnel-logs" ''
      #!${pkgs.bash}/bin/bash
      if [ "$1" = "data" ]; then
        echo "=== Data Tunnel Logs ==="
        sudo journalctl -u cloudflared-tunnel-data -n 50 --no-pager
      else
        echo "Usage: cloudflare-tunnel-logs <data>"
        exit 1
      fi
    '')

    (pkgs.writeScriptBin "cloudflare-tunnel-restart" ''
      #!${pkgs.bash}/bin/bash
      if [ "$1" = "data" ] || [ "$1" = "all" ]; then
        echo "Restarting Data tunnel..."
        sudo systemctl restart cloudflared-tunnel-data
        echo "✓ Data tunnel restarted"
      else
        echo "Usage: cloudflare-tunnel-restart <data|all>"
        exit 1
      fi
    '')
  ];
}
