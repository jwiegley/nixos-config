{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.copyparty;
  dataDir = "/var/lib/copyparty";
  shareDir = "/tank/Public";  # Main share directory

  # Script to generate config with passwords from secrets
  configGenerator = pkgs.writeShellScript "copyparty-config-generator" ''
    # Read passwords from SOPS secrets
    ADMIN_PASS=$(cat ${config.sops.secrets."copyparty/admin-password".path})
    JOHNW_PASS=$(cat ${config.sops.secrets."copyparty/johnw-password".path})

    # Generate configuration file
    cat > ${dataDir}/copyparty.conf <<EOF
    [global]
      # Listen on loopback only - nginx will handle external access
      i: 127.0.0.1
      # Port configuration
      p: ${toString cfg.port}
      # Enable Prometheus metrics
      stats
      # Enable media indexing and search
      e2dsa
      # Enable audio metadata
      e2ts
      # Enable zeroconf/mDNS
      z
      # Generate QR codes for mobile access
      qr
      # Theme
      theme: 3

    [accounts]
      admin: $ADMIN_PASS
      johnw: $JOHNW_PASS

    [/public]
      ${shareDir}
      accs:
        r: *
        rw: admin, johnw
        a: admin
      flags:
        # Enable deduplication
        nodupe
        # Enable media indexing
        e2d
        # Enable directory tags
        d2t

    ${cfg.extraConfig}
    EOF
  '';

  # Python environment with copyparty and optional dependencies
  copypartyEnv = pkgs.python3.withPackages (ps: with ps; [
    copyparty
    pillow  # For thumbnails
    mutagen  # For audio metadata
    jinja2  # Core dependency
  ]);

in {
  options.services.copyparty = {
    enable = mkEnableOption "copyparty file server";

    port = mkOption {
      type = types.port;
      default = 3923;
      description = "Port for copyparty to listen on (loopback only)";
    };

    accounts = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = { alice = "password123"; bob = "secret456"; };
      description = "User accounts for authentication. Format: username = password. Passwords can be plaintext or hashed.";
    };

    writeUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" "bob" ];
      description = "List of users who have write access to shares";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra configuration to append to copyparty.conf";
    };

    domain = mkOption {
      type = types.str;
      default = "copyparty.vulcan.lan";
      description = "Domain name for nginx virtual host";
    };
  };

  config = mkIf cfg.enable {
    # SOPS secrets for authentication
    sops.secrets."copyparty/admin-password" = {
      owner = "copyparty";
      group = "copyparty";
      mode = "0440";  # Allow group read for Prometheus
      restartUnits = [ "copyparty.service" "prometheus.service" ];
    };

    sops.secrets."copyparty/johnw-password" = {
      owner = "copyparty";
      group = "copyparty";
      mode = "0400";
      restartUnits = [ "copyparty.service" ];
    };

    # Create copyparty user and group
    users.users.copyparty = {
      isSystemUser = true;
      group = "copyparty";
      description = "Copyparty file server user";
      home = dataDir;
      createHome = true;
    };

    users.groups.copyparty = {
      members = [ "prometheus" ];  # Allow Prometheus to read secrets
    };

    # Ensure share directory exists and has correct permissions
    systemd.tmpfiles.rules = [
      "d ${shareDir} 0755 copyparty copyparty -"
      "d ${dataDir} 0755 copyparty copyparty -"
      "d ${dataDir}/.hist 0755 copyparty copyparty -"
      "d ${dataDir}/.th 0755 copyparty copyparty -"
    ];

    # Copyparty systemd service
    systemd.services.copyparty = {
      description = "Copyparty file server with media indexing";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # Generate config before starting
      preStart = ''
        ${configGenerator}
      '';

      serviceConfig = {
        Type = "notify";
        User = "copyparty";
        Group = "copyparty";
        WorkingDirectory = dataDir;

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ dataDir shareDir ];

        # Resource limits
        MemoryMax = "2G";
        TasksMax = 512;

        # Start copyparty with generated config file
        ExecStart = "${copypartyEnv}/bin/copyparty -c ${dataDir}/copyparty.conf --hist ${dataDir}/.hist";

        # Reload configuration on SIGUSR1
        ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";

        Restart = "always";
        RestartSec = 5;
      };
    };

    # Nginx reverse proxy
    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/${cfg.domain}.crt";
      sslCertificateKey = "/var/lib/nginx-certs/${cfg.domain}.key";

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.port}/";
        recommendedProxySettings = true;
        extraConfig = ''
          # WebSocket support for real-time updates
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";

          # Large file upload support
          client_max_body_size 10G;
          proxy_request_buffering off;
        '';
      };
    };

    # Allow loopback traffic
    networking.firewall.interfaces."lo".allowedTCPPorts = [ cfg.port ];

    # Prometheus metrics scraping with basic auth
    services.prometheus.scrapeConfigs = mkIf config.services.prometheus.enable [
      {
        job_name = "copyparty";
        static_configs = [{
          targets = [ "127.0.0.1:${toString cfg.port}" ];
          labels = {
            instance = "vulcan";
            service = "copyparty";
          };
        }];
        metrics_path = "/.cpr/metrics";
        scrape_interval = "30s";
        basic_auth = {
          username = "admin";
          password_file = config.sops.secrets."copyparty/admin-password".path;
        };
      }
    ];
  };
}
