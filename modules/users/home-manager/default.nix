{
  config,
  lib,
  inputs,
  utils,
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

  # Restart each Home Manager activation oneshot on transient failure.
  #
  # The user set is DERIVED from config.home-manager.users so it can NEVER drift:
  # a hand-maintained list previously rotted — decommissioned names produced
  # ExecStart-less "bad-setting" units, and real users were silently omitted
  # (9 listed vs 14 actual as of 2026-06-01).
  #
  # The unit name MUST be escaped the way home-manager names it — its NixOS module
  # uses "home-manager-${utils.escapeSystemdPath name}". Keying by the RAW username
  # makes hyphenated users (open-webui, opnsense-exporter, shlink-web-client, ...)
  # miss the real escaped unit ("home-manager-open\x2dwebui") and fabricate a
  # phantom bad-setting unit instead of merging — so Restart never reached them.
  #
  # nix-daemon ordering is intentionally NOT re-stated here: home-manager already
  # sets after/wants = [ "nix-daemon.socket" ] on every user unit unconditionally,
  # and NIX_REMOTE=daemon is redundant (the oneshot runs as the user and reaches
  # the active nix-daemon.socket regardless). Both verified on this host 2026-06-01.
  systemd.services = lib.mkMerge (
    map (username: {
      "home-manager-${utils.escapeSystemdPath username}" = {
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    }) (lib.attrNames config.home-manager.users)
  );

  # Guard the invariant the override relies on: home-manager names each activation
  # unit after the user's home.username, while we derive the name from the attr
  # key. They are equal for every user today; if anyone later sets a divergent
  # users.users.<name>.name / home.username, fail loudly at eval rather than
  # silently resurrecting the phantom-unit bug.
  assertions = lib.mapAttrsToList (name: userCfg: {
    assertion = userCfg.home.username == name;
    message =
      "home-manager user '${name}' has home.username='${userCfg.home.username}'. "
      + "The nix-daemon Restart override in modules/users/home-manager/default.nix "
      + "derives the systemd unit name from the attr key, which only matches "
      + "home-manager's own naming when key == home.username. Align them or rework "
      + "the derivation.";
  }) config.home-manager.users;
}
