{ config, lib, pkgs, ... }:

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;
in
{
  # Create password files for copyparty from SOPS secrets
  systemd.services.copyparty-password-setup = {
    description = "Create copyparty password files for container";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@secure-nginx.service" ];
    after = [ "sops-nix.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      mkdir -p /var/lib/copyparty-passwords
      chmod 755 /var/lib/copyparty-passwords

      # Copy passwords from SOPS to password files
      cat ${config.sops.secrets."copyparty/admin-password".path} > /var/lib/copyparty-passwords/admin
      cat ${config.sops.secrets."copyparty/johnw-password".path} > /var/lib/copyparty-passwords/johnw
      cat ${config.sops.secrets."copyparty/friend-password".path} > /var/lib/copyparty-passwords/friend

      chmod 644 /var/lib/copyparty-passwords/admin
      chmod 644 /var/lib/copyparty-passwords/johnw
      chmod 644 /var/lib/copyparty-passwords/friend
    '';
  };

  # SOPS secrets for creating password files
  sops.secrets."copyparty/admin-password" = {
    restartUnits = [ "copyparty-password-setup.service" ];
  };
  sops.secrets."copyparty/johnw-password" = {
    restartUnits = [ "copyparty-password-setup.service" ];
  };
  sops.secrets."copyparty/friend-password" = {
    restartUnits = [ "copyparty-password-setup.service" ];
  };

  # Ensure directories exist on host
  systemd.tmpfiles.rules = [
    "d /var/lib/acme-container 0755 root root -"
    "d /var/www/home.newartisans.com 0755 root root -"
    "d /var/lib/copyparty-container 0755 root root -"
    "d /var/lib/copyparty-container/.hist 0755 root root -"
    "d /var/lib/copyparty-container/.th 0755 root root -"
    "d /var/lib/copyparty-passwords 0755 root root -"
  ];

  # Bind mount ZFS dataset to host directory (container will access via bindMount)
  # Changed from read-only to read-write to allow copyparty to manage uploads
  fileSystems = bindTankPath {
    path = "/var/www/home.newartisans.com";
    device = "/tank/Public";
    isReadOnly = false;
  };

  # Enable NAT for container to access internet
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];  # All container interfaces
    externalInterface = "end0";
  };

  # Open firewall ports on host for container access
  networking.firewall.allowedTCPPorts = [ 18080 18443 18873 18874 13923 ];

  # NixOS container for secure nginx with direct SSL/ACME
  containers.secure-nginx = {

    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = "10.233.1.1";
    localAddress = "10.233.1.2";

    # Forward ports from host to container
    forwardPorts = [
      {
        protocol = "tcp";
        hostPort = 18080;
        containerPort = 80;
      }
      {
        protocol = "tcp";
        hostPort = 18443;
        containerPort = 443;
      }
      {
        protocol = "tcp";
        hostPort = 18873;
        containerPort = 873;
      }
      {
        protocol = "tcp";
        hostPort = 18874;
        containerPort = 874;
      }
      {
        protocol = "tcp";
        hostPort = 13923;
        containerPort = 3923;
      }
    ];

    bindMounts = {
      # Bind mount the web directory (read-write for copyparty uploads)
      "/var/www/home.newartisans.com" = {
        hostPath = "/var/www/home.newartisans.com";
        isReadOnly = false;
      };
      # Bind mount for ACME certificate storage
      "/var/lib/acme" = {
        hostPath = "/var/lib/acme-container";
        isReadOnly = false;
      };
      # Bind mount for copyparty state (history, thumbnails)
      "/var/lib/copyparty" = {
        hostPath = "/var/lib/copyparty-container";
        isReadOnly = false;
      };
      # Bind mount password files for copyparty authentication
      "/var/lib/copyparty-passwords" = {
        hostPath = "/var/lib/copyparty-passwords";
        isReadOnly = true;
      };
    };

    # Auto-start the container
    autoStart = true;

    # Container configuration
    config = { config, pkgs, lib, ... }: {
      # Import copyparty module
      imports = [
        ../../modules/services/copyparty.nix
      ];

      # Apply host overlays to container nixpkgs
      nixpkgs.overlays = [
        (import ../../overlays)
      ];

      # Basic system configuration
      system.stateVersion = "25.05";

      # Networking configuration
      networking = {
        firewall = {
          enable = true;
          # Allow HTTP for ACME challenges, HTTPS for secure traffic, rsync
          # daemon, rsync-ssl proxy, and copyparty metrics
          allowedTCPPorts = [ 80 443 873 874 3923 ];
        };
      };

      # Time zone (match host)
      time.timeZone = "America/Los_Angeles";

      # Force DNS to point to host (works around resolvconf issues in
      # containers)
      environment.etc."resolv.conf".text = lib.mkForce ''
        nameserver 10.233.1.1
        options edns0
      '';

      # ACME configuration for Let's Encrypt certificates
      security.acme = {
        acceptTerms = true;
        defaults = {
          email = "johnw@newartisans.com";
          # Use production Let's Encrypt server for trusted certificates
          server = "https://acme-v02.api.letsencrypt.org/directory";
        };
        # Individual certificate configuration
        certs."home.newartisans.com" = {
          # Don't block nginx startup on certificate fetch
          postRun = "systemctl reload nginx.service || true";
        };
      };

      # Nginx configuration with TLS/ACME
      services.nginx = {
        enable = true;

        # Recommended settings
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        virtualHosts."home.newartisans.com" = {
          default = true;
          # Use addSSL instead of forceSSL to allow ACME challenges on HTTP
          addSSL = true;
          enableACME = true;

          # Listen on standard ports (443 is forwarded from host:18443)
          listen = [
            { addr = "0.0.0.0"; port = 443; ssl = true; }
            { addr = "0.0.0.0"; port = 80; }
          ];

          # Security headers for internet-facing service
          extraConfig = ''
            # Strict Transport Security
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

            # Additional security headers
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-XSS-Protection "1; mode=block" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;

            # CSP Header
            add_header Content-Security-Policy "default-src 'self' https:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';" always;

            # Indicate this is served from the secure container
            add_header X-Served-By "secure-nginx-container" always;
          '';

          # Reverse proxy to copyparty (replacing static file serving)
          locations."/" = {
            proxyPass = "http://127.0.0.1:3923/";
            extraConfig = ''
              # WebSocket support for real-time updates
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";

              # Large file upload support (up to 10GB)
              client_max_body_size 10G;
              proxy_request_buffering off;

              # Proxy headers
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Timeouts for large uploads
              proxy_connect_timeout 300;
              proxy_send_timeout 300;
              proxy_read_timeout 300;
              send_timeout 300;
            '';
          };

          # Health check endpoint
          locations."/health" = {
            extraConfig = ''
              access_log off;
              return 200 "healthy\n";
              default_type text/plain;
            '';
          };

          # Status endpoint for monitoring
          locations."/status" = {
            extraConfig = ''
              stub_status on;
              access_log off;
              allow 10.233.1.1;  # Allow host only
              deny all;
            '';
          };
        };

        # Stream configuration for rsync-ssl proxy
        streamConfig = ''
          # rsync-ssl proxy: accepts SSL connections and forwards to local
          # rsync daemon
          server {
            listen 874 ssl;

            ssl_certificate /var/lib/acme/home.newartisans.com/cert.pem;
            ssl_certificate_key /var/lib/acme/home.newartisans.com/key.pem;
            ssl_trusted_certificate /var/lib/acme/home.newartisans.com/chain.pem;

            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_ciphers HIGH:!aNULL:!MD5;
            ssl_prefer_server_ciphers on;

            proxy_pass 127.0.0.1:873;
            proxy_connect_timeout 10s;
            proxy_timeout 30m;
          }
        '';
      };

      # Ensure nginx user exists
      users.users.nginx = {
        group = "nginx";
        isSystemUser = true;
        uid = 60;
      };
      users.groups.nginx.gid = 60;

      # Rsync daemon configuration for serving public files
      services.rsyncd = {
        enable = true;
        socketActivated = true;
        settings = {
          globalSection = {
            uid = "nginx";
            gid = "nginx";
            "use chroot" = true;
            "max connections" = 10;
            "log file" = "/var/log/rsyncd.log";
            "transfer logging" = true;
          };
          sections = {
            pub = {
              path = "/var/www/home.newartisans.com/pub";
              comment = "Public files for home.newartisans.com";
              "read only" = true;
              list = true;
            };
          };
        };
      };

      # Enable copyparty service with password files
      services.copyparty = {
        enable = true;
        port = 3923;
        domain = "home.newartisans.com";
        shareDir = "/var/www/home.newartisans.com";

        # Use password files instead of SOPS
        passwordFiles = {
          admin = "/var/lib/copyparty-passwords/admin";
          johnw = "/var/lib/copyparty-passwords/johnw";
          friend = "/var/lib/copyparty-passwords/friend";
        };

        extraConfig = ''
          # Container serves from bind-mounted directory
        '';
      };

      systemd.services = {
        nginx = {
          after = [ "var-www-home.newartisans.com.mount" "copyparty.service" ];
          wants = [ "copyparty.service" ];
        };
        rsyncd = {
          after = [ "var-www-home.newartisans.com.mount" ];
        };
      };

      # Make ACME non-blocking for container startup
      systemd.services."acme-order-renew-home.newartisans.com" = {
        after = [ "nginx.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        # Don't fail if ACME fails
        unitConfig = {
          FailureAction = "none";
        };
        serviceConfig = {
          # Shorter timeout to avoid blocking container startup
          TimeoutStartSec = "30s";
        };
      };
    };
  };
}
