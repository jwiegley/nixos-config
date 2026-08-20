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
    #
    # NOTE: the permissions around this path are load-bearing and non-obvious --
    # see the systemd.tmpfiles and users.groups blocks at the bottom of this
    # file before changing the ownership of it or of its parent.
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
    # Auto-(re)start when the Immich dataset mounts — covers a late or
    # manually-recovered tank import; upstream wantedBy=multi-user.target still
    # covers normal boot.
    wantedBy = [ "tank-Photos-Immich.mount" ];
    unitConfig = {
      RequiresMountsFor = [ "/tank/Photos/Immich" ];
      # SKIP cleanly (no crash-loop, no StartLimit exhaustion) when the dataset
      # isn't mounted. RequiresMountsFor is a no-op against the runtime ZFS mount,
      # so without this immich-server crash-looped and gave up PERMANENTLY on a
      # late/missing tank. Mirrors aria2.nix / samba.nix. (Audit 2026-06-08.)
      ConditionPathIsMountPoint = "/tank/Photos/Immich";
    };
  };

  systemd.services.immich-machine-learning = {
    after = [
      "zfs.target"
      "tank-Photos-Immich.mount"
    ];
    wantedBy = [ "tank-Photos-Immich.mount" ];
    unitConfig = {
      RequiresMountsFor = [ "/tank/Photos/Immich" ];
      ConditionPathIsMountPoint = "/tank/Photos/Immich";
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
    unitConfig = {
      RequiresMountsFor = [ "/tank/Photos" ];
      # Skip cleanly when /tank/Photos isn't mounted (don't fail the daily job).
      ConditionPathIsMountPoint = "/tank/Photos";
    };
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

  # ---------------------------------------------------------------------------
  # PERMISSIONS AROUND mediaLocation  (nixos-g52, decided by John 2026-08-18)
  # ---------------------------------------------------------------------------
  #
  # THE BUG THIS FIXES. systemd-tmpfiles-setup AND -resetup exited 73
  # (EX_CANTCREAT) on EVERY run, while still reporting Result=success -- so
  # `systemctl --failed` showed nothing and it went unnoticed for months. The
  # cause was upstream's own rule, generated from mediaLocation above:
  #
  #     e /tank/Photos/Immich 0700 immich immich -
  #
  #     Detected unsafe path transition /tank/Photos (owned by johnw) ->
  #     /tank/Photos/Immich (owned by immich) during canonicalization.
  #
  # systemd refuses to traverse into a directory whose owner differs from its
  # parent's unless that parent is root-owned. That is a deliberate hardening,
  # not a bug in systemd, so the fix has to satisfy it rather than work around
  # it.
  #
  # THE FIRST ATTEMPT AT THAT WAS WRONG, and this is the correction (2026-08-19).
  # Making /tank/Photos root-owned did make the Photos -> Immich edge legal, but
  # tmpfiles checks EVERY edge in the chain, and it simply moved the failure one
  # level up:
  #
  #     Detected unsafe path transition /tank (owned by johnw) ->
  #     /tank/Photos (owned by root) during canonicalization of tank/Photos/Immich.
  #
  # systemd's actual rule (src/basic/chase.c, unsafe_transition) is: a step is
  # safe iff the PARENT is root-owned, or parent and child have the SAME owner.
  # Apply that to this chain with /tank owned by johnw and the media directory
  # owned by immich, and no assignment for /tank/Photos satisfies both edges:
  #
  #     Photos=johnw -> Photos->Immich  unsafe (johnw -> immich)
  #     Photos=root  -> /tank->Photos   unsafe (johnw -> root)
  #     Photos=immich-> /tank->Photos   unsafe (johnw -> immich)
  #
  # So while /tank itself is owned by johnw, a tmpfiles rule on any path BELOW
  # /tank/Photos can never run. Only two things would actually fix it:
  #
  #   A. chown root /tank -- makes the first edge safe and every rule work. NOT
  #      done: /tank is the pool mountpoint, its ownership is on-disk state that
  #      no module declares, and taking it away from johnw changes who can
  #      create things at the top of the pool. That is John's call, not a
  #      side effect of an Immich fix.
  #   B. stop tmpfiles from chasing that path at all, and enforce the permission
  #      somewhere that does not canonicalize. That is what is done below.
  #
  # Note that part 1's rule on /tank/Photos itself is unaffected either way: the
  # unsafe-transition check applies to intermediate components, and /tank/Photos
  # is that rule's final component.
  #
  # WHY THE MODE IS 0750 AND NOT UPSTREAM'S 0700. /tank/Photos/Immich is also
  # exported over SMB as [tank-Photos-Immich] with `valid users = johnw
  # assembly` and no `force user`, so Samba touches the filesystem as the
  # logged-in user. At 0700 immich:immich neither valid user can read it -- the
  # share was verified DEAD before this change (johnw traverse: NO, list: NO).
  # 0750 plus the group membership below makes the share function as its own
  # config always intended.
  #
  # Upstream's 0700 exists to repair early-24.11 installs that created
  # WORLD-READABLE media storage (see the comment in nixos/modules/services/
  # web-apps/immich.nix). 0750 immich:immich is not world-readable, so that
  # privacy intent is preserved -- only the group bit is restored, and the group
  # has exactly one non-service member.
  #
  # THE PARTS ARE INTERDEPENDENT. Do not apply one without the others:
  #   1. parent johnw:immich -> johnw owns his own photo directory and can
  #      create in it; group immich gets r-x so the service can descend
  #   2. no tmpfiles rule below /tank/Photos, plus the ExecStartPre that
  #      replaces it -> the permission is still enforced, without the chase
  #   3. child mode 0750     -> group access for the SMB share
  #   4. johnw in immich     -> the share's other half, and how johnw reads the
  #      media directory itself (0750 immich:immich, group r-x)

  # Part 1. Non-recursive: `z` adjusts an existing path's mode/ownership and
  # never creates or deletes. Deliberately NOT `Z` (recursive -- would rewrite
  # ownership across the whole photo library) and emphatically not `D`, which
  # EMPTIES its target and has caused data loss on this host twice.
  # The setgid bit is retained so new entries keep inheriting group immich.
  #
  # johnw, not root. This briefly WAS `root immich` (2026-08-18), on the theory
  # that a root-owned parent legalised the tmpfiles transition. It did not --
  # see the correction above -- and it cost something real: at 2750 with root as
  # owner, johnw had no write bit on his own photo directory and could no longer
  # create folders in it. Verified before reverting: `test -w /tank/Photos` as
  # johnw failed. Do not "tidy" this back to root.
  systemd.tmpfiles.rules = [
    "z /tank/Photos 2750 johnw immich -"
  ];

  # Part 2. Drop upstream's `e /tank/Photos/Immich ...` entry entirely. An empty
  # attrset emits no rule for the path, which is the point: the rule cannot
  # succeed here (see option B above) and its only effect was to make
  # systemd-tmpfiles-setup and -resetup exit 73 on every boot and every rebuild,
  # where -- because Result stays `success` -- it was invisible to
  # `systemctl --failed` and quietly polluted the one signal that would have
  # shown a REAL tmpfiles failure.
  #
  # mkForce is needed because the immich module sets this path unconditionally.
  systemd.tmpfiles.settings.immich."/tank/Photos/Immich" = lib.mkForce { };

  # Part 2b. What upstream's entry was for, done where no canonicalization
  # happens. `+` runs this as root, outside the unit's sandbox, so it works even
  # if ownership has drifted away from immich; chmod/chown are idempotent and
  # this is a no-op in the normal case.
  #
  # 0750 rather than upstream's 0700 for the SMB reason documented above. This
  # is the drift protection the dropped tmpfiles rule used to provide -- it is
  # not redundant just because the mode happens to be right today.
  systemd.services.immich-server.serviceConfig.ExecStartPre = [
    "+${pkgs.coreutils}/bin/chown immich:immich /tank/Photos/Immich"
    "+${pkgs.coreutils}/bin/chmod 0750 /tank/Photos/Immich"
  ];

  # Part 3. See the interdependence note above -- this is what keeps johnw able
  # to reach /tank/Photos at all after part 1, and what makes the SMB share
  # usable. Scope checked before granting: no other user holds this group, and
  # the only other group-immich paths are /var/lib/immich (already 0755) and the
  # media tree itself.
  users.users.johnw.extraGroups = [ "immich" ];
}
