{
  config,
  lib,
  pkgs,
  hostPolicy,
  ...
}:

# Grist - System Configuration
#
# Quadlet container: modules/users/home-manager/grist.nix
# This file: the enable switch, nginx virtual host, SOPS secrets, Redis, firewall,
# storage, and the PostgreSQL bootstrap.
#
# ---------------------------------------------------------------------------
# WHY A CONTAINER AND NOT A NATIVE SERVICE
# ---------------------------------------------------------------------------
# There is no nixpkgs package and no NixOS module for Grist -- verified 2026-08-19
# against nixpkgs unstable, which returns nothing for either `grist` package or
# option. Upstream ships an official image and that is the supported path, so this
# follows the rootless-quadlet pattern already used here by Wallabag, OpenProject
# and others rather than packaging grist-core by hand.
#
# ---------------------------------------------------------------------------
# WHY THIS IS OFF BY DEFAULT
# ---------------------------------------------------------------------------
# sops-nix fails ACTIVATION for a declared secret whose key is absent from
# secrets.yaml -- not just the one service, the whole rebuild. So the secrets
# below are declared inside this `mkIf`, and the switch stays off until the keys
# exist. NocoBase established this contract for the same reason; it was removed
# 2026-08-31, so this module is now the reference implementation of it.
#
# To turn it on:
#
#   1. sops /etc/nixos/secrets/secrets.yaml   and add TWO keys:
#
#      grist-db-password: <the PostgreSQL password for role "grist">
#
#      grist-secrets: |            # an env file, one KEY=VALUE per line
#        GRIST_SESSION_SECRET=<random, e.g. openssl rand -hex 32>
#        TYPEORM_PASSWORD=<the SAME value as grist-db-password>
#
#      TYPEORM_PASSWORD and grist-db-password MUST match: the first is what the
#      container authenticates with, the second is what postgresql-grist-setup
#      sets on the role. They are two keys rather than one because they have
#      different owners (grist vs postgres) and different shapes (env file vs
#      bare value).
#
#      GRIST_SESSION_SECRET signs browser session cookies. Changing it later
#      invalidates every existing session; losing it only forces re-login, so it
#      is not as unforgiving as an encryption key, but it should still be random
#      and kept.
#
#   2. Set services.grist.enable = true; in hosts/vulcan/default.nix
#   3. /etc/nixos/build switch
#   4. Issue the certificate -- the vhost below references it and nginx will NOT
#      start without it, so this is not optional:
#        sudo /etc/nixos/certs/renew-certificate.sh "grist.vulcan.lan" \
#          -o /var/lib/nginx-certs -d 365 --owner nginx:nginx
#      grist.vulcan.lan is already in certs/renew-nginx-certs.sh, so renewals
#      are automatic thereafter.
#
# ---------------------------------------------------------------------------
# MONITORING, and what was deliberately NOT built
# ---------------------------------------------------------------------------
# Grist exposes NO Prometheus metrics. Upstream issue gristlabs/grist-core#671
# ("Monitoring Grist using Prometheus or OpenTelemetry?") is still an open
# feature request, so there is no /metrics endpoint to scrape and no
# service-specific series to dashboard. No Grafana dashboard is provided for
# that reason -- an empty dashboard is worse than none.
#
# Coverage is instead automatic and comes from three existing mechanisms:
#   * container-health-exporter derives its target list from
#     config.home-manager.users, so enabling this service alone produces
#     container_health_status / container_running / container_restart_count,
#     which ContainerDown, ContainerUnhealthy, ContainerRestarting,
#     ContainerCPUSaturated and ContainerImageOutdated already act on. Verified
#     empirically 2026-08-19 against nocobase, which appeared in that metric
#     purely by existing. NocoBase was removed 2026-08-31; the mechanism is
#     unchanged, since it keys on the container rather than on any one service.
#   * the blackbox_https_local target added in
#     modules/services/blackbox-monitoring.nix, covered by the generic probe
#     rules.
#   * certificate expiry, via the shared nginx cert rules.
#
# Those three mechanisms are the WHOLE of the coverage, deliberately. Prometheus
# and Alertmanager are the only monitoring system on this host -- the second,
# hand-maintained check system was removed on 2026-08-19 -- so there is no
# per-service check list to add an entry to, and none is wanted.
let
  cfg = config.services.grist;
in
{
  options.services.grist = {
    enable = lib.mkEnableOption "Grist collaborative spreadsheet";
  };

  config = lib.mkIf cfg.enable {
    # Container user.
    #
    # Declared HERE rather than in modules/users/container-users-dedicated.nix
    # for the reason NocoBase was before its 2026-08-31 removal: this must be
    # gated, and that file assigns
    # one literal `users = { ... }` attrset, where a nested lib.mkIf is not a
    # definition boundary -- the module system would hand the submodule a raw
    # { _type = "if"; } and fail. Definitions merge with that file either way.
    users.users.grist = {
      isSystemUser = true;
      group = "grist";
      home = "/var/lib/containers/grist";
      createHome = true;
      shell = pkgs.bash;
      autoSubUidGidRange = true;
      linger = true;
      extraGroups = [ "podman" ];
      description = "Container user for Grist";
    };
    users.groups.grist = { };

    # Store access for rootless image pulls (list definitions merge).
    nix.settings.allowed-users = [ "grist" ];

    # Redis, used by Grist as its session/state store.
    #
    # Without it Grist keeps sessions in a local grist-sessions.db SQLite file.
    # Using the host Redis instead is what John asked for, and it means session
    # state survives a container image roll.
    #
    # bind 0.0.0.0, not 127.0.0.1, because this container reaches the host by
    # the pinned bridge address 10.88.0.1 (see the REDIS_URL note in
    # modules/users/home-manager/grist.nix) and a loopback-bound Redis is not
    # reachable there. openproject (6383) binds 0.0.0.0 for the same reason.
    #
    # The other per-service instances here -- searxng 6386, speedtest-tracker
    # 6387 -- bind 127.0.0.1 instead, and that is NOT an inconsistency to
    # "fix": they address the host as host.containers.internal, which under
    # slirp4netns lands on the host's loopback. This service deliberately does
    # not use that name; it is what caused the 2026-07-03 boot race.
    #
    # Exposure is limited by the firewall block below, which opens 6388 ONLY on
    # podman0 -- it is not reachable from the LAN.
    services.redis.servers.grist = {
      enable = true;
      port = 6388;
      bind = "0.0.0.0";
      settings = {
        protected-mode = "no";
        maxmemory = "128mb";
        # Sessions are cache-like and safe to evict under pressure; the durable
        # state is in PostgreSQL and /tank/Documents/Grist.
        maxmemory-policy = "allkeys-lru";
      };
    };

    # Nginx virtual host.
    services.nginx.virtualHosts."grist.${hostPolicy.dnsName}" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/grist.${hostPolicy.dnsName}.crt";
      sslCertificateKey = "/var/lib/nginx-certs/grist.${hostPolicy.dnsName}.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8484/";
        # Grist is realtime: the document view holds a websocket open, and
        # without this every edit session dies at the proxy.
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          # Attachments and document imports; Grist's own default limit is well
          # under this, so this is the proxy getting out of the way.
          client_max_body_size 1G;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
          proxy_connect_timeout 60s;
          # Standard proxy headers come from recommendedProxySettings.
        '';
      };
    };

    # SOPS secrets.
    #
    # The env file is delivered straight to /run/secrets-grist via sops `path=`.
    # modules/users/container-users-dedicated.nix forbids reintroducing `L+`
    # symlink rules for this and mandates exactly this path= override.
    sops.secrets."grist-secrets" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "grist";
      path = "/run/secrets-grist/grist-secrets";
    };

    # Consumed by postgresql-grist-setup.service (modules/services/databases.nix)
    # via systemd LoadCredential, hence owner postgres. Left at its default
    # /run/secrets/grist-db-password path, which that service names literally.
    sops.secrets."grist-db-password" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "postgres";
      restartUnits = [ "postgresql-grist-setup.service" ];
    };

    # Reachable from the podman bridge only. 8484 is here so the container's own
    # tooling and the host can reach it; nginx proxies via 127.0.0.1.
    networking.firewall.interfaces.podman0.allowedTCPPorts = [
      8484 # grist
      6388 # redis - grist
    ];

    # Storage for Grist's /persist -- documents, attachments and its own
    # bookkeeping.
    #
    # /tank/Documents/Grist, moved off /var/lib/grist on 2026-09-11 at John's
    # request. A plain directory inside the existing tank/Documents dataset, not
    # a dataset of its own -- also his choice. What the move buys and what it
    # costs, each item measured rather than assumed:
    #
    #   * GAINED: hourly and archival ZFS snapshots on tank/Documents, and
    #     offsite B2 through the existing `Documents` restic job at 04:25
    #     (modules/storage/backups.nix). Note when reading that file that the
    #     commented-out `mkBackup { path = "Documents"; }` near the top is STALE
    #     -- the live call site is further down and has been running since
    #     2026-08-14. Its excludes are .stfolder/.stignore/.stversions/Sessions,
    #     none of which touch this directory.
    #   * GAINED: Syncthing replication to the peers in
    #     modules/services/syncthing.nix. John chose this deliberately on
    #     2026-09-11, having been shown the hazard first: that folder is
    #     `sendreceive`, so Syncthing can write a peer's copy back into a live
    #     SQLite file that Grist holds open. If a document ever returns corrupt,
    #     or a ~conflicted~ copy appears beside it, THIS is the cause, and the
    #     fix is a "/Grist" entry in the documents folder's ignorePatterns --
    #     not anything on the Grist side.
    #   * LOST: the 4x-daily /var/lib rsync into /tank/Backups/Machines/Vulcan
    #     (modules/services/local-backup.nix). That mirror DID cover the old
    #     location, contrary to what this comment used to claim: grist is absent
    #     from its exclude list and its `**/*.sqlite` globs never matched the
    #     `.grist` suffix. The mirror runs with --delete, so the orphaned copy at
    #     .../Vulcan/var/lib/grist clears itself on the next run -- nothing to
    #     remove by hand.
    #
    # NOT systemd-tmpfiles, which is how the old location was created.
    # systemd-tmpfiles runs before the ZFS import, so a `d` rule here would
    # create the directory beneath an unmounted mountpoint and leave it shadowed
    # once tank came up. The oneshot below is ordered on the mount unit instead,
    # which is the pattern modules/services/immich.nix already uses for
    # /tank/Photos/Immich.
    #
    # There is no `Z` rule any more either. A recursive chmod rewrites the POSIX
    # ACL mask to `---`, which would leave syncthing's named ACL entry visibly
    # present and silently ineffective on every boot -- the exact failure with
    # the six-day post-mortem in modules/services/syncthing.nix. The subuid
    # ownership problem `Z` was there to solve is handled properly by
    # --userns=keep-id in modules/users/home-manager/grist.nix.
    systemd.services.grist-storage-init = {
      description = "Prepare Grist document storage under /tank/Documents";
      after = [
        "zfs.target"
        "tank-Documents.mount"
      ];
      # Also (re)start when the dataset mounts, so a late or hand-recovered tank
      # import is covered as well as an ordinary boot.
      wantedBy = [
        "tank-Documents.mount"
        "multi-user.target"
      ];
      unitConfig = {
        RequiresMountsFor = [ "/tank/Documents" ];
        # RequiresMountsFor is a no-op against a runtime ZFS mount, so this is
        # what actually makes the unit skip cleanly rather than fail when tank is
        # absent. Mirrors immich.nix / aria2.nix / samba.nix.
        ConditionPathIsMountPoint = "/tank/Documents";
      };
      path = [
        pkgs.acl
        pkgs.coreutils
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        install -d -m 0750 -o grist -g grist /tank/Documents/Grist

        # /tank/Documents is other::--- , so grist cannot so much as traverse
        # into it without a named entry. This is the same ancestor-grant
        # mechanism syncthing-folder-acls applies to its own sub-folders.
        setfacl -m u:grist:x /tank/Documents

        # The mask is set on the SAME setfacl invocation as every named entry,
        # and must stay that way. The install -d above rewrites it to r-x, which
        # would leave u:syncthing as "#effective:r--" -- present in getfacl
        # output, correct-looking, and unable to complete a pull. The full
        # post-mortem of that bug is in modules/services/syncthing.nix.
        setfacl -R \
          -m u:grist:rwX \
          -m u:syncthing:rwX \
          -m u:johnw:rwX \
          -m m::rwX \
          /tank/Documents/Grist

        # Defaults, so documents Grist creates later stay reachable by syncthing
        # without waiting for the next sweep.
        setfacl \
          -m d:u:grist:rwX \
          -m d:u:syncthing:rwX \
          -m d:u:johnw:rwX \
          -m d:m::rwX \
          /tank/Documents/Grist
      '';
    };

    systemd.tmpfiles.rules = [
      # Secrets drop directory, matching the convention every other container
      # user follows. The sops `path=` above writes the env file into it; there
      # is deliberately no L+ symlink.
      "d /run/secrets-grist 0750 grist grist - -"
    ];
  };
}
