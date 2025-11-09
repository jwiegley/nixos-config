# Cloudflare Tunnel for n8n webhook exposure
# Manually controlled - does NOT auto-start
# Usage: sudo systemctl start cloudflared-tunnel-n8n-webhook

{ config, pkgs, lib, ... }:

{
  # Create cloudflared user and group for SOPS secret ownership
  users.users.cloudflared = {
    group = "cloudflared";
    isSystemUser = true;
  };

  users.groups.cloudflared = { };

  # SOPS secret for Cloudflare Tunnel credentials
  sops.secrets."cloudflared/n8n" = {
    owner = "cloudflared";
    group = "cloudflared";
    mode = "0400";
    restartUnits = [ "cloudflared-tunnel-n8n-webhook.service" ];
  };

  # Nginx virtual host for Cloudflare Tunnel endpoint
  services.nginx.virtualHosts."n8n-webhook.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/n8n-webhook.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/n8n-webhook.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://n8n/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Increase timeouts for long-running workflows
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;

        # Buffer settings for large payloads
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 100M;
      '';
    };
  };

  # Cloudflared tunnel service (manually controlled)
  services.cloudflared = {
    enable = true;
    tunnels = {
      "n8n-webhook" = {
        credentialsFile = config.sops.secrets."cloudflared/n8n".path;
        default = "http_status:404";

        ingress = {
          "n8n.newartisans.com" = "https://n8n-webhook.vulcan.lan";
        };
      };
    };
  };

  # Override cloudflared service to prevent auto-start
  systemd.services."cloudflared-tunnel-n8n-webhook" = {
    wantedBy = lib.mkForce [];  # Manual start only
    after = [ "nginx.service" ];
    wants = [ "nginx.service" ];
  };

  # Helper scripts for easy management
  environment.systemPackages = [
    (pkgs.writeScriptBin "n8n-webhook-enable" ''
      #!${pkgs.bash}/bin/bash
      set -e
      echo "Starting n8n Cloudflare Tunnel..."
      sudo systemctl start cloudflared-tunnel-n8n-webhook
      echo "✓ Cloudflare Tunnel started"
      echo ""
      echo "Webhook tunnel is now active at: https://n8n.newartisans.com"
      echo ""
      echo "To check status: n8n-webhook-status"
      echo "To disable: n8n-webhook-disable"
    '')

    (pkgs.writeScriptBin "n8n-webhook-disable" ''
      #!${pkgs.bash}/bin/bash
      set -e
      echo "Stopping n8n Cloudflare Tunnel..."
      sudo systemctl stop cloudflared-tunnel-n8n-webhook
      echo "✓ Cloudflare Tunnel stopped"
      echo ""
      echo "Webhook tunnel is now disabled"
    '')

    (pkgs.writeScriptBin "n8n-webhook-status" ''
      #!${pkgs.bash}/bin/bash
      echo "=== Cloudflare Tunnel Status ==="
      systemctl status cloudflared-tunnel-n8n-webhook --no-pager | head -10
      echo ""
      echo "=== Tunnel Configuration ==="
      sudo journalctl -u cloudflared-tunnel-n8n-webhook -n 20 --no-pager | grep -i "ingress\|registered" | tail -5
    '')

    (pkgs.writeScriptBin "n8n-webhook-logs" ''
      #!${pkgs.bash}/bin/bash
      echo "=== Cloudflare Tunnel Logs ==="
      sudo journalctl -u cloudflared-tunnel-n8n-webhook -n 50 --no-pager
    '')

    (pkgs.writeScriptBin "n8n-webhook-test" ''
      #!${pkgs.bash}/bin/bash
      echo "Testing n8n webhook tunnel..."
      echo ""
      echo "1. Testing n8n-webhook endpoint (local):"
      curl -s -k https://n8n-webhook.vulcan.lan/ | grep -o '<title>[^<]*</title>' || echo "❌ Local endpoint not responding"
      echo ""
      echo "2. Testing public endpoint:"
      curl -s https://n8n.newartisans.com/ 2>&1 | grep -o '<title>[^<]*</title>' || echo "❌ Public endpoint not responding (DNS may not be configured yet)"
    '')
  ];
}
