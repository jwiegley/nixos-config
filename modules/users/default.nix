{ config, lib, pkgs, ... }:

{
  users = {
    groups.container-data = {
      gid = 1010;
    };

    users.container-data = {
      isSystemUser = true;
      uid = 1010;
      group = "container-data";
    };
  };
}