{ config, lib, pkgs, ... }:

{
  home-manager = {
    # Use the same nixpkgs as the system
    useGlobalPkgs = true;

    # Install packages to /etc/profiles instead of ~/.nix-profile
    useUserPackages = true;

    # Backup existing files when they conflict with home-manager files
    backupFileExtension = "hm-bak";
  };
}
