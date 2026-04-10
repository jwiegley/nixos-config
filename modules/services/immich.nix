{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Fix permissions on Immich external library directories so the immich
  # user can read files via group membership.  New photos imported by the
  # user sometimes land with owner-only permissions (e.g. 0400 johnw:johnw).
  immichFixPermsScript = pkgs.writeShellScript "immich-fix-permissions" ''
    set -euo pipefail

    PHOTO_DIR="/tank/Photos"
    IMMICH_DIR="$PHOTO_DIR/Immich"

    # Fix group ownership: anything not already group immich
    ${pkgs.findutils}/bin/find "$PHOTO_DIR" -path "$IMMICH_DIR" -prune \
      -o -not -group immich -print0 \
      | ${pkgs.findutils}/bin/xargs -0 -r ${pkgs.coreutils}/bin/chgrp immich

    # Fix group-read on files
    ${pkgs.findutils}/bin/find "$PHOTO_DIR" -path "$IMMICH_DIR" -prune \
      -o -type f -not -perm -g=r -print0 \
      | ${pkgs.findutils}/bin/xargs -0 -r ${pkgs.coreutils}/bin/chmod g+r

    # Fix group-read+execute on directories
    ${pkgs.findutils}/bin/find "$PHOTO_DIR" -path "$IMMICH_DIR" -prune \
      -o -type d -not -perm -g=rx -print0 \
      | ${pkgs.findutils}/bin/xargs -0 -r ${pkgs.coreutils}/bin/chmod g+rx
  '';
in
{
  # Enable Immich service with native NixOS module
  # Note: Using socket authentication for PostgreSQL (no password needed)
  # If you need OAuth/SMTP secrets later, add them via secretsFile without DB_PASSWORD
  services.immich = {
    enable = true;

    # Network configuration
    host = "127.0.0.1"; # Listen on localhost only, nginx will proxy
    port = 2283; # Default Immich port

    # Media storage location on ZFS
    mediaLocation = "/tank/Photos/Immich";

    # Enable built-in PostgreSQL with required extensions (VectorChord)
    # Uses socket authentication - no password needed
    database = {
      enable = true;
      createDB = true;
    };

    # Enable built-in Redis
    redis.enable = true;

    # Machine learning for face detection and smart search
    machine-learning.enable = true;

    # Enable telemetry for Prometheus metrics
    environment = {
      IMMICH_TELEMETRY_INCLUDE = "all";
      IMMICH_API_METRICS_PORT = "9283";
      IMMICH_MICROSERVICES_METRICS_PORT = "9284";
    };

    # Configuration settings
    # Note: Setting to null allows web UI configuration
    settings = null;
  };

  # Ensure Immich service waits for ZFS mount
  systemd.services.immich-server = {
    after = [
      "zfs.target"
      "tank-Photos-Immich.mount"
    ];
    unitConfig = {
      RequiresMountsFor = [ "/tank/Photos/Immich" ];
    };
  };

  systemd.services.immich-machine-learning = {
    after = [
      "zfs.target"
      "tank-Photos-Immich.mount"
    ];
    unitConfig = {
      RequiresMountsFor = [ "/tank/Photos/Immich" ];
    };
  };

  # Immich nginx upstream with retry logic
  services.nginx.upstreams."immich" = {
    servers = {
      "127.0.0.1:2283" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 16;
      keepalive_timeout 60s;
    '';
  };

  # Nginx reverse proxy for Immich
  services.nginx.virtualHosts."immich.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/immich.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/immich.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://immich/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Large file upload support for photos/videos
        client_max_body_size 50000M;

        # Extended timeouts for large file uploads
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;

        # Connection pooling
        proxy_set_header Connection "";
      '';
    };
  };

  # Daily job to fix permissions on external photo libraries
  systemd.services.immich-fix-permissions = {
    description = "Fix permissions on Immich external photo libraries";
    after = [ "zfs.target" ];
    unitConfig.RequiresMountsFor = [ "/tank/Photos" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = immichFixPermsScript;
      User = "root";
    };
  };

  systemd.timers.immich-fix-permissions = {
    description = "Daily Immich photo permissions fix";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
    };
  };

  # Firewall - only allow localhost access (nginx proxies)
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    2283 # Immich web interface
    9283 # Immich API metrics
    9284 # Immich microservices metrics
  ];
}
