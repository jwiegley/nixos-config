# programs.starship.presets — compatibility shim (Home Manager sharedModule)
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-18 every rebuild of this host started failing at evaluation:
#
#   error: The option `home-manager.users.johnw.programs.starship.presets'
#   does not exist. Definition values: [ "nerd-font-symbols" ]
#
# `programs.starship.presets` is a Home Manager option that exists on MASTER but
# not on release-25.11, which this host pins (rev 3ee51fbdac8c — and that branch
# has not moved since 2026-05-23, so waiting for it is not an option).
#
# The trigger was NOT a new feature appearing in nix-config. The setting had
# been in config/johnw.nix since 2026-03-13; what changed was its FORM. Up to
# nix-config 66eaf03e it was hand-rolled, and worked against any Home Manager:
#
#     starship = {
#       enable = true;
#       settings = lib.mkMerge [
#         (builtins.fromTOML (builtins.readFile
#            "${pkgs.starship}/share/starship/presets/nerd-font-symbols.toml"))
#         { ... }
#       ];
#     };
#
# nix-config 7e92da92 refactored that into `presets = [ "nerd-font-symbols" ];`,
# adopting the newer upstream option. That is correct for nix-config's own
# targets, which track a newer Home Manager — it is only vulcan, pinned to
# 25.11, that cannot parse it.
#
# This is the SAME STRUCTURAL HAZARD as nixos-sil (2026-08-15): vulcan consumes
# nix-config with `flake = false`, so nix-config's own input versions never
# apply here, and any API it adopts from a newer Home Manager lands on this host
# as an eval error with no local cause. Both incidents took the host down
# completely — nothing could be rebuilt until it was resolved.
#
# WHAT THIS DOES
# --------------
# Declares the option and implements it exactly as nix-config used to, by
# reading the preset TOML out of the starship package and merging it into
# settings. This is a behaviour-preserving translation, NOT a no-op stub: a stub
# would evaluate fine and silently drop the nerd-font symbols from the prompt,
# which is the kind of quiet regression that gets found weeks later.
#
# The readFile-on-a-store-path is import-from-derivation, which is already
# proven acceptable in this exact position — it is precisely what the previous
# nix-config code did on this host for five months.
#
# mkAfter places preset values BEFORE the user's own settings in the merge
# order, so an explicit setting in johnw.nix still wins over a preset default.
# That matches the old code, where the preset was the first element of the
# mkMerge list.
#
# REMOVING THIS
# -------------
# Delete it when either becomes true:
#   * nix-config stops using `presets` (reverting that one refactor, or guarding
#     it on the option existing), or
#   * this host moves to a Home Manager that defines the option itself.
#
# The second case will FAIL LOUDLY rather than silently double-define: two
# declarations of the same option is an eval error naming this file. That is
# intentional — a loud failure at the moment of a deliberate Home Manager bump
# is much better than a shim quietly shadowing upstream's own implementation.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.starship;
in
{
  options.programs.starship.presets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "nerd-font-symbols" ];
    description = ''
      Starship preset names to merge into {option}`programs.starship.settings`.
      Each name must match a TOML file shipped in
      `''${pkgs.starship}/share/starship/presets/`.

      Compatibility shim for Home Manager release-25.11, which does not carry
      upstream's own `presets` option. See the comment at the top of
      modules/users/home-manager/starship-presets-compat.nix.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.presets != [ ]) {
    # Fail at eval with a readable message rather than a bare readFile ENOENT
    # buried in a stack trace, which is what a typo in a preset name would
    # otherwise produce.
    assertions = map (preset: {
      assertion = builtins.pathExists "${cfg.package}/share/starship/presets/${preset}.toml";
      message =
        "programs.starship.presets: no preset named '${preset}' in "
        + "${cfg.package}/share/starship/presets/. Available: "
        + lib.concatStringsSep ", " (
          map (lib.removeSuffix ".toml") (
            builtins.attrNames (builtins.readDir "${cfg.package}/share/starship/presets")
          )
        );
    }) cfg.presets;

    programs.starship.settings = lib.mkAfter (
      lib.foldl' lib.recursiveUpdate { } (
        map (
          preset: builtins.fromTOML (builtins.readFile "${cfg.package}/share/starship/presets/${preset}.toml")
        ) cfg.presets
      )
    );
  };
}
