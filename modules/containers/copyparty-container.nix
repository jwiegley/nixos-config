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
    before = [ "container@copyparty.service" ];
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
  fileSystems = bindTankPath {
    path = "/var/www/home.newartisans.com";
    device = "/tank/Public";
    isReadOnly = false;
  };

  # NixOS container for copyparty (HTTP-only, localhost access)
  containers.copyparty = {

    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = "10.233.2.1";
    localAddress = "10.233.2.2";

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
            # Allow copyparty port
            allowedTCPPorts = [ 3923 ];
          };
        };

        # Time zone (match host)
        time.timeZone = "America/Los_Angeles";

        # Force DNS to point to host (works around resolvconf issues in containers)
        environment.etc."resolv.conf".text = lib.mkForce ''
          nameserver 10.233.2.1
          options edns0
        '';

        # Enable copyparty service with password files
        services.copyparty = {
          enable = true;
          port = 3923;
          domain = "data.newartisans.com";
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
          copyparty = {
            after = [ "var-www-home.newartisans.com.mount" ];
          };
        };
      };
  };

  # Systemd socket unit for localhost-only port forwarding to container
  systemd.sockets = {
    "copyparty-http" = {
      description = "Copyparty HTTP Socket (localhost only)";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:13923" ];
      socketConfig = {
        Accept = false;
      };
    };
  };

  # Systemd service to proxy connections to the container
  systemd.services = {
    "copyparty-http" = {
      description = "Proxy HTTP to copyparty container";
      requires = [
        "container@copyparty.service"
        "copyparty-http.socket"
      ];
      after = [
        "container@copyparty.service"
        "copyparty-http.socket"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 10.233.2.2:3923";
        PrivateTmp = true;
        PrivateNetwork = false;
      };
    };
  };
}
