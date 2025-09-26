{ config, lib, pkgs, ... }:

{
  imports = [
    # Use fixed quadlet configuration with proper network setup
    ./quadlet.nix

    # Keep secure-nginx as it may have other configurations
    ./secure-nginx.nix
  ];
}
