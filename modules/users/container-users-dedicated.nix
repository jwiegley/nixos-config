{ config, lib, pkgs, ... }:

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
    groups.podman = {};

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

      nocobase = {
        isSystemUser = true;
        group = "nocobase";
        home = "/var/lib/containers/nocobase";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for NocoDB database service";
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

      # Web services (formerly container-web)
      sillytavern = {
        isSystemUser = true;
        group = "sillytavern";
        home = "/var/lib/containers/sillytavern";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for SillyTavern AI chat service";
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
        extraGroups = [ "podman" "technitium-readers" ];
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
    };

    # Create corresponding groups for each container user
    groups = {
      litellm = {};
      nocobase = {};
      wallabag = {};
      teable = {};
      sillytavern = {};
      opnsense-exporter = {};
      technitium-dns-exporter = {};
      openspeedtest = {};
      changedetection = {};
      mailarchiver = {};
      openproject = {};
      podman = {};
    };
  };

  # Add container users to Nix allowed-users for store access and container image operations
  nix.settings.allowed-users = [
    "changedetection"
    "litellm"
    "mailarchiver"
    "nocobase"
    "openproject"
    "wallabag"
    "teable"
    "sillytavern"
    "opnsense-exporter"
    "technitium-dns-exporter"
    "openspeedtest"
  ];

  # Grant full Nix daemon access to wheel group (admin users like johnw)
  # This allows home-manager and other user tools to access the Nix store
  nix.settings.trusted-users = [ "root" "@wheel" ];

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
    "d /run/secrets-nocobase 0750 nocobase nocobase - -"
    "L+ /run/secrets-nocobase/nocobase - - - - /run/secrets/nocobase"
    "d /run/secrets-wallabag 0750 wallabag wallabag - -"
    "L+ /run/secrets-wallabag/wallabag - - - - /run/secrets/wallabag"
    "d /run/secrets-teable 0750 teable teable - -"
    "L+ /run/secrets-teable/teable - - - - /run/secrets/teable"
    "d /run/secrets-sillytavern 0750 sillytavern sillytavern - -"
    "L+ /run/secrets-sillytavern/sillytavern - - - - /run/secrets/sillytavern"
    "d /run/secrets-opnsense-exporter 0750 opnsense-exporter opnsense-exporter - -"
    "L+ /run/secrets-opnsense-exporter/opnsense-exporter - - - - /run/secrets/opnsense-exporter"
    "d /run/secrets-technitium-dns-exporter 0750 technitium-dns-exporter technitium-dns-exporter - -"
    "L+ /run/secrets-technitium-dns-exporter/technitium-dns-exporter - - - - /run/secrets/technitium-dns-exporter"
    "d /run/secrets-openspeedtest 0750 openspeedtest openspeedtest - -"
    "L+ /run/secrets-openspeedtest/openspeedtest - - - - /run/secrets/openspeedtest"
    "d /run/secrets-openproject 0750 openproject openproject - -"
    "L+ /run/secrets-openproject/openproject - - - - /run/secrets/openproject"
  ];
}
