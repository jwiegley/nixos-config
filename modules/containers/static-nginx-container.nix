{
  config,
  lib,
  pkgs,
  ...
}:

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;
in
{
  # Ensure directories exist on host
  systemd.tmpfiles.rules = [
    "d /var/www/home.newartisans.com 0755 root root -"
  ];

  # Bind mount ZFS dataset to host directory (container will access via bindMount)
  # Read-only since this is just a static file server
  fileSystems = bindTankPath {
    path = "/var/www/home.newartisans.com";
    device = "/tank/Public";
    isReadOnly = true;
  };

  # NixOS container for nginx static file server (HTTP-only, localhost access)
  containers.static-nginx = {

    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = "10.233.3.1";
    localAddress = "10.233.3.2";

    bindMounts = {
      # Bind mount the web directory (read-only for static serving)
      "/var/www/home.newartisans.com" = {
        hostPath = "/var/www/home.newartisans.com";
        isReadOnly = true;
      };
    };

    # Auto-start the container
    autoStart = true;

    # Container configuration
    config =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        # Basic system configuration
        system.stateVersion = "25.05";

        # Networking configuration
        networking = {
          firewall = {
            enable = true;
            # Allow HTTP
            allowedTCPPorts = [ 80 ];
          };
        };

        # Time zone (match host)
        time.timeZone = "America/Los_Angeles";

        # Force DNS to point to host (works around resolvconf issues in containers)
        environment.etc."resolv.conf".text = lib.mkForce ''
          nameserver 10.233.3.1
          options edns0
        '';

        # Nginx configuration
        services.nginx = {
          enable = true;

          # Recommended settings
          recommendedGzipSettings = true;
          recommendedOptimisation = true;
          recommendedProxySettings = true;

          virtualHosts."home.newartisans.com" = {
            default = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
            ];

            # Container identifier header
            extraConfig = ''
              add_header X-Served-By "static-nginx-container" always;
            '';

            # Serve static files from /var/www/home.newartisans.com
            root = "/var/www/home.newartisans.com";

            # Directory listing and other options
            locations."/" = {
              extraConfig = ''
                autoindex on;
                autoindex_exact_size off;
                autoindex_localtime on;
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
                allow 10.233.3.1;  # Allow host only
                deny all;
              '';
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

        systemd.services = {
          nginx = {
            after = [ "var-www-home.newartisans.com.mount" ];
          };
        };
      };
  };

  # Systemd socket unit for localhost-only port forwarding to container
  systemd.sockets = {
    "static-nginx-http" = {
      description = "Static Nginx HTTP Socket (localhost only)";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:18080" ];
      socketConfig = {
        Accept = false;
      };
    };
  };

  # Systemd service to proxy connections to the container
  systemd.services = {
    "static-nginx-http" = {
      description = "Proxy HTTP to static-nginx container";
      requires = [
        "container@static-nginx.service"
        "static-nginx-http.socket"
      ];
      after = [
        "container@static-nginx.service"
        "static-nginx-http.socket"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.233.3.2:80";
        PrivateTmp = true;
        PrivateNetwork = false;
      };
    };
  };
}
