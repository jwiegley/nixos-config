{ config, lib, pkgs, ... }:

{
  # Cloudflare Tunnel for Convention Speaker List
  #
  # This module configures cloudflared to expose the convention-speaker-list
  # container to the internet via Cloudflare Tunnel, providing:
  # - SSL/TLS termination at Cloudflare edge
  # - DDoS protection
  # - Global CDN
  # - No need to expose ports directly to the internet
  #
  # Setup steps:
  # 1. Install cloudflared locally and authenticate
  # 2. Create a tunnel: cloudflared tunnel create convention-speaker-list
  # 3. Get the tunnel credentials JSON
  # 4. Add credentials to SOPS secrets
  # 5. Configure DNS CNAME to point to the tunnel
  # 6. Enable this module

  # SOPS secret for tunnel credentials
  # The credentials file should contain the JSON from 'cloudflared tunnel create'
  sops.secrets."cloudflared/convention" = {
    mode = "0400";
    owner = "cloudflared";
    group = "cloudflared";
    restartUnits = [ "cloudflared-tunnel-convention-speaker-list.service" ];
  };

  # Create cloudflared user if it doesn't exist
  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    description = "Cloudflare Tunnel daemon user";
  };
  users.groups.cloudflared = {};

  # Cloudflare Tunnel service
  systemd.services."cloudflared-tunnel-convention-speaker-list" = {
    description = "Cloudflare Tunnel for Convention Speaker List";
    after = [
      "network-online.target"
      "convention-speaker-list-http.service"
    ];
    wants = [
      "network-online.target"
      "convention-speaker-list-http.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "cloudflared";
      Group = "cloudflared";

      # Run cloudflared tunnel
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --config /run/secrets/cloudflared-convention-config.yaml run";

      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;

      # Restart policy
      Restart = "always";
      RestartSec = "10s";
    };

    # Unit configuration for restart rate limiting
    unitConfig = {
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };
  };

  # Generate cloudflared configuration file
  # This needs to be created from SOPS secrets
  systemd.services."cloudflared-config-setup" = {
    description = "Setup Cloudflare Tunnel configuration";
    wantedBy = [ "multi-user.target" ];
    before = [ "cloudflared-tunnel-convention-speaker-list.service" ];
    after = [ "sops-nix.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Create cloudflared config directory
      mkdir -p /run/secrets/cloudflared

      # Extract tunnel ID from credentials JSON
      TUNNEL_ID=$(${pkgs.jq}/bin/jq -r '.TunnelID' /run/secrets/cloudflared/convention)

      # Generate configuration file
      cat > /run/secrets/cloudflared-convention-config.yaml <<EOF
      # Cloudflare Tunnel Configuration for Convention Speaker List
      tunnel: $TUNNEL_ID
      credentials-file: /run/secrets/cloudflared/convention

      ingress:
        # Route convention.newartisans.com to the local service
        - hostname: convention.newartisans.com
          service: http://127.0.0.1:9095
          originRequest:
            # Enable WebSocket support for Socket.io
            noTLSVerify: false
            connectTimeout: 30s
            keepAliveTimeout: 90s
            keepAliveConnections: 100

        # Catch-all rule (required by cloudflared)
        - service: http_status:404
      EOF

      chmod 600 /run/secrets/cloudflared-convention-config.yaml
      chown cloudflared:cloudflared /run/secrets/cloudflared-convention-config.yaml
    '';
  };

  # Documentation comment for reference
  # To set up the tunnel:
  #
  # 1. Install cloudflared locally:
  #    nix-shell -p cloudflared
  #
  # 2. Authenticate with Cloudflare:
  #    cloudflared tunnel login
  #
  # 3. Create the tunnel:
  #    cloudflared tunnel create convention-speaker-list
  #    # This outputs a credentials JSON file
  #
  # 4. Add credentials to SOPS:
  #    sops /etc/nixos/secrets.yaml
  #    # Add the entire JSON content under cloudflare/convention-tunnel-credentials
  #
  # 5. Configure DNS in Cloudflare dashboard:
  #    - Type: CNAME
  #    - Name: convention (or your subdomain)
  #    - Content: <tunnel-id>.cfargotunnel.com
  #    - Proxy status: Proxied (orange cloud)
  #
  # 6. Update the tunnel ID in cloudflared-config-setup script above
  #
  # 7. Rebuild NixOS:
  #    sudo nixos-rebuild switch --flake '.#vulcan'
  #
  # 8. Check tunnel status:
  #    systemctl status cloudflared-tunnel-convention-speaker-list.service
  #    journalctl -u cloudflared-tunnel-convention-speaker-list.service -f
}
