# Container Users Home Manager Configuration
#
# This file is intentionally empty - all container users now have their own
# dedicated Home Manager modules in this directory (e.g., litellm.nix, shlink.nix).
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
  # See: litellm.nix, shlink.nix, changedetection.nix, etc.
}
