{ config, lib, pkgs, ... }:

{
  networking = {
    hostId = "671bf6f5";
    hostName = "vulcan";
    domain = "lan";

    hosts = {
      "127.0.0.2" = lib.mkForce [];
      "192.168.1.2" = [ "vulcan.lan" "vulcan" ];
    };

    interfaces.end0.useDHCP = true;
  };

  # Enable IP forwarding for container networking
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };
}
