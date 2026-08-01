# Container Users Home Manager Configuration
#
# This file is intentionally empty - all container users now have their own
# dedicated Home Manager modules in this directory (e.g., wallabag.nix, teable.nix).
#
# The system user definitions are in /etc/nixos/modules/users/container-users-dedicated.nix

{
  config,
  lib,
  pkgs,
  ...
}:

{
  # All container users have individual Home Manager modules
  # See: wallabag.nix, teable.nix, changedetection.nix, etc.
}
