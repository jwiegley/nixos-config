{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

# NocoBase - rootless quadlet container (Home Manager)
#
# Restored 2026-08-15 for further evaluation. Removed 2026-03-14 in f40e2ac01
# together with n8n, Windows 11 and ntopng; nothing of the old deployment
# survived -- no PostgreSQL role or database, no /var/lib/nocobase, no user or
# group, no certificate, no image -- so this is a fresh install rather than a
# restore of prior state.
#
# Gated on services.nocobase.enable (declared in
# modules/containers/nocobase-quadlet.nix), which is OFF until the two SOPS keys
# it needs exist. See that file for the contract.
#
# Modernised against the 2026-03 original, which would no longer work as written:
#
#   * DB_HOST is 10.88.0.1, not 127.0.0.1. The original set POSTGRES_HOST, which
#     NocoBase does not read at all (it uses DB_*), so the database host came
#     from the secrets file or defaulted. 10.88.0.1 is the pinned, config-static
#     podman bridge address -- see the long note in modules/containers/quadlet.nix
#     about the 2026-07-03 boot race, where rootless containers froze the microVM
#     bridge into /etc/hosts and every DB client hit pg_hba's reject catch-all.
#     wallabag reaches PostgreSQL exactly this way.
#
#   * ExecStartPre retries instead of a single pg_isready -t 30. The original
#     would fail the unit outright if PostgreSQL was slow to accept connections;
#     the current idiom (wallabag, and every other DB-dependent container here)
#     polls for up to two minutes.
#
#   * The second publishPorts entry (10.88.0.1:13000) is dropped. Nginx proxies
#     from the host loopback, so exposing the bridge address only widened reach
#     for no consumer.
let
  cfg = config.services.nocobase;
in
{
  home-manager.users.nocobase = lib.mkIf cfg.enable (
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
      home.username = "nocobase";
      home.homeDirectory = "/var/lib/containers/nocobase";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
        postgresql
      ];

      virtualisation.quadlet.containers.nocobase = {
        autoStart = true;

        containerConfig = {
          # Pinned to a digest-less tag deliberately: this is an evaluation
          # deployment and the container image updater (modules/maintenance/timers.nix)
          # rolls it forward on its own schedule.
          image = "docker.io/nocobase/nocobase:latest";
          publishPorts = [ "127.0.0.1:13000:80/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          # Non-secret configuration only. Everything secret -- APP_KEY,
          # ENCRYPTION_FIELD_KEY, DB_PASSWORD -- arrives via environmentFiles.
          environments = {
            APP_ENV = "production";
            DB_DIALECT = "postgres";
            DB_HOST = "10.88.0.1";
            DB_PORT = "5432";
            DB_DATABASE = "nocobase";
            DB_USER = "nocobase";
          };

          environmentFiles = [ "/run/secrets-nocobase/nocobase-secrets" ];

          volumes = [
            "/var/lib/nocobase:/app/nocobase/storage"
          ];
        };

        unitConfig = {
          After = [ "network-online.target" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do ${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -t 2 && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; exit 1'";
          Restart = "always";
          RestartSec = "10s";
          # NocoBase runs migrations on first boot against an empty schema, which
          # is by far the slowest start. 900s is the original value and is kept.
          TimeoutStartSec = "900";
        };
      };
    }
  );
}
