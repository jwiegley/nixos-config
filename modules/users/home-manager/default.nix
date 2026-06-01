{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager = {
    # Use the same nixpkgs as the system
    useGlobalPkgs = true;

    # Install packages to /etc/profiles instead of ~/.nix-profile
    useUserPackages = true;

    # Backup existing files when they conflict with home-manager files
    backupFileExtension = "hm-bak";

    # Applied to every Home Manager user. The prune module self-targets only the
    # rootless container users (home dir under /var/lib/containers/), closing the
    # gap left by the root-level virtualisation.podman.autoPrune which never sees
    # per-user rootless stores. See ./rootless-podman-image-prune.nix.
    sharedModules = [
      ./rootless-podman-image-prune.nix
    ];

    # Pass hostname and inputs to home-manager modules so they can be used
    # by the shared johnw.nix cross-platform module
    extraSpecialArgs = {
      hostname = config.networking.hostName;
      inherit inputs;
    };
  };

  # Fix Home Manager services to wait for nix-daemon
  # This prevents "Connection reset by peer" errors during activation
  systemd.services = lib.mkMerge (
    map
      (username: {
        "home-manager-${username}" = {
          after = [ "nix-daemon.socket" ];
          wants = [ "nix-daemon.socket" ];
          serviceConfig = {
            # Restart on failure to handle transient nix-daemon issues
            Restart = "on-failure";
            RestartSec = "5s";
          };
          environment = {
            # Ensure the service can connect to nix-daemon
            NIX_REMOTE = "daemon";
          };
        };
      })
      # Only users with a live, imported Home Manager config belong here. Names of
      # decommissioned users (technitium-dns-exporter, reverted to a system-level
      # container; the retired container-db/web/misc/monitor shared-user scheme)
      # were removed 2026-06-01 — they had no HM module to attach to, so the
      # override produced ExecStart-less "bad-setting" units that systemd refused
      # to start and that logged noise on every switch.
      [
        "changedetection"
        "litellm"
        "open-webui"
        "vane"
        "wallabag"
        "teable"
        "opnsense-exporter"
        "openspeedtest"
        "johnw"
      ]
  );
}
