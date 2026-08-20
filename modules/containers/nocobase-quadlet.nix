{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

# NocoBase - System Configuration
#
# Quadlet container: modules/users/home-manager/nocobase.nix
# This file: the enable switch, nginx virtual host, SOPS secrets, firewall, tmpfiles.
#
# ---------------------------------------------------------------------------
# WHY THIS IS OFF BY DEFAULT
# ---------------------------------------------------------------------------
# NocoBase was removed on 2026-03-14 (f40e2ac01) and its SOPS keys were cleaned
# up with it -- that commit's own message says "SOPS secrets must be cleaned up
# manually". Verified 2026-08-15: secrets/secrets.yaml contains no key matching
# nocobase. sops-nix fails activation for a declared secret whose key is absent,
# so declaring these unconditionally would break every rebuild on this host, not
# just NocoBase.
#
# Everything else is written and wired. To turn it on:
#
#   1. sops /etc/nixos/secrets/secrets.yaml   and add TWO keys:
#
#      nocobase-db-password: <the PostgreSQL password for role "nocobase">
#
#      nocobase-secrets: |          # an env file, one KEY=VALUE per line
#        APP_KEY=<random, e.g. openssl rand -hex 32>
#        ENCRYPTION_FIELD_KEY=<random, e.g. openssl rand -hex 32>
#        DB_PASSWORD=<the SAME value as nocobase-db-password>
#        INIT_ROOT_EMAIL=<first-run admin email>
#        INIT_ROOT_PASSWORD=<first-run admin password>
#
#      DB_PASSWORD and nocobase-db-password MUST match: the first is what the
#      container authenticates with, the second is what
#      postgresql-nocobase-setup.service sets on the role. They are two keys
#      rather than one because they have different owners (nocobase vs postgres)
#      and different shapes (env file vs bare value).
#
#      APP_KEY is not cosmetic -- changing it later invalidates every issued user
#      token. ENCRYPTION_FIELD_KEY protects encrypted field values; losing it
#      makes that data unrecoverable. Both are required by the image.
#      INIT_ROOT_* are read only on the very first boot against an empty schema.
#
#   2. Set services.nocobase.enable = true; in hosts/vulcan/default.nix
#   3. /etc/nixos/build switch
#   4. Issue the certificate (the vhost below references it, and nginx will not
#      start without it):
#        sudo /etc/nixos/certs/renew-certificate.sh "nocobase.vulcan.lan" \
#          -o /var/lib/nginx-certs -d 365 --owner nginx:nginx
#      nocobase.vulcan.lan is already in certs/renew-nginx-certs.sh so renewals
#      are automatic thereafter.
#
# ---------------------------------------------------------------------------
# WHAT WAS DELIBERATELY NOT RESTORED
# ---------------------------------------------------------------------------
#   * modules/monitoring/alerts/nocobase.yaml -- 4 of its 7 rules were already
#     dead or would be dead now. Three keyed on systemd_unit_state, a metric that
#     does not exist on this host (it is node_systemd_unit_state, and even that
#     only sees SYSTEM units -- a rootless quadlet's container unit lives in the
#     user manager and is invisible to it; only home-manager-nocobase.service
#     shows up). A fourth watched node_filesystem_avail_bytes for mountpoint
#     "/var/lib/nocobase", which is a directory on / and never had a series.
#     Restoring the file verbatim would have re-created exactly the dead-rule
#     class that was remediated across this repo.
#
#     Coverage is now automatic and better: container-health-exporter derives its
#     target list from config.home-manager.users, so enabling this service alone
#     produces container_health_status / container_running / container_restart_count
#     for it, which ContainerDown, ContainerUnhealthy, ContainerRestarting,
#     ContainerHealthCheckFailing, ContainerCPUSaturated and ContainerImageOutdated
#     already act on. The three rules that were genuinely live -- HTTPS probe,
#     slow response, cert expiry -- are covered by the blackbox target added in
#     modules/services/blackbox-monitoring.nix plus the generic probe and
#     certificate rules. Note wallabag, the closest analogue still deployed, has
#     no per-service alert file either.
#
#   * The second-check-system block. That hand-maintained check system was
#     dismantled starting 2026-07-31 and fully removed on 2026-08-19; Prometheus
#     and Alertmanager are the only monitoring system now, and the coverage above
#     is all of it.
#
#   * The modules/maintenance/timers.nix entry. rootlessContainerUsers is derived
#     from config.home-manager.users now, so the container image updater picks
#     this up with no edit. The hand-maintained list that used to drift is gone.
#
#   * The "L+ /run/secrets-nocobase/nocobase -> /run/secrets/nocobase" tmpfiles
#     rule. modules/users/container-users-dedicated.nix now says in terms: "Do not
#     reintroduce L+ rules here; add a sops path= override instead." The sops
#     path= form below is that override, and was already how this service worked.
#
#   * modules/containers/secrets-migration.nix. The whole container-db shared
#     secret grouping was retired along with the shared container users.
let
  cfg = config.services.nocobase;
in
{
  options.services.nocobase = {
    enable = lib.mkEnableOption "NocoBase low-code platform (evaluation)";
  };

  config = lib.mkIf cfg.enable {
    # Container user.
    #
    # Defined HERE rather than alongside the others in
    # modules/users/container-users-dedicated.nix because it has to be gated, and
    # that file assigns one literal `users = { ... }` attrset -- a lib.mkIf nested
    # inside a literal is not a definition boundary, so the module system would
    # hand the submodule a raw { _type = "if"; } and fail. The module system
    # merges these definitions with that file's either way.
    users.users.nocobase = {
      isSystemUser = true;
      group = "nocobase";
      home = "/var/lib/containers/nocobase";
      createHome = true;
      shell = pkgs.bash;
      autoSubUidGidRange = true;
      linger = true;
      extraGroups = [ "podman" ];
      description = "Container user for NocoBase low-code platform";
    };
    users.groups.nocobase = { };

    # Store access for rootless image pulls (list definitions merge).
    nix.settings.allowed-users = [ "nocobase" ];

    # postgres_fdw, for NocoBase's external-data-source feature.
    #
    # NocoBase issues `CREATE EXTENSION IF NOT EXISTS postgres_fdw;` as
    # nocobase@nocobase whenever an external PostgreSQL data source is added.
    # postgres_fdw is NOT a trusted extension -- pg_available_extension_versions
    # reports trusted=f, superuser=t -- so the unprivileged nocobase role cannot
    # create it and the attempt fails with "permission denied to create extension".
    # A superuser has to install it once; the GRANT then lets nocobase define
    # foreign servers, user mappings and imported schemas by itself.
    #
    # Both statements were first applied BY HAND on 2026-08-16 while debugging
    # this live. Declaring them here is what stops that state from existing only
    # in the running database, where a restore or a rebuilt database would lose
    # it silently and NocoBase would fail the same way again (nixos-75l).
    #
    # Ordered after postgresql-setup.service, not merely postgresql.service: the
    # nocobase DATABASE is created by ensureDatabases, which postgresql-setup
    # applies. Connecting to a database that does not exist yet is exactly the
    # race that made postgresql-nocobase-setup fail with `role "nocobase" does
    # not exist` on this service's first activation.
    #
    # Both statements are idempotent (IF NOT EXISTS; GRANT is naturally
    # repeatable), so this is safe to re-run on every boot.
    #
    # SECURITY NOTE, deliberately recorded rather than assumed harmless: USAGE on
    # a foreign-data wrapper lets the grantee make the PostgreSQL server process
    # open outbound connections and authenticate as whatever a user mapping
    # stores, and mapping passwords live in pg_user_mapping readable by the
    # mapping's owner. That is a real privilege, scoped here to the nocobase role
    # in its own database.
    systemd.services.postgresql-nocobase-fdw = {
      description = "Install postgres_fdw for NocoBase and grant it to the nocobase role";
      after = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      wants = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      requiredBy = [ "postgresql-nocobase-setup.service" ];
      before = [ "postgresql-nocobase-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql -d nocobase -v ON_ERROR_STOP=1 \
          -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw;"
        ${config.services.postgresql.package}/bin/psql -d nocobase -v ON_ERROR_STOP=1 \
          -c "GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO nocobase;"
      '';
    };

    # Nginx virtual host
    services.nginx.virtualHosts."nocobase.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/nocobase.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/nocobase.vulcan.lan.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:13000/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 100M;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
          proxy_connect_timeout 60s;
          # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
          # included by NixOS nginx module via recommendedProxySettings
        '';
      };
    };

    # SOPS secrets.
    #
    # The env file is delivered straight to /run/secrets-nocobase via sops
    # `path=` -- this IS the "sops path= override" the container-users module
    # mandates in place of an L+ symlink.
    sops.secrets."nocobase-secrets" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "nocobase";
      path = "/run/secrets-nocobase/nocobase-secrets";
    };

    # Consumed by postgresql-nocobase-setup.service (modules/services/databases.nix)
    # via systemd LoadCredential, hence owner postgres. Left at its default
    # /run/secrets/nocobase-db-password path, which that service names literally.
    sops.secrets."nocobase-db-password" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "postgres";
      restartUnits = [ "postgresql-nocobase-setup.service" ];
    };

    # Reachable from the podman bridge so the container's own health tooling and
    # the host can hit it; nginx itself proxies via 127.0.0.1.
    networking.firewall.interfaces.podman0.allowedTCPPorts = [
      13000 # nocobase
    ];

    # Storage for /app/nocobase/storage inside the container.
    #
    # `d`, never `D`: D EMPTIES the directory on every boot/rebuild and has caused
    # data loss on this host twice (mail 2025-11-04, container databases
    # 2025-11-09). `Z` recursively fixes ownership without deleting anything,
    # which matters because the container runs with PODMAN_USERNS=keep-id.
    systemd.tmpfiles.rules = [
      "d /var/lib/nocobase 0755 nocobase nocobase -"
      "Z /var/lib/nocobase 0755 nocobase nocobase -"
      # Secrets drop directory, matching the convention every other container
      # user follows in modules/users/container-users-dedicated.nix. The sops
      # `path=` above writes the env file directly into it; there is deliberately
      # no L+ symlink, which that module forbids.
      "d /run/secrets-nocobase 0750 nocobase nocobase - -"
    ];
  };
}
