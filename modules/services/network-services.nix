{
  config,
  lib,
  pkgs,
  ...
}:

{
  services = {
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        # Send keepalives every 60s; drop after 3 missed (3 min total)
        # Prevents SSH sessions from dying silently through NAT/firewall
        ClientAliveInterval = 60;
        ClientAliveCountMax = 3;
      };
    };

    fail2ban.enable = false;
  };
}
