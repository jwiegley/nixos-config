{ config, lib, pkgs, ... }:

{
  services = {
    eternal-terminal.enable = true;

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    fail2ban = {
      enable = true;
      jails.sshd.settings = {
        enabled = true;
        maxretry = 10;        # Allow up to 10 failed attempts
        findtime = 3600;      # Count failures within an hour (3600 seconds)
        bantime = "24h";      # Ban for one day
        backend = "systemd";  # Use systemd journal (works best on NixOS)
      };
    };
  };
}
