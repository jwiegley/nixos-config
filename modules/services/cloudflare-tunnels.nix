# Always-running CloudFlare Tunnels for external service access
#
# Provides persistent CloudFlare Tunnel connections for:
# - data.newartisans.com → localhost:18080

{ config, pkgs, lib, ... }:

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
      # Data tunnel: data.newartisans.com → localhost:18080
      "data" = {
        credentialsFile = config.sops.secrets."cloudflared/data".path;
        default = "http_status:404";

        ingress = {
          "data.newartisans.com" = "http://localhost:18080";
        };
      };
    };
  };

  # Ensure tunnels start automatically and stay running
  # Added resilience for boot timing: delays between restarts and higher burst limit
  systemd.services."cloudflared-tunnel-data" = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nss-lookup.target" ];
    wants = [ "network-online.target" ];
    requires = [ "network-online.target" ];
    description = "CloudFlare Tunnel for data.newartisans.com";

    serviceConfig = {
      # Wait 10 seconds between restart attempts to allow network to stabilize
      RestartSec = 10;
      # Allow up to 10 restarts within a 5-minute window before giving up
      StartLimitIntervalSec = 300;
      StartLimitBurst = 10;
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
      echo "Use 'cloudflare-tunnel-logs <data>' for detailed logs"
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
      if [ "$1" = "data" ]; then
        echo "Restarting Data tunnel..."
        sudo systemctl restart cloudflared-tunnel-data
        echo "✓ Data tunnel restarted"
      elif [ "$1" = "all" ]; then
        echo "Restarting all tunnels..."
        sudo systemctl restart cloudflared-tunnel-data
        echo "✓ All tunnels restarted"
      else
        echo "Usage: cloudflare-tunnel-restart <data|all>"
        exit 1
      fi
    '')
  ];
}
