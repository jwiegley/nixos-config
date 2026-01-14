{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # Use fixed quadlet configuration with proper network setup
    ./quadlet.nix

    # Separate containers for copyparty and static nginx
    ./copyparty-container.nix
    ./static-nginx-container.nix
  ];
}
