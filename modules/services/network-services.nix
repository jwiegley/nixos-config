{ config, lib, pkgs, ... }:

{
  services = {
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    fail2ban.enable = false;
  };
}
