{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

# Grist - rootless quadlet container (Home Manager)
#
# System side, including the enable switch and the SOPS contract:
# modules/containers/grist-quadlet.nix. Gated on services.grist.enable, which is
# OFF until the two keys exist.
#
# CONFIGURATION NOTES, each of which is a thing that bites if guessed:
#
#   * TYPEORM_* is how Grist is pointed at PostgreSQL -- not DATABASE_URL, not
#     PG*. Grist uses TypeORM for its home database (orgs, workspaces, users,
#     ACLs); the spreadsheet documents themselves stay as SQLite files under
#     /persist and are NOT in PostgreSQL. So losing /var/lib/grist loses the
#     documents even with the database intact.
#
#   * TYPEORM_HOST is 10.88.0.1, the pinned podman bridge address, NOT
#     127.0.0.1 (which is the container's own loopback) and NOT
#     host.containers.internal. The latter is what caused the 2026-07-03 boot
#     race on this host, where rootless containers froze a stale bridge address
#     into /etc/hosts and every DB client hit pg_hba's reject catch-all. See the
#     long note in modules/containers/quadlet.nix. wallabag reaches PostgreSQL
#     this way too.
#
#   * PostgreSQL's JIT used to have to be disabled for Grist -- every cell
#     operation took seconds with it on. Grist >= 1.5.0 disables JIT itself on
#     connect, so nothing is done here. Recorded because the old advice is all
#     over the internet and looks like a missing step.
#
#   * APP_HOME_URL must be the EXTERNAL https URL, not the container's own
#     address. Grist builds absolute links and websocket URLs from it, so
#     getting this wrong produces a UI that loads and then fails to connect.
let
  cfg = config.services.grist;
in
{
  home-manager.users.grist = lib.mkIf cfg.enable (
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      home.stateVersion = "24.11";
      home.username = "grist";
      home.homeDirectory = "/var/lib/containers/grist";

      # NOTE: no PODMAN_USERNS here, unlike the other container users on this
      # host. home.sessionVariables is written into the shell profile and is NOT
      # inherited by systemd user units, so setting it there never affected any
      # of these containers -- it is a no-op that reads like configuration. The
      # real mapping is set with --userns below.

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
        postgresql
      ];

      virtualisation.quadlet.containers.grist = {
        autoStart = true;

        containerConfig = {
          # Digest-less tag on purpose: the container image updater
          # (modules/maintenance/timers.nix) derives its user list from
          # config.home-manager.users and rolls this forward on its own
          # schedule, so pinning here would fight it.
          image = "docker.io/gristlabs/grist:latest";
          publishPorts = [ "127.0.0.1:8484:8484/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          # Map the container's uid/gid 1000 onto the HOST grist user, so files
          # written into /persist are owned by grist(899) on disk.
          #
          # WHY THIS IS NEEDED HERE AND NOT FOR WALLABAG. Rootless podman maps
          # container uid 0 to the invoking host user, so an image that runs as
          # root lands its files on the host as that user with no extra
          # configuration -- which was also true of nocobase (removed
          # 2026-08-31), whose /var/lib/nocobase was cleanly owned by
          # nocobase(945). Grist's image drops to uid 1000, and 1000
          # maps into the user's SUBUID range instead: /var/lib/grist ended up
          # owned by 2394760 (= grist's subuid base 2393760 + 1000).
          #
          # That is not cosmetic. The `Z /var/lib/grist 0750 grist grist` rule in
          # modules/containers/grist-quadlet.nix recursively chowns the tree back
          # to grist(899) on EVERY boot and every rebuild, and at 0750 the subuid
          # then has no access at all -- so Grist would lose write access to its
          # own documents at the next activation. Verified by running
          # `systemd-tmpfiles --create --prefix=/var/lib/grist` by hand: it
          # rewrote 2394760 -> 899 exactly as predicted.
          #
          # Fixing the mapping is the right half to change rather than dropping
          # the tmpfiles rule: on-disk ownership then matches what every other
          # service here assumes, and the data directory stays administrable as
          # the grist user.
          podmanArgs = [ "--userns=keep-id:uid=1000,gid=1000" ];

          # Non-secret configuration only. GRIST_SESSION_SECRET and
          # TYPEORM_PASSWORD arrive via environmentFiles.
          environments = {
            GRIST_HOST = "0.0.0.0";
            GRIST_PORT = "8484";
            APP_HOME_URL = "https://grist.vulcan.lan";
            GRIST_DOMAIN = "grist.vulcan.lan";
            # Single-org ("personal") mode: one team site rather than Grist's
            # multi-tenant SaaS layout, which is what makes sense for a
            # single-household install.
            GRIST_SINGLE_ORG = "vulcan";

            # The install's default user. SET ONLY AFTER the ownership grant
            # below was done -- the order is load-bearing, and deploying this
            # first makes things worse rather than better.
            #
            # WHAT WENT WRONG. Omitting it at first deploy is what caused the
            # "Access denied". setUpSingleOrg() creates the single org with
            # getAdminEmail() || getDefaultEmail(); with neither set, grist-core
            # used its built-in placeholder you@example.com and made it the sole
            # member of the org's owners group. johnw got a Personal org of his
            # own and NO membership in "vulcan", while GRIST_SINGLE_ORG forces
            # every request onto that site.
            #
            # WHY SETTING IT DOES NOT FIX THAT. Ownership is assigned ONLY in
            # setUpSingleOrg's `catch (organization not found)` branch, i.e.
            # once, at creation. With org 3 already present that path is a no-op
            # lookup forever, and nothing reconciles env -> ACLs at boot. Install
            # -admin status confers no bypass either: PATCH /api/orgs/:id/access
            # uses a plain scope check.
            #
            # WHY IT IS ACTIVELY HARMFUL RIGHT NOW. With no auth provider,
            # minimal login resolves every request to this address. Today that
            # is you@example.com -- the one account that IS an org owner, and
            # therefore the only working way in. Setting this flips minimal
            # login to johnw@vulcan.lan, who has zero membership, turning a
            # partly-working site into a fully-denied one. It is also a one-way
            # door: AppSettings puts process.env ahead of the DB-stored envVars,
            # so /admin can no longer override it back.
            #
            # THE ORDER THAT WAS FOLLOWED (2026-08-19), and must be followed
            # again if this install is ever rebuilt from empty:
            #   1. In a browser, as you@example.com, add johnw@vulcan.lan as an
            #      Owner of the vulcan site via Share > Manage users. Doing it
            #      through the app is what makes group_groups inheritance reach
            #      the workspace and the existing document and invalidates the
            #      Redis doc-access cache; a direct SQL insert does neither.
            #   2. Verify: SELECT user_id FROM group_users WHERE group_id=19;
            #      must return both 5 and 6. It returned 5,6, and the owners
            #      group was confirmed to reach workspace 3 and the one existing
            #      document by inheritance.
            #   3. ONLY THEN set the line below and rebuild.
            #
            # SECURITY PROPERTY, once it is set. No auth provider is configured
            # -- no GRIST_OIDC_*, no SAML, no forward auth -- so grist-core
            # treats every request as this user. Anyone who can reach
            # grist.vulcan.lan is that account, with full admin. It is an
            # identity string, not a credential. Acceptable while the vhost is
            # LAN-only and trusted; putting this behind the public edge without
            # a real auth provider first would hand admin to the internet.
            GRIST_DEFAULT_EMAIL = "johnw@vulcan.lan";

            # Home database on the host PostgreSQL.
            TYPEORM_TYPE = "postgres";
            TYPEORM_HOST = "10.88.0.1";
            TYPEORM_PORT = "5432";
            TYPEORM_DATABASE = "grist";
            TYPEORM_USERNAME = "grist";

            # Session/state store on the host Redis, so sessions survive an
            # image roll instead of living in a container-local SQLite file.
            REDIS_URL = "redis://10.88.0.1:6388";
          };

          environmentFiles = [ "/run/secrets-grist/grist-secrets" ];

          volumes = [
            "/var/lib/grist:/persist"
          ];
        };

        unitConfig = {
          After = [ "network-online.target" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          # Poll for PostgreSQL rather than a single pg_isready -t 30: on a cold
          # boot the database is often not accepting connections yet, and a
          # one-shot check fails the unit outright. Every DB-dependent container
          # here uses this idiom.
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do ${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -t 2 && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; exit 1'";
          Restart = "always";
          RestartSec = "10s";
          # First boot runs migrations against an empty home database, which is
          # much slower than a normal start.
          TimeoutStartSec = "600";
        };
      };
    }
  );
}
