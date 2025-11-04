{ config, lib, pkgs, ... }:

{
  # Dirscan share service - monitor /tank/Nextcloud/johnw/files/share
  # and copy files to /tank/Public/share with proper ownership
  services.dirscan-share = {
    enable = true;
    sourceDir = "/tank/Nextcloud/johnw/files/share";
    destinationDir = "/tank/Public/share";
    user = "root";
    group = "root";
    destinationOwner = "johnw";
    destinationGroup = "johnw";
    extraArgs = [ "-v" ];
  };
}
