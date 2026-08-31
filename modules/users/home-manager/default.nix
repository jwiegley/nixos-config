{
  config,
  lib,
  inputs,
  utils,
  ...
}:

{
  home-manager = {
    # User profiles intentionally follow nix-config-ai's nixpkgs, the same line as Hera.
    # The NixOS module graph itself remains on the stable system nixpkgs input.
    useGlobalPkgs = false;

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
      # Reloads the user manager after quadlet-nix writes a .container file, so a
      # newly introduced container gets a real unit on the switch that creates it
      # rather than only after the next boot. Self-gates to users that declare
      # quadlet containers. See the file for the NocoBase case that motivated it.
      ./quadlet-daemon-reload.nix
      # Supplies programs.starship.presets, which nix-config adopted from a newer
      # Home Manager than this host pins. Without it NOTHING on this host can be
      # rebuilt -- see the file for the full account. Same class of breakage as
      # the rust-overlay incident described in the extraSpecialArgs note below.
      ./starship-presets-compat.nix
    ];

    # Pass hostname and inputs to home-manager modules so they can be used
    # by the shared johnw.nix cross-platform module.
    #
    # The merge mirrors what nix-config does for its own consumers, and exists
    # because vulcan does NOT get that for free. nix-config/flake.nix does:
    #
    #   portableInputs = rootInputs.nix-config-ai.lib.inputSet;
    #   inputs         = rootInputs // portableInputs;
    #
    # inside its `outputs` function -- but this host consumes nix-config with
    # `flake = false`, so that function never runs and the merge never happens.
    # Every input the shared home-manager modules reference therefore had to be
    # re-declared by hand here, which is exactly how a nix-config bump that
    # started requiring `rust-overlay` made the whole host unbuildable on
    # 2026-08-15 (nixos-sil): NOTHING could be rebuilt, and the cause was
    # invisible from this repo because nothing here had changed.
    #
    # Match upstream's `rootInputs // portableInputs` direction: portable
    # nixpkgs must win inside Home Manager so shared user configuration and
    # packages follow Hera's line. System modules retain the stable input from
    # the outer NixOS evaluation and never receive this argument set.
    #
    # Measured exposure at the time of writing (nixos-czc): only `obr` carries
    # an assertion in the shared config, and it is declared here, so this is
    # prevention rather than repair. What it buys is that the NEXT input
    # nix-config starts requiring arrives automatically instead of taking the
    # host down first.
    extraSpecialArgs = {
      hostname = config.networking.hostName;
      inputs = inputs // inputs.nix-config-ai.lib.inputSet;
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
