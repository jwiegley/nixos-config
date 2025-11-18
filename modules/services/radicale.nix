{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Script to initialize Git repository for Radicale collections versioning
  # This script is idempotent and safe to run multiple times
  initGitRepo = pkgs.writeShellScript "radicale-init-git" ''
        set -euo pipefail

        COLLECTIONS_DIR="/var/lib/radicale/collections"

        # Create collections directory if it doesn't exist
        mkdir -p "$COLLECTIONS_DIR"
        cd "$COLLECTIONS_DIR"

        # Check if Git repository already exists
        if [ ! -d .git ]; then
          echo "Initializing Git repository for Radicale collections..."

          # Initialize Git repository
          ${pkgs.git}/bin/git init

          # Configure Git user identity
          ${pkgs.git}/bin/git config user.name "radicale"
          ${pkgs.git}/bin/git config user.email "radicale@vulcan.lan"

          # Create .gitignore for Radicale temporary files
          cat > .gitignore <<'EOF'
    .Radicale.cache
    .Radicale.lock
    .Radicale.tmp-*
    EOF

          # Add .gitignore to repository
          ${pkgs.git}/bin/git add .gitignore

          # Make initial commit if there are any files
          if [ -n "$(${pkgs.git}/bin/git status --porcelain)" ]; then
            ${pkgs.git}/bin/git add -A
            ${pkgs.git}/bin/git commit -m "Initial commit - Radicale collections versioning enabled"
            echo "Git repository initialized with initial commit"
          else
            ${pkgs.git}/bin/git commit -m "Initial commit - Git versioning enabled"
            echo "Git repository initialized"
          fi
        else
          echo "Git repository already exists for Radicale collections"
        fi
  '';
in
{
  # Radicale CalDAV/CardDAV server
  # A lightweight calendar and contacts server for personal use
  # Documentation: https://radicale.org/
  # Git versioning: https://radicale.org/v3.html#versioning-collections-with-git

  # SOPS secrets for Radicale authentication
  sops.secrets."radicale/users-htpasswd" = {
    owner = "radicale";
    group = "radicale";
    mode = "0400";
    restartUnits = [ "radicale.service" ];
  };

  services.radicale = {
    enable = true;

    settings = {
      # Server configuration
      server = {
        hosts = [
          "127.0.0.1:5232"
          "[::1]:5232"
        ];
        max_connections = 20;
        max_content_length = 100000000; # 100 MB max upload
        timeout = 30;
      };

      # Authentication - use htpasswd with bcrypt
      auth = {
        type = "htpasswd";
        htpasswd_filename = config.sops.secrets."radicale/users-htpasswd".path;
        htpasswd_encryption = "bcrypt";
        delay = 1; # Delay in seconds after failed auth attempt
      };

      # Storage configuration
      storage = {
        type = "multifilesystem";
        filesystem_folder = "/var/lib/radicale/collections";

        # Git hook for automatic versioning after each change
        # This commits changes with the authenticated user's name
        # The hook only commits if there are actual changes (avoids empty commits)
        hook = "git add -A && (git diff --cached --quiet || git commit -m \"Changes by \\\"%(user)s\\\"\")";
      };

      # Web interface configuration
      web = {
        type = "internal"; # Enable built-in web interface
      };

      # Logging configuration
      logging = {
        level = "info";
        mask_passwords = true;
      };

      # Rights management - authenticated users can access their own data
      rights = {
        type = "owner_only"; # Users can only access their own collections
      };

      # Encoding
      encoding = {
        request = "utf-8";
        stock = "utf-8";
      };

      # Headers for better caching and performance
      headers = {
        # Security headers
        "X-Frame-Options" = "SAMEORIGIN";
        "X-Content-Type-Options" = "nosniff";
        "X-XSS-Protection" = "1; mode=block";

        # Cache control for static resources
        "Cache-Control" = "private, max-age=3600";
      };
    };
  };

  # Ensure the radicale service has proper permissions
  systemd.services.radicale = {
    # Ensure SOPS secrets are available before starting
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];

    # Initialize Git repository before starting the service
    preStart = ''
      ${initGitRepo}
    '';

    serviceConfig = {
      # Add git to the service's PATH for the storage hook
      # Git is needed for automatic versioning of collections
      Environment = "PATH=${pkgs.git}/bin:${pkgs.coreutils}/bin";

      # Hardening options
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
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

      # Allow writing to state directory
      ReadWritePaths = [ "/var/lib/radicale" ];
    };
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."radicale.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/radicale.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/radicale.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:5232/";
      extraConfig = ''
        # Allow large uploads for VCF/ICS files (matches Radicale's 100MB limit)
        client_max_body_size 100M;

        # Headers for CalDAV/CardDAV
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Remote-User $remote_user;
        proxy_set_header Host $host;

        # Pass Authorization header
        proxy_pass_header Authorization;

        # Timeouts for long operations (large calendar sync)
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # Buffering
        proxy_buffering off;

        # HTTP/1.1 support
        proxy_http_version 1.1;
        proxy_set_header Connection "";
      '';
    };
  };

  # Open firewall for localhost access only (nginx handles external access)
  # Radicale listens on 127.0.0.1:5232
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 5232 ];
}
