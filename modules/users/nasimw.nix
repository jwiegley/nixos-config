{
  config,
  lib,
  pkgs,
  ...
}:

{
  users = {
    groups.nasimw = {
      gid = 991;
    };

    users.nasimw = {
      uid = 1001;
      isNormalUser = true;
      description = "Nasim Wiegley";
      group = "nasimw";
      extraGroups = [ ];
      home = "/home/nasimw";
      shell = pkgs.bash;
      packages = with pkgs; [ ];
    };
  };
}
