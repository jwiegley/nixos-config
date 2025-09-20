{ config, lib, pkgs, ... }:

{
  services = {
    eternal-terminal.enable = true;

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "yes";
      };
    };

    postfix = {
      enable = true;
      settings.main = {
        mynetworks = [
          "192.168.1.0/24"
          "10.6.0.0/24"
          "127.0.0.0/8"
        ];
        relayhost = [ "[smtp.fastmail.com]:587" ];
        smtp_use_tls = "yes";
        smtp_sasl_auth_enable = "yes";
        smtp_sasl_security_options = "";
        smtp_sasl_password_maps = "texthash:/secrets/postfix_sasl";
      };
    };

    fail2ban = {
      enable = false;
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
