{ config, lib, pkgs, ... }:

{
  networking = {
    hostId = "671bf6f5";
    hostName = "vulcan";
    domain = "lan";

    # Hard-code DNS servers to prevent DHCP from adding extras
    nameservers = [ "127.0.0.1" "192.168.1.1" ];

    hosts = {
      "127.0.0.2" = lib.mkForce [];
      "192.168.1.2" = [ "vulcan.lan" "vulcan" ];
    };

    # Enable NetworkManager for WiFi and Ethernet management
    networkmanager = {
      enable = true;
      # Use internal DHCP implementation
      dhcp = "internal";
      # Use systemd-resolved for DNS
      dns = "systemd-resolved";
      # Ensure WiFi is enabled
      wifi.backend = "wpa_supplicant";
      # Ignore DHCP-provided DNS servers
      insertNameservers = [ "127.0.0.1" "192.168.1.1" ];
    };

    # Note: When NetworkManager is enabled, per-interface useDHCP is managed by NetworkManager
    # The Ethernet interface (end0) will be managed by NetworkManager
    # WiFi interface (wlp1s0f0) will also be managed by NetworkManager
  };

  # Enable systemd-resolved for DNS management with NetworkManager
  services.resolved = {
    enable = true;
    dnssec = "allow-downgrade";

    # Disable stub listener to avoid conflict with Technitium DNS (0.0.0.0:53)
    # Point directly to Technitium on localhost and ignore DHCP-provided DNS
    extraConfig = ''
      DNS=127.0.0.1 192.168.1.1
      Domains=~.
      DNSStubListener=no
    '';
  };

  # Enable IP forwarding for container networking
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };
}
