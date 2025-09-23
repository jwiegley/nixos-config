{ config, lib, pkgs, ... }:

{
  # NixOS container for secure nginx serving internal HTTP
  containers.secure-nginx = {

    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = "10.233.1.1";
    localAddress = "10.233.1.2";

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

            # Default location - can be customized later
            locations."/" = {
              root = pkgs.writeTextDir "index.html" ''
                <!DOCTYPE html>
                <html>
                <head>
                    <title>Home - NewArtisans</title>
                    <style>
                        body {
                            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                            max-width: 800px;
                            margin: 50px auto;
                            padding: 20px;
                            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                            min-height: 100vh;
                        }
                        .container {
                            background: white;
                            padding: 40px;
                            border-radius: 10px;
                            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
                        }
                        h1 { color: #333; }
                        p { color: #666; line-height: 1.6; }
                        .status {
                            background: #f0f0f0;
                            padding: 15px;
                            border-radius: 5px;
                            margin: 20px 0;
                        }
                        .secure {
                            color: #22c55e;
                            font-weight: bold;
                        }
                    </style>
                </head>
                <body>
                    <div class="container">
                        <h1>Welcome to NewArtisans Home</h1>
                        <p>This is a secure containerized nginx instance serving your home services.</p>
                        <div class="status">
                            <p class="secure">🔒 Secured with Let's Encrypt ACME certificates</p>
                            <p>🐳 Running in an isolated NixOS container</p>
                            <p>🛡️ Enhanced security headers enabled</p>
                            <p>🔄 Automatic certificate renewal via host proxy</p>
                        </div>
                        <p>Server: home.newartisans.com</p>
                        <p>Container: secure-nginx</p>
                        <p>Internal Address: 10.233.1.2:8080</p>
                    </div>
                </body>
                </html>
              '';
              extraConfig = ''
                try_files /index.html =404;
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