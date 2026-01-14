{
  inputs,
  system,
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
      ${lib.optionalString (config.sops.secrets ? "copyparty/nasimw-password") ''
        cat ${config.sops.secrets."copyparty/nasimw-password".path} > /var/lib/copyparty-passwords/nasimw
      ''}

      chmod 644 /var/lib/copyparty-passwords/admin
      chmod 644 /var/lib/copyparty-passwords/johnw
      chmod 644 /var/lib/copyparty-passwords/friend
      ${lib.optionalString (config.sops.secrets ? "copyparty/nasimw-password") ''
        chmod 644 /var/lib/copyparty-passwords/nasimw
      ''}
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
  sops.secrets."copyparty/nasimw-password" = {
    restartUnits = [ "copyparty-password-setup.service" ];
  };

  # Ensure directories exist on host
  systemd.tmpfiles.rules = [
    "d /var/www/home.newartisans.com 0755 root root -"
    "d /var/lib/copyparty-container 0755 root root -"
    "d /var/lib/copyparty-container/.hist 0755 root root -"
    "d /var/lib/copyparty-container/.th 0755 root root -"
    "d /var/lib/copyparty-passwords 0755 root root -"
    # Personal directories for copyparty shares
    "d /tank/Public/johnw 0755 root root -"
    "d /tank/Public/nasimw 0755 root root -"
  ];

  # Bind mount ZFS dataset to host directory (container will access via bindMount)
  # Changed from read-only to read-write to allow copyparty to manage uploads
  fileSystems = bindTankPath {
    path = "/var/www/home.newartisans.com";
    device = "/tank/Public";
    isReadOnly = false;
  };

  # NixOS container for nginx with copyparty (HTTP-only, localhost access)
  containers.secure-nginx = {

    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = "10.233.1.1";
    localAddress = "10.233.1.2";

    # Port forwarding removed - using systemd socket units instead for localhost-only binding

    bindMounts = {
      # Bind mount the web directory (read-write for copyparty uploads)
      "/var/www/home.newartisans.com" = {
        hostPath = "/var/www/home.newartisans.com";
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
    config =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        # Import copyparty module
        imports = [
          ../../modules/services/copyparty.nix
        ];

        # Apply host overlays to container nixpkgs
        nixpkgs.overlays = [
          (import ../../overlays inputs system)
        ];

        # Basic system configuration
        system.stateVersion = "25.05";

        # Networking configuration
        networking = {
          firewall = {
            enable = true;
            # Allow HTTP, copyparty metrics
            allowedTCPPorts = [
              80
              3923
            ];
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

        # Nginx configuration
        services.nginx = {
          enable = true;

          # Recommended settings
          recommendedGzipSettings = true;
          recommendedOptimisation = true;
          recommendedProxySettings = true;

          virtualHosts."data.newartisans.com" = {
            default = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
            ];

            # Container identifier header
            extraConfig = ''
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
                proxy_set_header X-Forwarded-Proto https;

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
        };

        # Ensure nginx user exists
        users.users.nginx = {
          group = "nginx";
          isSystemUser = true;
          uid = 60;
        };
        users.groups.nginx.gid = 60;

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
            nasimw = "/var/lib/copyparty-passwords/nasimw";
          };
        };

        systemd.services = {
          nginx = {
            after = [
              "var-www-home.newartisans.com.mount"
              "copyparty.service"
            ];
            wants = [ "copyparty.service" ];

            # Systemd hardening
            serviceConfig = {
              # Filesystem hardening
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              ReadWritePaths = [ "/var/log/nginx" ];

              # Privilege restrictions
              NoNewPrivileges = true;
              PrivateDevices = true;

              # Kernel hardening
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;

              # Capabilities
              CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
              AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

              # Syscall filtering
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
                "~@resources"
              ];
              SystemCallArchitectures = "native";

              # Network restrictions
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
              ];

              # Misc hardening
              LockPersonality = true;
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              RemoveIPC = true;
            };
          };
        };
      };
  };

  # Systemd socket units for localhost-only port forwarding to container
  # These bind only to 127.0.0.1 and forward to the container's internal IP
  systemd.sockets = {
    "secure-nginx-http" = {
      description = "Secure Nginx HTTP Socket (localhost only)";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:18080" ];
      socketConfig = {
        Accept = false;
      };
    };

    "secure-nginx-copyparty" = {
      description = "Secure Nginx Copyparty Metrics Socket (localhost only)";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:13923" ];
      socketConfig = {
        Accept = false;
      };
    };
  };

  # Systemd services to proxy connections to the container
  systemd.services = {
    "secure-nginx-http" = {
      description = "Proxy HTTP to secure-nginx container";
      requires = [
        "container@secure-nginx.service"
        "secure-nginx-http.socket"
      ];
      after = [
        "container@secure-nginx.service"
        "secure-nginx-http.socket"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.233.1.2:80";
        PrivateTmp = true;
        PrivateNetwork = false;
      };
    };

    "secure-nginx-copyparty" = {
      description = "Proxy Copyparty Metrics to secure-nginx container";
      requires = [
        "container@secure-nginx.service"
        "secure-nginx-copyparty.socket"
      ];
      after = [
        "container@secure-nginx.service"
        "secure-nginx-copyparty.socket"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.233.1.2:3923";
        PrivateTmp = true;
        PrivateNetwork = false;
      };
    };
  };
}
