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
  # User naming: Matches service name (e.g., litellm service → litellm user)
  # Home directory: /var/lib/containers/<service-name>

  users = {
    # Ensure podman group exists for container management
    groups.podman = { };

    users = {
      # Database-dependent services (formerly container-db)
      litellm = {
        isSystemUser = true;
        group = "litellm";
        home = "/var/lib/containers/litellm";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for LiteLLM proxy service";
      };

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

      teable = {
        isSystemUser = true;
        group = "teable";
        home = "/var/lib/containers/teable";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Teable database service";
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

      perplexica = {
        isSystemUser = true;
        group = "perplexica";
        home = "/var/lib/containers/perplexica";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Perplexica AI search engine";
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
      litellm = { };
      wallabag = { };
      teable = { };
      opnsense-exporter = { };
      technitium-dns-exporter = { };
      openspeedtest = { };
      changedetection = { };
      mailarchiver = { };
      openproject = { };
      shlink = { };
      shlink-web-client = { };
      open-webui = { };
      perplexica = { };
      speedtest-tracker = { };
      podman = { };
    };
  };

  # Add container users to Nix allowed-users for store access and container image operations
  nix.settings.allowed-users = [
    "changedetection"
    "litellm"
    "mailarchiver"
    "open-webui"
    "openproject"
    "perplexica"
    "shlink"
    "shlink-web-client"
    "wallabag"
    "teable"
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
  # These directories are used for deploying user-specific secrets via SOPS
  # Permissions: 0750 (owner: rwx, group: r-x, others: ---)
  # This allows the user to read/write secrets, group members to list, and prevents other users from accessing
  #
  # Symlinks are created to make SOPS secrets (in /run/secrets/<service>/) accessible
  # to user services as /run/secrets-<service>/<service>/ for container environmentFiles
  systemd.tmpfiles.rules = [
    "d /run/secrets-changedetection 0750 changedetection changedetection - -"
    "L+ /run/secrets-changedetection/changedetection - - - - /run/secrets/changedetection"
    "d /run/secrets-litellm 0750 litellm litellm - -"
    "L+ /run/secrets-litellm/litellm - - - - /run/secrets/litellm"
    "d /run/secrets-mailarchiver 0750 mailarchiver mailarchiver - -"
    "L+ /run/secrets-mailarchiver/mailarchiver - - - - /run/secrets/mailarchiver"
    "d /run/secrets-wallabag 0750 wallabag wallabag - -"
    "L+ /run/secrets-wallabag/wallabag - - - - /run/secrets/wallabag"
    "d /run/secrets-teable 0750 teable teable - -"
    "L+ /run/secrets-teable/teable - - - - /run/secrets/teable"
    "d /run/secrets-opnsense-exporter 0750 opnsense-exporter opnsense-exporter - -"
    "L+ /run/secrets-opnsense-exporter/opnsense-exporter - - - - /run/secrets/opnsense-exporter"
    "d /run/secrets-technitium-dns-exporter 0750 technitium-dns-exporter technitium-dns-exporter - -"
    "L+ /run/secrets-technitium-dns-exporter/technitium-dns-exporter - - - - /run/secrets/technitium-dns-exporter"
    "d /run/secrets-openspeedtest 0750 openspeedtest openspeedtest - -"
    "L+ /run/secrets-openspeedtest/openspeedtest - - - - /run/secrets/openspeedtest"
    "d /run/secrets-openproject 0750 openproject openproject - -"
    "L+ /run/secrets-openproject/openproject - - - - /run/secrets/openproject"
    "d /run/secrets-shlink 0750 shlink shlink - -"
    "L+ /run/secrets-shlink/shlink - - - - /run/secrets/shlink"
    "d /run/secrets-shlink-web-client 0750 shlink-web-client shlink-web-client - -"
    "L+ /run/secrets-shlink-web-client/shlink-web-client - - - - /run/secrets/shlink-web-client"
    "d /run/secrets-open-webui 0750 open-webui open-webui - -"
    "L+ /run/secrets-open-webui/open-webui-secrets - - - - /run/secrets/open-webui-secrets"
    "d /run/secrets-speedtest-tracker 0750 speedtest-tracker speedtest-tracker - -"
    "L+ /run/secrets-speedtest-tracker/speedtest-tracker-secrets - - - - /run/secrets/speedtest-tracker-secrets"
  ];
  # Note: perplexica currently has no SOPS secrets (configured via web UI)
  # Add secret entries here if/when API keys are managed via SOPS
}
