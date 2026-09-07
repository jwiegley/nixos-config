{
  config,
  lib,
  pkgs,
  hostRegistry,
  ...
}:

let
  account = hostRegistry.userAccounts.vulcan.nasimw;
in
{
  users = {
    groups.${account.username} = {
      gid = account.gid;
    };

    users.${account.username} = {
      uid = account.uid;
      isNormalUser = true;
      description = "Nasim Wiegley";
      group = account.username;
      extraGroups = [ ];
      home = account.homeDirectory;
      shell = pkgs.bash;
      packages = with pkgs; [ ];
    };
  };
}
