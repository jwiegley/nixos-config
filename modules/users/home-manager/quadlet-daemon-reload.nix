# Quadlet generator refresh (Home Manager sharedModule)
#
# WHY THIS EXISTS
# ---------------
# quadlet-nix writes the `.container` file and an [Install]-only stub into
# ~/.config/systemd/user/default.target.wants/, then symlinks
# ~/.config/quadlet-nix/out at the user manager's generator directory. What it
# does NOT do is reload the user manager -- verified 2026-08-16 by grepping the
# generated activation script, where `daemon-reload` appears zero times while the
# quadletNix step is present at lines 302-304.
#
# The real unit behind that stub is produced by podman's quadlet GENERATOR, and
# generators only run on a daemon-reload. So on the switch that FIRST introduces a
# container, the stub exists but nothing stands behind it, and systemd reports:
#
#   Failed to start <name>.service: Unit <name>.service has a bad unit file setting.
#
# Hit while enabling NocoBase (nixos-yfp). The .container file was correct and
# byte-comparable to wallabag's; a manual `systemctl --user daemon-reload` as that
# user cleared it instantly (LoadState went to loaded with no LoadError) and the
# container started. It is not a persistent defect -- on the next BOOT the
# generator runs before targets are reached, so the container comes up normally --
# which is why this only bites the first activation and why it is worth exactly
# this much code and no more.
#
# MECHANISM
# ---------
# Installed into every Home Manager user via `home-manager.sharedModules` (see
# ./default.nix), and self-gating: the activation block is only emitted for users
# that actually declare quadlet containers, so it applies to the eight container
# users and never to johnw. No list to keep in sync -- the same self-targeting
# approach ./rootless-podman-image-prune.nix uses.
#
# Ordered after quadlet-nix's own step by depending on "quadletNix", so the
# generator sees the .container file that step just placed.
{
  config,
  lib,
  ...
}:

lib.mkIf (config.virtualisation.quadlet.containers or { } != { }) {
  home.activation.quadletDaemonReload = lib.hm.dag.entryAfter [ "quadletNix" ] ''
    # Best-effort by design. During the very first activation for a brand-new
    # user the manager may not be up yet, and a boot-time activation may run
    # before the session exists; in both cases the generator runs on its own
    # afterwards, so failing activation here would be strictly worse than doing
    # nothing. Hence the guard plus `|| true`.
    if [ -d "''${XDG_RUNTIME_DIR:-/run/user/$UID}/systemd" ]; then
      $DRY_RUN_CMD systemctl --user daemon-reload || true
    fi
  '';
}
