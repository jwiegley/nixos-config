{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Dirscan share service - monitor source and copy files to destination with
  # proper ownership
  services.dirscan-share = {
    enable = true;
    sourceDir = "/home/johnw/share";
    destinationDir = "/tank/Public/share";
    user = "root";
    group = "root";
    sourceOwner = "johnw";
    sourceGroup = "johnw";
    destinationOwner = "johnw";
    destinationGroup = "johnw";
    extraArgs = [ "-v" ];
  };
}
