{
  config,
  lib,
  pkgs,
  hostRegistry,
  ...
}:

let
  account = hostRegistry.userAccounts.vulcan.bia;
in
{
  users = {
    groups.${account.username} = {
      gid = account.gid;
    };

    users.${account.username} = {
      isNormalUser = true;
      uid = account.uid;
      group = account.username;
      home = account.homeDirectory;
      description = "BIA mirror user (john@bia.bahai.org)";
    };
  };
}
