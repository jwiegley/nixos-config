{
  config,
  lib,
  pkgs,
  ...
}:

{
  users = {
    groups.bia = {
      gid = 1012;
    };

    users.bia = {
      isNormalUser = true;
      uid = 1012;
      group = "bia";
      home = "/home/bia";
      description = "BIA mirror user (john@bia.bahai.org)";
    };
  };
}
