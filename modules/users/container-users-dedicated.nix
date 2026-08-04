{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Create dedicated container users for rootless Podman operations
  # Each service runs under its own isolated user account for maximum security separation
  #
  # Migration from previous shared-user model (container-db, container-web, etc.)
  # to per-service dedicated users for improved security isolation.
  #
  # User naming: Matches service name (e.g., wallabag service → wallabag user)
  # Home directory: /var/lib/containers/<service-name>

  users = {
    # Ensure podman group exists for container management
    groups.podman = { };

    users = {
      # Database-dependent services (formerly container-db)
      wallabag = {
        isSystemUser = true;
        group = "wallabag";
        home = "/var/lib/containers/wallabag";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Wallabag read-it-later service";
      };

      memory-vault = {
        isSystemUser = true;
        group = "memory-vault";
        home = "/var/lib/containers/memory-vault";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Memory Vault AI memory service";
      };

      # Monitoring services (formerly container-monitor)
      opnsense-exporter = {
        isSystemUser = true;
        group = "opnsense-exporter";
        home = "/var/lib/containers/opnsense-exporter";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for OPNsense Prometheus exporter";
      };

      technitium-dns-exporter = {
        isSystemUser = true;
        group = "technitium-dns-exporter";
        home = "/var/lib/containers/technitium-dns-exporter";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [
          "podman"
          "technitium-readers"
        ];
        description = "Container user for Technitium DNS Prometheus exporter";
      };

      # Miscellaneous services (formerly container-misc)
      openspeedtest = {
        isSystemUser = true;
        group = "openspeedtest";
        home = "/var/lib/containers/openspeedtest";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for OpenSpeedTest service";
      };

      changedetection = {
        isSystemUser = true;
        group = "changedetection";
        home = "/var/lib/containers/changedetection";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for ChangeDetection.io service";
      };

      mailarchiver = {
        isSystemUser = true;
        group = "mailarchiver";
        home = "/var/lib/containers/mailarchiver";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Mail Archiver service";
      };

      openproject = {
        isSystemUser = true;
        group = "openproject";
        home = "/var/lib/containers/openproject";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for OpenProject project management";
      };

      shlink = {
        isSystemUser = true;
        group = "shlink";
        home = "/var/lib/containers/shlink";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Shlink URL shortener";
      };

      shlink-web-client = {
        isSystemUser = true;
        group = "shlink-web-client";
        home = "/var/lib/containers/shlink-web-client";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Shlink Web Client";
      };

      open-webui = {
        isSystemUser = true;
        group = "open-webui";
        home = "/var/lib/containers/open-webui";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Open WebUI AI chat interface";
      };

      vane = {
        isSystemUser = true;
        group = "vane";
        home = "/var/lib/containers/vane";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Vane AI answering engine";
      };

      speedtest-tracker = {
        isSystemUser = true;
        group = "speedtest-tracker";
        home = "/var/lib/containers/speedtest-tracker";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Speedtest Tracker service";
      };

    };

    # Create corresponding groups for each container user
    groups = {
      wallabag = { };
      memory-vault = { };
      opnsense-exporter = { };
      technitium-dns-exporter = { };
      openspeedtest = { };
      changedetection = { };
      mailarchiver = { };
      openproject = { };
      shlink = { };
      shlink-web-client = { };
      open-webui = { };
      vane = { };
      speedtest-tracker = { };
      podman = { };
    };
  };

  # Add container users to Nix allowed-users for store access and container image operations
  nix.settings.allowed-users = [
    "changedetection"
    "mailarchiver"
    "memory-vault"
    "open-webui"
    "openproject"
    "vane"
    "shlink"
    "shlink-web-client"
    "wallabag"
    "opnsense-exporter"
    "technitium-dns-exporter"
    "openspeedtest"
    "speedtest-tracker"
  ];

  # Grant full Nix daemon access to wheel group (admin users like johnw)
  # This allows home-manager and other user tools to access the Nix store
  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  # Create per-user SOPS secrets directories with proper ownership and permissions
  # These directories are used for deploying user-specific secrets via SOPS.
  # Permissions: 0750 (owner: rwx, group: r-x, others: ---) — the container user
  # reads its own secrets, group members may list, everyone else is shut out.
  #
  # These `d` rules are the ONLY thing this module contributes to secret exposure.
  # The secrets themselves are placed inside these directories by exactly one
  # mechanism: a sops `path = "/run/secrets-<user>/<secret>"` override, either
  # written out by modules/lib/mkQuadletService.nix (see its `sops.secrets` block)
  # or spelled out in the service's own module. sops-nix creates a
  # user-owned symlink at `path` pointing at the real /run/secrets/<secret> file.
  #
  # A second, competing mechanism used to live here: 13 `L+` tmpfiles symlink rules
  # of the form `L+ /run/secrets-<user>/<name> -> /run/secrets/<name>`. They were
  # removed on 2026-07-29 after a per-path audit against the live system (names,
  # ownership and stat only; no secret contents read). Per path:
  #   - 3 were exact duplicates of a sops `path=` override that names the very same
  #     path, and sops had already won: the live symlink was owned by the service
  #     user, not root. shlink-web-client (modules/containers/shlink-quadlet.nix),
  #     open-webui-secrets (open-webui-quadlet.nix), speedtest-tracker-secrets
  #     (speedtest-tracker-quadlet.nix). Those overrides remain and are unchanged.
  #   - 9 had no consumer anywhere — not in any unit, --env-file, EnvironmentFile,
  #     LoadCredential or volume mount under /etc/systemd or the rootless users'
  #     ~/.config: mailarchiver, wallabag, opnsense-exporter,
  #     technitium-dns-exporter, openspeedtest, openproject, shlink. Seven of the
  #     nine dangled outright (target did not exist); each of those services reaches
  #     its secret by a sibling sops `path=` file instead (
  #     …/mailarchiver-env, …/wallabag-secrets,
  #     …/opnsense-exporter-secrets, …/openproject-env, …/shlink-secrets), while
  #     technitium-dns-exporter reads /run/secrets/technitium-dns-exporter-env
  #     directly and openspeedtest has no secrets at all.
  #   - 1 was genuinely load-bearing: changedetection consumed
  #     /run/secrets-changedetection/changedetection/api-key through the symlink.
  #     It was converted to the sops `path=` form
  #     (/run/secrets-changedetection/api-key) in
  #     modules/containers/changedetection-quadlet.nix, and its consumer in
  #     modules/users/home-manager/changedetection.nix was updated to match.
  # Do not reintroduce `L+` rules here; add a sops `path=` override instead.
  systemd.tmpfiles.rules = [
    "d /run/secrets-changedetection 0750 changedetection changedetection - -"
    "d /run/secrets-mailarchiver 0750 mailarchiver mailarchiver - -"
    "d /run/secrets-wallabag 0750 wallabag wallabag - -"
    # memory-vault: sops.templates renders /run/secrets-memory-vault/env directly,
    # so only the dir is required here.
    "d /run/secrets-memory-vault 0750 memory-vault memory-vault - -"
    "d /run/secrets-opnsense-exporter 0750 opnsense-exporter opnsense-exporter - -"
    # technitium-dns-exporter and openspeedtest have no secrets under
    # /run/secrets-<user> at all; the dirs are kept only so the convention holds if
    # one is added later.
    "d /run/secrets-technitium-dns-exporter 0750 technitium-dns-exporter technitium-dns-exporter - -"
    "d /run/secrets-openspeedtest 0750 openspeedtest openspeedtest - -"
    "d /run/secrets-openproject 0750 openproject openproject - -"
    "d /run/secrets-shlink 0750 shlink shlink - -"
    "d /run/secrets-shlink-web-client 0750 shlink-web-client shlink-web-client - -"
    "d /run/secrets-open-webui 0750 open-webui open-webui - -"
    "d /run/secrets-speedtest-tracker 0750 speedtest-tracker speedtest-tracker - -"
  ];
  # Note: vane currently has no SOPS secrets (configured via web UI)
  # Add secret entries here if/when API keys are managed via SOPS
}
