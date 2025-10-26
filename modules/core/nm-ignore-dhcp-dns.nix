{ config, lib, pkgs, ... }:

{
  # NetworkManager dispatcher script to clear DHCP-provided DNS servers
  # This ensures only hard-coded DNS servers from networking.nameservers are used
  networking.networkmanager.dispatcherScripts = [{
    source = pkgs.writeText "clear-dhcp-dns" ''
      #!/bin/sh
      # Clear DNS servers from NetworkManager connections
      # Only runs on DHCP events
      if [ "$2" = "dhcp4-change" ] || [ "$2" = "dhcp6-change" ] || [ "$2" = "up" ]; then
        ${pkgs.systemd}/bin/resolvectl dns "$1" ""
      fi
    '';
    type = "basic";
  }];
}
