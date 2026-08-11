{
  config,
  pkgs,
  ...
}:

let
  nodeRedAdminSource = pkgs.writeText "node-red-admin.py" (
    builtins.readFile ../../scripts/node-red-admin/node_red_admin.py
  );
  nodeRedAdminBackend = pkgs.writeTextFile {
    name = "node-red-admin-backend";
    destination = "/bin/node-red-admin-backend";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash -p
      exec ${pkgs.coreutils}/bin/env -i LC_ALL=C \
        ${pkgs.python3}/bin/python3 -I -B ${nodeRedAdminSource} "$@"
    '';
  };
  nodeRedAdmin = pkgs.writeTextFile {
    name = "node-red-admin";
    destination = "/bin/node-red-admin";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash -p
      exec /run/wrappers/bin/sudo -n -u node-red-admin -g node-red-admin -- ${nodeRedAdminBackend}/bin/node-red-admin-backend "$@"
    '';
    passthru = {
      inherit nodeRedAdminBackend nodeRedAdminSource;
    };
  };
in
{
  # This is a narrow non-disclosure boundary for a trusted administrator and
  # authorized flow author: callers can list tabs, read one complete (and
  # therefore sensitive) flow, or replace that flow without learning the
  # service credential. It is not an adversarial sandbox; johnw also retains
  # broader passwordless wheel authority on this host.
  users.groups.node-red-admin = { };
  users.users.node-red-admin = {
    isSystemUser = true;
    group = "node-red-admin";
    description = "Node-RED administrative helper";
  };

  environment.systemPackages = [ nodeRedAdmin ];

  security.sudo.extraRules = [
    {
      users = [ "johnw" ];
      runAs = "node-red-admin:node-red-admin";
      commands = [
        {
          command = "${nodeRedAdminBackend}/bin/node-red-admin-backend";
          options = [
            "NOPASSWD"
            "NOSETENV"
            "NOLOG_INPUT"
            "NOLOG_OUTPUT"
          ];
        }
      ];
    }
  ];

  # Keep 844 privileged: the nginx upstream must not become impersonable by an
  # unprivileged local process if Node-RED is stopped.
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 1024;

  # SOPS secrets for Node-RED

  # Home Assistant long-lived access token
  # This token allows Node-RED to authenticate with Home Assistant's WebSocket API
  # Generate in HA: Settings > Profile > Long-Lived Access Tokens
  sops.secrets."home-assistant/node-red-token" = {
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # Node-RED admin authentication secrets
  # Admin username for Node-RED editor login
  sops.secrets."node-red/admin-username" = {
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # Bcrypt password hash for admin user
  # Generate with: /etc/nixos/scripts/node-red-hash-password.sh
  sops.secrets."node-red/admin-password-hash" = {
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # API bearer tokens, JSON array of {token, description}.
  # Consumed by settings.js for both:
  #   - httpNodeMiddleware (HTTP-In endpoints + /metrics)
  #   - adminAuth.tokens (Admin API: GET/PUT /flow, /flows, etc.)
  # Any token in this list grants full Admin API permissions, so each entry
  # should map to a single named consumer. Rotate by replacing the entry.
  sops.secrets."node-red/api-tokens" = {
    owner = "node-red";
    group = "node-red";
    mode = "0400";
    restartUnits = [ "node-red.service" ];
  };

  # Admin API bearer token duplicated only for the node-red-admin helper.
  # IMPORTANT: this value MUST exactly equal the .token field of one entry in
  # node-red/api-tokens (conventionally the entry described "johnw shell /
  # Claude"). settings.js does not read this file — it only reads api-tokens
  # — so a mismatch makes helper requests fail with HTTP 401. When rotating,
  # update BOTH SOPS values in
  # one `sops secrets/secrets.yaml` session (the encrypted store lives in the
  # separate `secrets` flake-input repo; there is no /etc/nixos/secrets.yaml).
  # The dedicated identity and exact 0400 mode keep the runtime value out of
  # caller argv, environment, logs, errors, helper-created files, and output.
  sops.secrets."node-red-admin-token" = {
    owner = "node-red-admin";
    group = "node-red-admin";
    mode = "0400";
  };

  # Node-RED service configuration
  services.node-red = {
    enable = true;

    # Allow installing additional nodes via Palette Manager UI
    # This enables npm and gcc at runtime for installing node modules
    withNpmAndGcc = true;

    # A privileged loopback port prevents local upstream impersonation while
    # nginx owns the public TLS boundary.
    port = 844;

    # Use default node-red package from nixpkgs
    # package = pkgs.nodePackages.node-red;

    # Deploy custom settings.js with authentication configuration
    # This file loads secrets from /run/secrets/ for secure authentication
    configFile = pkgs.writeText "node-red-settings.js" (
      builtins.readFile ../../config/node-red-settings.js
    );
  };

  # Ensure Node-RED starts after secrets are available
  # Add bash to the service PATH so npm postinstall scripts that spawn /bin/sh
  # (e.g. core-js's "Thank you" message script, a transitive dep of
  # @flowfuse/node-red-dashboard) don't ENOENT and fail the whole install.
  systemd.services.node-red.path = [ pkgs.bash ];

  systemd.services.node-red = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];

    # Make Home Assistant token available to Node-RED
    # Users can access this via process.env or file read
    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      EnvironmentFile = [
        (pkgs.writeText "node-red-env" ''
          HA_TOKEN_FILE=${config.sops.secrets."home-assistant/node-red-token".path}
        '')
      ];
    };
  };

  # Node-RED nginx upstream with retry logic
  # Prevents 502 errors during service restarts
  services.nginx.upstreams."node-red" = {
    servers = {
      "127.0.0.1:${toString config.services.node-red.port}" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 16;
      keepalive_timeout 60s;
    '';
  };

  # Nginx reverse proxy for Node-RED
  # Provides HTTPS access at https://nodered.vulcan.lan
  services.nginx.virtualHosts."nodered.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/nodered.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/nodered.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://node-red/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Increase timeouts for websocket connections
        proxy_connect_timeout 1h;
        proxy_send_timeout 1h;
        proxy_read_timeout 1h;

        # Buffer settings for streaming
        proxy_buffering off;
      '';
    };
  };

  # Node-RED is accessed via nginx HTTPS proxy only (nodered.vulcan.lan)
  # No direct HTTP port exposed on the LAN interface
}
