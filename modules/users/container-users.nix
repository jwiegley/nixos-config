{ config, lib, pkgs, ... }:

{
  # Create dedicated container users for rootless Podman operations
  # Each user manages a specific category of containers:
  # - container-db: Database-dependent services (litellm, metabase, wallabag, etc.)
  # - container-web: Web services (changedetection, openspeedtest, silly-tavern)
  # - container-monitor: Monitoring services (opnsense-exporter, technitium-dns-exporter)
  # - container-misc: Miscellaneous services

  users = {
    # Ensure podman group exists for container management
    groups.podman = {};

    users = {
      container-db = {
        isSystemUser = true;
        group = "container-db";
        home = "/var/lib/containers/container-db";
        createHome = true;
        shell = pkgs.bash;
        # Enable automatic subuid/subgid range allocation for user namespaces
        autoSubUidGidRange = true;
        # Enable lingering to allow systemd user services to run without login
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for database-dependent services";
      };

      container-web = {
        isSystemUser = true;
        group = "container-web";
        home = "/var/lib/containers/container-web";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for web services";
      };

      container-monitor = {
        isSystemUser = true;
        group = "container-monitor";
        home = "/var/lib/containers/container-monitor";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for monitoring services";
      };

      container-misc = {
        isSystemUser = true;
        group = "container-misc";
        home = "/var/lib/containers/container-misc";
        createHome = true;
        shell = pkgs.bash;
        autoSubUidGidRange = true;
        linger = true;
        extraGroups = [ "podman" ];
        description = "Container user for miscellaneous services";
      };
    };

    # Create corresponding groups for each container user
    groups = {
      container-db = {};
      container-web = {};
      container-monitor = {};
      container-misc = {};
      podman = {};
    };
  };

  # Add container users to Nix allowed-users for store access and container image operations
  nix.settings.allowed-users = [
    "container-db"
    "container-web"
    "container-monitor"
    "container-misc"
  ];

  # Create per-user SOPS secrets directories with proper ownership and permissions
  # These directories are used for deploying user-specific secrets via SOPS
  # Permissions: 0750 (owner: rwx, group: r-x, others: ---)
  # This allows the user to read/write secrets, group members to list, and prevents other users from accessing
  systemd.tmpfiles.rules = [
    "d /run/secrets-container-db 0750 container-db container-db - -"
    "d /run/secrets-container-web 0750 container-web container-web - -"
    "d /run/secrets-container-monitor 0750 container-monitor container-monitor - -"
    "d /run/secrets-container-misc 0750 container-misc container-misc - -"
  ];
}
