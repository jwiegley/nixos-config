{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # Podman quadlet container modules plus podman network/storage setup
    ./quadlet.nix

    # Separate containers for copyparty and static nginx
    ./copyparty-container.nix
    ./static-nginx-container.nix
  ];
}
