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
#     long note in modules/containers/quadlet.nix. wallabag and nocobase both
#     reach PostgreSQL this way.
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
          # WHY THIS IS NEEDED HERE AND NOT FOR NOCOBASE OR WALLABAG. Rootless
          # podman maps container uid 0 to the invoking host user, so an image
          # that runs as root lands its files on the host as that user with no
          # extra configuration -- which is why /var/lib/nocobase is cleanly
          # owned by nocobase(945). Grist's image drops to uid 1000, and 1000
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
