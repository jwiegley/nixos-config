{ config, lib, pkgs, ... }:

{
  # Ensure ACME certificate directory exists on host
  # Also ensure /var/www/home.newartisans.com exists even when tank isn't mounted
  # This allows the container to start (though it won't have content without tank)
  systemd.tmpfiles.rules = [
    "d /var/lib/acme-container 0755 root root -"
    "d /var/www/home.newartisans.com 0755 root root -"
  ];

  # Enable NAT for container to access internet
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];  # All container interfaces
    externalInterface = "enp4s0";  # Replace with your internet-facing interface if different
  };

  # Open firewall ports on host for container access
  networking.firewall.allowedTCPPorts = [ 18080 18443 18873 18874 ];

  # Ensure container waits for ZFS mount of /var/www/home.newartisans.com (tank/Public)
  # Note: We use 'after' but not 'requires' to allow activation without tank
  # The container will fail to start if the mount isn't available, but won't block nixos-rebuild
  systemd.services."container@secure-nginx" = {
    after = [ "zfs-import-tank.service" "zfs.target" ];
  };

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
    ];

    # Bind mount the web directory
    bindMounts = {
      "/var/www/home.newartisans.com" = {
        hostPath = "/var/www/home.newartisans.com";
        isReadOnly = true;
      };
      # Bind mount for ACME certificate storage
      "/var/lib/acme" = {
        hostPath = "/var/lib/acme-container";
        isReadOnly = false;
      };
    };

    # Auto-start the container
    autoStart = true;

    # Container configuration
    config = { config, pkgs, lib, ... }: {
      # Basic system configuration
      system.stateVersion = "25.05";

      # Networking configuration
      networking = {
        firewall = {
          enable = true;
          # Allow HTTP for ACME challenges, HTTPS for secure traffic, rsync daemon, and rsync-ssl proxy
          allowedTCPPorts = [ 80 443 873 874 ];
        };
      };

      # Time zone (match host)
      time.timeZone = "America/Los_Angeles";

      # Force DNS to point to host (works around resolvconf issues in containers)
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

        virtualHosts = {
          # Main site - HTTPS with ACME
          "home.newartisans.com" = {
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

            # Root location - serve files from bind mount
            root = "/var/www/home.newartisans.com";

            locations."/" = {
              extraConfig = ''
                # Disable directory listing
                autoindex off;

                # Try to serve file, then directory index, then 404
                try_files $uri $uri/ =404;
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
        };

        # Stream configuration for rsync-ssl proxy
        streamConfig = ''
          # rsync-ssl proxy: accepts SSL connections and forwards to local rsync daemon
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