{ config, lib, pkgs, ... }:

{
  users = {
    groups.assembly = {
      gid = 1011;
    };

    users.assembly = {
      isNormalUser = true;
      uid = 1011;
      group = "assembly";
      home = "/home/assembly";
      description = "Assembly user";
    };
  };
}
