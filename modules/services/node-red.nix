{ config, lib, pkgs, ... }:

{
  # SOPS secrets for Node-RED

  # Home Assistant long-lived access token
  # This token allows Node-RED to authenticate with Home Assistant's WebSocket API
  # Generate in HA: Settings > Profile > Long-Lived Access Tokens
  sops.secrets."home-assistant/node-red-token" = {
    sopsFile = ../../secrets.yaml;
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # Node-RED admin authentication secrets
  # Admin username for Node-RED editor login
  sops.secrets."node-red/admin-username" = {
    sopsFile = ../../secrets.yaml;
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # Bcrypt password hash for admin user
  # Generate with: /etc/nixos/scripts/node-red-hash-password.sh
  sops.secrets."node-red/admin-password-hash" = {
    sopsFile = ../../secrets.yaml;
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # API bearer tokens for HTTP node authentication (JSON array)
  # Format: [{"token": "abc123", "description": "Service name"}, ...]
  sops.secrets."node-red/api-tokens" = {
    sopsFile = ../../secrets.yaml;
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # Node-RED service configuration
  services.node-red = {
    enable = true;

    # Allow installing additional nodes via Palette Manager UI
    # This enables npm and gcc at runtime for installing node modules
    withNpmAndGcc = true;

    # Use default port 1880 (Node-RED standard)
    port = 1880;

    # Use default node-red package from nixpkgs
    # package = pkgs.nodePackages.node-red;

    # Deploy custom settings.js with authentication configuration
    # This file loads secrets from /run/secrets/ for secure authentication
    configFile = pkgs.writeText "node-red-settings.js" (builtins.readFile ../../config/node-red-settings.js);
  };

  # Ensure Node-RED starts after secrets are available
  systemd.services.node-red = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];

    # Make Home Assistant token available to Node-RED
    # Users can access this via process.env or file read
    serviceConfig = {
      EnvironmentFile = [
        (pkgs.writeText "node-red-env" ''
          HA_TOKEN_FILE=${config.sops.secrets."home-assistant/node-red-token".path}
        '')
      ];
    };
  };

  # Nginx reverse proxy for Node-RED
  # Provides HTTPS access at https://nodered.vulcan.lan
  services.nginx.virtualHosts."nodered.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/nodered.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/nodered.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:1880/";
      proxyWebsockets = true;
      extraConfig = ''
        # Increase timeouts for websocket connections
        proxy_connect_timeout 1h;
        proxy_send_timeout 1h;
        proxy_read_timeout 1h;

        # Buffer settings for streaming
        proxy_buffering off;
      '';
    };
  };

  # Open firewall for local network access
  # Allow direct access to Node-RED on port 1880 (HTTP)
  # HTTPS access via nginx on port 443 (already open globally in web.nix)
  networking.firewall.interfaces."enp4s0".allowedTCPPorts = [
    1880 # Node-RED web interface
  ];
}
