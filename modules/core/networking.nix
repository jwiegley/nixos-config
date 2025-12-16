{ config, lib, pkgs, ... }:

{
  # Enable iproute2 with custom routing table for asymmetric routing fix
  networking.iproute2 = {
    enable = true;
    rttablesExtraConfig = ''
      200 end0_return
    '';
  };

  networking = {
    hostId = "671bf6f5";
    hostName = "vulcan";
    domain = "lan";

    # Hard-code DNS servers to prevent DHCP from adding extras
    nameservers = [ "127.0.0.1" "192.168.1.1" ];

    # Disable reverse path filtering in firewall
    # Required for asymmetric routing between WiFi (192.168.3.x) and Ethernet
    # (192.168.1.x) networks
    # firewall.checkReversePath = false;

    hosts = {
      "127.0.0.2" = [];
      "192.168.1.2" = [ "vulcan.lan" "vulcan" ];
      "192.168.1.4" = [ "Hera.local" ];
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

    # Note: When NetworkManager is enabled, per-interface useDHCP is managed
    # by NetworkManager
    # The Ethernet interface (end0) will be managed by NetworkManager
    # WiFi interface (wlp1s0f0) will also be managed by NetworkManager
  };

  # Enable systemd-resolved for DNS management with NetworkManager
  services.resolved = {
    enable = true;
    dnssec = "allow-downgrade";

    # Disable stub listener to avoid conflict with Technitium DNS (0.0.0.0:53)
    # Point directly to Technitium on localhost and ignore DHCP-provided DNS
    # Route .lan domains specifically to Technitium for local name resolution
    extraConfig = ''
      DNS=127.0.0.1 192.168.1.1
      Domains=~lan
      DNSStubListener=no
    '';
  };

  # Enable IP forwarding for container networking
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;

    # Disable reverse path filtering to allow asymmetric routing
    # This is needed because traffic from 192.168.3.x arrives on end0 (via
    # router) but routing table shows 192.168.3.0/24 is reachable via wlp1s0f0
    # "net.ipv4.conf.all.rp_filter" = 0;
    # "net.ipv4.conf.default.rp_filter" = 0;
    # "net.ipv4.conf.end0.rp_filter" = 0;
    # "net.ipv4.conf.wlp1s0f0.rp_filter" = 0;
  };

  # Policy routing for asymmetric routing support
  # Problem: Clients on 192.168.3.x reach 192.168.1.2 via router (arrives on end0),
  # but responses would go out via wlp1s0f0 with source IP 192.168.3.16 (wrong!)
  # Solution: Mark packets arriving on end0 from non-local subnets and route them
  # back via end0's gateway so responses have correct source IP (192.168.1.2)
  systemd.services.asymmetric-routing = {
    description = "Configure policy routing for cross-subnet DNS and NTP access";
    wantedBy = [ "network-online.target" ];
    after = [ "network-online.target" "NetworkManager.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for end0 to be up with an IP
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ip addr show end0 | grep -q 'inet '; then
          break
        fi
        sleep 1
      done

      GATEWAY="192.168.1.1"

      # Create return route table for end0
      # First, add direct route for the local subnet so local traffic doesn't go via gateway
      ${pkgs.iproute2}/bin/ip route add 192.168.1.0/24 dev end0 src 192.168.1.2 table end0_return 2>/dev/null || \
        ${pkgs.iproute2}/bin/ip route replace 192.168.1.0/24 dev end0 src 192.168.1.2 table end0_return

      # Then add default route via gateway for cross-subnet traffic (e.g., to 192.168.3.x)
      ${pkgs.iproute2}/bin/ip route add default via $GATEWAY table end0_return 2>/dev/null || \
        ${pkgs.iproute2}/bin/ip route replace default via $GATEWAY table end0_return

      # Route ALL traffic from 192.168.1.2 destined to non-local subnets via the ethernet gateway
      ${pkgs.iproute2}/bin/ip rule add from 192.168.1.2 to 192.168.0.0/16 table end0_return priority 50 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add from 192.168.1.2 to 10.0.0.0/8 table end0_return priority 51 2>/dev/null || true

      # Keep specific port rules as fallback (lower priority) for any edge cases
      ${pkgs.iproute2}/bin/ip rule add ipproto udp sport 53 to 192.168.0.0/16 table end0_return priority 60 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add ipproto tcp sport 53 to 192.168.0.0/16 table end0_return priority 61 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add ipproto udp sport 123 to 192.168.0.0/16 table end0_return priority 62 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add ipproto udp sport 53 to 10.0.0.0/8 table end0_return priority 60 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add ipproto tcp sport 53 to 10.0.0.0/8 table end0_return priority 61 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add ipproto udp sport 123 to 10.0.0.0/8 table end0_return priority 62 2>/dev/null || true

      echo "Asymmetric routing configured: all traffic from 192.168.1.2 routes via $GATEWAY"
    '';

    preStop = ''
      ${pkgs.iproute2}/bin/ip rule del from 192.168.1.2 to 192.168.0.0/16 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del from 192.168.1.2 to 10.0.0.0/8 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del ipproto udp sport 53 to 192.168.0.0/16 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del ipproto tcp sport 53 to 192.168.0.0/16 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del ipproto udp sport 123 to 192.168.0.0/16 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del ipproto udp sport 53 to 10.0.0.0/8 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del ipproto tcp sport 53 to 10.0.0.0/8 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del ipproto udp sport 123 to 10.0.0.0/8 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip route del 192.168.1.0/24 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip route del default table end0_return 2>/dev/null || true
    '';
  };
}
