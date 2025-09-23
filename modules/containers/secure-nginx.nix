{ config, lib, pkgs, ... }:

{
  # NixOS container for secure nginx serving internal HTTP
  containers.secure-nginx = {

    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = "10.233.1.1";
    localAddress = "10.233.1.2";

    # Bind mount the web directory
    bindMounts = {
      "/var/www/home.newartisans.com" = {
        hostPath = "/var/www/home.newartisans.com";
        isReadOnly = true;
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
          # Only allow HTTP internally - TLS handled by host
          allowedTCPPorts = [ 8080 ];
        };
        # Use host's DNS
        nameservers = [ "1.1.1.1" "8.8.8.8" ];
      };

      # Time zone (match host)
      time.timeZone = "America/Los_Angeles";

      # Nginx configuration (HTTP only, no TLS)
      services.nginx = {
        enable = true;

        # Recommended settings
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;

        # Security headers (will be passed through host proxy)
        appendHttpConfig = ''
          # Security headers
          more_set_headers "X-Frame-Options: SAMEORIGIN";
          more_set_headers "X-Content-Type-Options: nosniff";
          more_set_headers "X-XSS-Protection: 1; mode=block";
          more_set_headers "Referrer-Policy: strict-origin-when-cross-origin";
          more_set_headers "X-Container: secure-nginx";
        '';

        virtualHosts = {
          # Main site - HTTP only, served internally
          "default" = {
            default = true;
            # Listen only on internal HTTP port
            listen = [
              { addr = "0.0.0.0"; port = 8080; }
            ];

            # Add security headers specific to this container
            extraConfig = ''
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

                # Security headers for downloads
                add_header X-Content-Type-Options "nosniff" always;
                add_header X-Download-Options "noopen" always;
              '';
            };

            # Health check endpoint
            locations."/health" = {
              extraConfig = ''
                access_log off;
                return 200 "healthy\n";
                add_header Content-Type text/plain;
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
      };

      # Ensure nginx user exists
      users.users.nginx = {
        group = "nginx";
        isSystemUser = true;
        uid = 60;
      };
      users.groups.nginx.gid = 60;

      # Enable certificate renewal timer
      systemd.timers."acme-renewal" = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    };
  };
}