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

      mindsdb = {
        isSystemUser = true;
        group = "mindsdb";
        home = "/var/lib/containers/mindsdb";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for MindsDB ML service";
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

      paperless-ai = {
        isSystemUser = true;
        group = "paperless-ai";
        home = "/var/lib/containers/paperless-ai";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for Paperless AI service";
      };
    };

    # Create corresponding groups for each container user
    groups = {
      litellm = {};
      mindsdb = {};
      nocobase = {};
      wallabag = {};
      teable = {};
      sillytavern = {};
      opnsense-exporter = {};
      technitium-dns-exporter = {};
      openspeedtest = {};
      paperless-ai = {};
      podman = {};
    };
  };

  # Add container users to Nix allowed-users for store access and container image operations
  nix.settings.allowed-users = [
    "changedetection"
    "litellm"
    "mindsdb"
    "nocobase"
    "wallabag"
    "teable"
    "sillytavern"
    "opnsense-exporter"
    "technitium-dns-exporter"
    "openspeedtest"
    "paperless-ai"
  ];

  # Grant full Nix daemon access to wheel group (admin users like johnw)
  # This allows home-manager and other user tools to access the Nix store
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # Create per-user SOPS secrets directories with proper ownership and permissions
  # These directories are used for deploying user-specific secrets via SOPS
  # Permissions: 0750 (owner: rwx, group: r-x, others: ---)
  # This allows the user to read/write secrets, group members to list, and prevents other users from accessing
  systemd.tmpfiles.rules = [
    "d /run/secrets-litellm 0750 litellm litellm - -"
    "d /run/secrets-mindsdb 0750 mindsdb mindsdb - -"
    "d /run/secrets-nocobase 0750 nocobase nocobase - -"
    "d /run/secrets-wallabag 0750 wallabag wallabag - -"
    "d /run/secrets-teable 0750 teable teable - -"
    "d /run/secrets-sillytavern 0750 sillytavern sillytavern - -"
    "d /run/secrets-opnsense-exporter 0750 opnsense-exporter opnsense-exporter - -"
    "d /run/secrets-technitium-dns-exporter 0750 technitium-dns-exporter technitium-dns-exporter - -"
    "d /run/secrets-openspeedtest 0750 openspeedtest openspeedtest - -"
    "d /run/secrets-paperless-ai 0750 paperless-ai paperless-ai - -"
  ];
}
