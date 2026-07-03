{
  config,
  lib,
  pkgs,
  ...
}:

{
  users = {
    groups.rbcca = {
      gid = 1013;
    };

    users.rbcca = {
      isNormalUser = true;
      uid = 1013;
      group = "rbcca";
      home = "/home/rbcca";
      description = "RBCCA mirror user (jwiegley@rbcca.org)";
    };
  };
}
