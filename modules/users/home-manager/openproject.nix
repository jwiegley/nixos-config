# OpenProject - Rootless Quadlet Container Configuration
#
# This file defines the Podman quadlet container for OpenProject
# managed via Home Manager for rootless operation.

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.openproject =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # Import the quadlet-nix Home Manager module
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      # Home Manager state version
      home.stateVersion = "24.11";

      # Basic home settings
      home.username = "openproject";
      home.homeDirectory = "/var/lib/containers/openproject";

      # Environment for rootless container operation
      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      # Ensure home directory structure exists
      home.file.".keep".text = "";

      # Basic packages available in container user environment
      home.packages = with pkgs; [
        podman
        coreutils
        postgresql # For pg_isready health check
      ];

      # Rootless quadlet container configuration
      virtualisation.quadlet.containers.openproject = {
        autoStart = true;

        containerConfig = {
          image = "openproject/openproject:16";
          publishPorts = [
            "127.0.0.1:8180:80/tcp" # Web interface
            "127.0.0.1:9394:9394/tcp" # Prometheus metrics
          ];

          # Rootless networking with host loopback access
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          # Environment configuration
          environments = {
            # Host configuration
            OPENPROJECT_HOST__NAME = "openproject.vulcan.lan";
            OPENPROJECT_HTTPS = "true";
            OPENPROJECT_HSTS = "true";

            # Cache configuration (external Redis on host)
            OPENPROJECT_RAILS__CACHE__STORE = "redis";
            OPENPROJECT_CACHE__REDIS__URL = "redis://host.containers.internal:6383";

            # Prometheus metrics
            OPENPROJECT_PROMETHEUS_EXPORT = "true";
            PROMETHEUS_EXPORTER_PORT = "9394";
            PROMETHEUS_EXPORTER_BIND = "0.0.0.0";

            # Language and locale
            OPENPROJECT_DEFAULT__LANGUAGE = "en";

            # Puma web server settings
            OPENPROJECT_WEB_WORKERS = "2";
            OPENPROJECT_WEB_MAX__THREADS = "8";
            OPENPROJECT_WEB_MIN__THREADS = "4";
            OPENPROJECT_WEB_TIMEOUT = "300";

            # Database connection pool settings (separate from DATABASE_URL)
            OPENPROJECT_DATABASE_POOL = "20";
          };

          # Secrets via environment files
          environmentFiles = [
            "/run/secrets-openproject/openproject-env"
          ];

          # Volume mounts for persistent data
          volumes = [
            "/var/lib/containers/openproject/assets:/var/openproject/assets:Z"
            "/var/lib/containers/openproject/tmp:/tmp:Z"
            # Mount CA certificate for PostgreSQL SSL verification (at libpq default location)
            "/etc/ssl/certs/step-ca/root_ca.crt:/var/lib/postgresql/.postgresql/root.crt:ro"
          ];
        };

        unitConfig = {
          After = [ "network-online.target" ];
          Description = "OpenProject project management container";

          # Restart rate limiting
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          # Wait for PostgreSQL to be ready
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do ${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 2 && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; exit 1'";

          # Restart policies
          Restart = "always";
          RestartSec = "15s";
          TimeoutStartSec = "900"; # OpenProject can take a while to start on first run

          # NO LogLevelMax here -- it does not work for container output, and a
          # setting that looks like a working mitigation is worse than none.
          #
          # `LogLevelMax = "warning"` sat here claiming to "filter out info-level
          # HTTP access logs" and to save ~4,200 lines/day. Measured 2026-08-13
          # over a 4h window, with that setting live and effective on the unit
          # (systemctl show -p LogLevelMax returned 4):
          #     prio 3 err      240
          #     prio 5 notice    15
          #     prio 6 info    1334
          # Nothing was being filtered. LogLevelMax caps messages systemd itself
          # relays from the stream it manages, but podman's default journald log
          # driver has conmon write to journald DIRECTLY -- the records carry
          # _COMM=conmon, SYSLOG_IDENTIFIER=openproject and never pass through
          # this unit's StandardOutput, so the cap has nothing to act on.
          #
          # What WOULD work, if the volume ever justifies it:
          #   - LogDriver=passthrough on the quadlet, which routes container
          #     output back through the unit's stdout/stderr and so back under
          #     LogLevelMax -- at the cost of `podman logs` no longer working;
          #   - a journald/promtail drop rule keyed on the access-line shape.
          # Both are deliberate observability trade-offs, so neither is applied
          # here on spec. See obr nixos-t2q.
        };
      };
    };
}
