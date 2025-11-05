{ config, lib, pkgs, ... }:

{
  # Enable copyparty file server
  services.copyparty = {
    enable = true;
    port = 3923;
    domain = "copyparty.vulcan.lan";

    # Authentication is now managed via SOPS secrets
    # Accounts: admin (full admin), johnw (read/write)

    # Extra configuration for additional shares or settings
    extraConfig = ''
      # Additional volumes can be added here
      # Example:
      # [/media]
      #   /tank/Media
      #   accs:
      #     r: *
      #     rw: admin, johnw
    '';
  };
}
