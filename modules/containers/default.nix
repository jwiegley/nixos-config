{ config, lib, pkgs, ... }:

{
  imports = [
    ./litellm.nix
    ./organizr.nix
    ./silly-tavern.nix
    ./wallabag.nix
    ./secure-nginx.nix
  ];

  virtualisation.podman = {
    enable = true;
    autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
  };
}
