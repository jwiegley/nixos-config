{
  config,
  lib,
  pkgs,
  ...
}:

{
  # vdirsyncer - Synchronize calendars and contacts
  # Bidirectional sync between Radicale (local) and remote services
  # - johnw: Radicale <-> Fastmail
  # - nasimw: Radicale <-> iCloud
  # Documentation: https://vdirsyncer.pimutils.org/

  # SOPS secrets for authentication
  sops.secrets."vdirsyncer-johnw/fastmail-username" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-johnw/fastmail-password" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-johnw/radicale-username" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-johnw/radicale-password" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  # SOPS secrets for nasimw iCloud sync
  sops.secrets."vdirsyncer-nasimw/icloud-username" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-nasimw/icloud-password" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-nasimw/radicale-username" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-nasimw/radicale-password" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  # Create vdirsyncer user and group
  users.users.vdirsyncer = {
    isSystemUser = true;
    group = "vdirsyncer";
    description = "vdirsyncer synchronization service user";
    home = "/var/lib/vdirsyncer";
    createHome = true;
  };

  users.groups.vdirsyncer = { };

  # Install vdirsyncer package
  environment.systemPackages = [ pkgs.vdirsyncer ];

  # vdirsyncer configuration file
  environment.etc."vdirsyncer/config".text = ''
    [general]
    status_path = "/var/lib/vdirsyncer/status/"

    # ===== johnw: Fastmail <-> Radicale =====

    # Contacts sync pair (johnw)
    [pair contacts_johnw]
    a = "radicale_contacts_johnw"
    b = "fastmail_contacts"
    collections = [["personal", "contacts", "Default"]]
    metadata = ["displayname", "color"]
    conflict_resolution = "a wins"

    # Local Radicale storage (johnw)
    [storage radicale_contacts_johnw]
    type = "carddav"
    url = "http://127.0.0.1:5232/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-johnw/radicale-username".path
    }"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-johnw/radicale-password".path
    }"]

    # Remote Fastmail storage (johnw)
    [storage fastmail_contacts]
    type = "carddav"
    url = "https://carddav.fastmail.com/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-johnw/fastmail-username".path
    }"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-johnw/fastmail-password".path
    }"]

    # ===== nasimw: iCloud <-> Radicale =====

    # Contacts sync pair (nasimw)
    [pair contacts_nasimw]
    a = "radicale_contacts_nasimw"
    b = "icloud_contacts_nasimw"
    collections = ["from b"]
    metadata = ["displayname", "color"]
    conflict_resolution = "b wins"

    # Local Radicale storage (nasimw)
    [storage radicale_contacts_nasimw]
    type = "carddav"
    url = "http://127.0.0.1:5232/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-nasimw/radicale-username".path
    }"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-nasimw/radicale-password".path
    }"]

    # Remote iCloud storage (nasimw)
    [storage icloud_contacts_nasimw]
    type = "carddav"
    url = "https://contacts.icloud.com/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-nasimw/icloud-username".path
    }"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${
      config.sops.secrets."vdirsyncer-nasimw/icloud-password".path
    }"]
  '';

  # Systemd service for vdirsyncer sync
  systemd.services.vdirsyncer = {
    description = "vdirsyncer synchronization";
    after = [
      "network-online.target"
      "radicale.service"
      "sops-install-secrets.service"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "vdirsyncer";
      Group = "vdirsyncer";
      ExecStart = "${pkgs.vdirsyncer}/bin/vdirsyncer --config /etc/vdirsyncer/config sync";

      # State directory
      StateDirectory = "vdirsyncer";
      StateDirectoryMode = "0750";

      # Hardening
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

      # Network access required
      PrivateNetwork = false;

      # Allow writing to state directory
      ReadWritePaths = [ "/var/lib/vdirsyncer" ];
    };

    # Run discovery on first start
    preStart = ''
      if [ ! -f /var/lib/vdirsyncer/.discovered ]; then
        echo "Running initial discovery..."
        ${pkgs.vdirsyncer}/bin/vdirsyncer --config /etc/vdirsyncer/config discover
        touch /var/lib/vdirsyncer/.discovered
      fi
    '';
  };

  # Systemd timer for periodic sync (every 15 minutes)
  systemd.timers.vdirsyncer = {
    description = "vdirsyncer periodic synchronization timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
      Unit = "vdirsyncer.service";
      Persistent = true;
    };
  };

  # Status dashboard and Prometheus exporter service
  systemd.services.vdirsyncer-status = {
    description = "vdirsyncer Status Dashboard and Metrics Exporter";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "vdirsyncer";
      Group = "vdirsyncer";
      Restart = "always";
      RestartSec = 5;

      ExecStart = "${pkgs.python3}/bin/python3 /etc/nixos/scripts/vdirsyncer-status.py";

      # Hardening
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
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;

      # Read access to state directory
      ReadOnlyPaths = [ "/var/lib/vdirsyncer" ];
    };
  };

  # Nginx reverse proxy for status dashboard
  services.nginx.virtualHosts."vdirsyncer.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/vdirsyncer.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/vdirsyncer.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:8089/";
      recommendedProxySettings = true;
    };
  };

  # Open firewall for localhost access
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 8089 ];
}
