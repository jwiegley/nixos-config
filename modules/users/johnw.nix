{ config, lib, pkgs, ... }:

let
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAj2IzkXyXEl+ReCg9H+t55oa6GIiumPWeufcYCWy3F yubikey-gnupg"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAING2r8bns7h9vZIfZSGsX+YmTSe2Tv1X8f/Qlqo+RGBb yubikey-14476831-gnupg"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPvP6nhCLyJLa2LsXLVYN1lbGHfv/ZL+Rt/y3Ao/hfGz Clio"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJmBoRIHfrT5RfCh1qyJP+aRwH6zpKJKv8KSk+1Rj8N0 Hera"
  ];
in
{
  users = {
    groups.johnw = {
      gid = 990;
    };

    users.johnw = {
      uid = 1000;
      isNormalUser = true;
      description = "John Wiegley";
      group = "johnw";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = authorizedKeys;
      home = "/home/johnw";
      shell = pkgs.zsh;
      # Packages that need to be available during system boot or are not
      # managed by home-manager are kept here. User-specific packages
      # are now managed through home-manager configuration.
      packages = with pkgs; [];
    };
  };

  # Fix home-manager service boot failure by ensuring nix-daemon is running
  # before home-manager activation attempts to use it
  systemd.services.home-manager-johnw = {
    after = [ "nix-daemon.service" ];
    wants = [ "nix-daemon.service" ];
  };
}
