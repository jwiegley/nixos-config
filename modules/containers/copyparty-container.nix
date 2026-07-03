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
  # Pinned copyparty user/group on the host. The container's copyparty user is
  # pinned to the same UID/GID (see modules/services/copyparty.nix). Without
  # this, the host shows copyparty-owned files as whatever stranger happens to
  # share the auto-allocated UID (was "nm-iodine"); with it, `ls` displays
  # copyparty:copyparty correctly and ownership stays stable across rebuilds.
  users.users.copyparty = {
    isSystemUser = true;
    uid = 970;
    group = "copyparty";
    description = "Copyparty file server user (host placeholder for container UID)";
  };
  users.groups.copyparty.gid = 970;

  # One-shot fixup that runs before the copyparty container starts. Reclaims any
  # files left orphaned by a previous container UID (e.g. the old 999) so the
  # service inside the container can read/write them under the pinned 970.
  systemd.services.copyparty-ownership-fixup = {
    description = "Reclaim copyparty-owned files under pinned UID 970";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@copyparty.service" ];
    after = [ "var-www-home.newartisans.com.mount" ];
    requires = [ "var-www-home.newartisans.com.mount" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # The "stale" UIDs are previous auto-allocations that copyparty has used
    # historically inside this container (996 and 999 seen in the wild). Anything
    # under the state dir or the share that's still owned by one of those gets
    # repatriated to the pinned 970.
    script = ''
      set -eu
      state=/var/lib/copyparty-container
      share=/var/www/home.newartisans.com

      # State dir: recursively reclaim everything inside (config files, .hist,
      # .th, .config, ...). The parent itself stays root-owned per tmpfiles.
      if [ -d "$state" ]; then
        ${pkgs.findutils}/bin/find "$state" -mindepth 1 \
          \( -not -uid 970 -o -not -gid 970 \) -exec \
          ${pkgs.coreutils}/bin/chown 970:970 {} + || true
      fi

      # Share dir: only touch entries currently owned by a previous copyparty UID.
      # Leaves host-managed dirs (johnw, nasimw, aria2-owned download/) untouched.
      if [ -d "$share" ]; then
        ${pkgs.findutils}/bin/find "$share" \( -uid 996 -o -uid 999 \) -exec \
          ${pkgs.coreutils}/bin/chown 970 {} + || true
        ${pkgs.findutils}/bin/find "$share" \( -gid 994 -o -gid 999 \) -exec \
          ${pkgs.coreutils}/bin/chgrp 970 {} + || true
      fi
    '';
  };

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

      # Note: 644 is required here because these files are bind-mounted into a
      # NixOS container where the copyparty user (with a container-allocated UID)
      # needs to read them. The files are owned by root:root on the host, so
      # world-readable is the only way the container user can access them.
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

  # Ensure directories exist on host. State subdirs owned by the pinned
  # copyparty user so tmpfiles doesn't undo the ownership-fixup service on
  # every reboot.
  systemd.tmpfiles.rules = [
    # BIND MOUNT of /tank/Public — mode/owner '-' so tmpfiles only creates the
    # mountpoint and never chmods the mounted dataset (an explicit mode here
    # re-applied chmod 0755 on every boot/resetup, resetting the POSIX ACL
    # mask syncthing needs; 2026-07-03 audit root cause).
    "d /var/www/home.newartisans.com - - - -"
    "d /var/lib/copyparty-container 0755 root root -"
    "d /var/lib/copyparty-container/.hist 0755 copyparty copyparty -"
    "d /var/lib/copyparty-container/.th 0755 copyparty copyparty -"
    "d /var/lib/copyparty-passwords 0755 root root -"
    # NOTE: /tank/Public/{johnw,nasimw} tmpfiles rules removed 2026-07-03
    # (post-reboot audit): the dirs are persistent ZFS-backed data owned
    # syncthing:syncthing / nasimw:nasimw — per CLAUDE.md, persistent data
    # dirs must not be managed via tmpfiles, and these root:root rules would
    # have broken ownership if they ever fired on a fresh dataset.
  ];

  # Bind mount ZFS dataset to host directory (container will access via bindMount)
  fileSystems = bindTankPath {
    path = "/var/www/home.newartisans.com";
    device = "/tank/Public";
    isReadOnly = false;
  };

  # Persistent networkd config for the container veth — prevents systemd-networkd's
  # default 80-container-ve.network from overriding the address set by the
  # container post-start script (which uses `ip addr add` and gets lost on
  # networkd reconfiguration, e.g. during nixos-rebuild).
  systemd.network.networks."40-ve-copyparty" = {
    matchConfig.Name = "ve-copyparty";
    address = [ "10.233.2.1/32" ];
    routes = [ { Destination = "10.233.2.2/32"; } ];
    networkConfig = {
      IPMasquerade = "both";
      LinkLocalAddressing = "yes";
    };
    linkConfig.RequiredForOnline = false;
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

  # Override the auto-generated container post-start script to use idempotent
  # ip commands. The networkd config (40-ve-copyparty) may already have assigned
  # the address, so `ip addr add` fails with "Address already assigned" on
  # container restart. Using `replace` is idempotent and works either way.
  systemd.services."container@copyparty".serviceConfig.ExecStartPost = lib.mkForce [
    (pkgs.writeScript "copyparty-post-start" ''
      #!${pkgs.bash}/bin/bash
      set -o errexit
      set -o nounset
      set -o pipefail

      ifaceHost=ve-copyparty
      ${pkgs.iproute2}/bin/ip link set dev "$ifaceHost" up
      ${pkgs.iproute2}/bin/ip addr replace 10.233.2.1/32 dev "$ifaceHost"
      ${pkgs.iproute2}/bin/ip route replace 10.233.2.2/32 dev "$ifaceHost"
    '')
  ];

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
