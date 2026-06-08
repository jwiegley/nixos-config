{
  config,
  lib,
  pkgs,
  ...
}:

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
    nameservers = [
      "127.0.0.1"
    ];

    # Disable reverse path filtering in firewall
    # Required for asymmetric routing between WiFi (192.168.3.x) and Ethernet
    # (192.168.1.x) networks
    # firewall.checkReversePath = false;

    hosts = {
      "127.0.0.2" = [ ];
      "192.168.1.2" = [
        "vulcan.lan"
        "vulcan"
      ];
      # Hera.local - Apple device, IP discovered via mDNS/Bonjour
      # This entry silences Postfix reverse DNS warnings when Hera connects
      "192.168.3.6" = [ "Hera.local" ];
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
      insertNameservers = [
        "127.0.0.1"
      ];
    };

    # Note: When NetworkManager is enabled, per-interface useDHCP is managed
    # by NetworkManager
    # The Ethernet interface (end0) will be managed by NetworkManager
    # WiFi interface (wlp1s0f0) will also be managed by NetworkManager
  };

  # Enable systemd-resolved for DNS management with NetworkManager
  services.resolved = {
    enable = true;
    dnssec = "false";

    # Disable stub listener to avoid conflict with Technitium DNS (0.0.0.0:53)
    # Point directly to Technitium on localhost and ignore DHCP-provided DNS
    # Route .lan domains specifically to Technitium for local name resolution
    extraConfig = ''
      DNS=127.0.0.1
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

  # NetworkManager dispatcher script: re-apply asymmetric routing rules whenever
  # end0 comes up or DHCP renews (NetworkManager wipes ip rules on interface events)
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeShellScript "re-apply-asymmetric-routing" ''
        IFACE="$1"
        ACTION="$2"
        case "$ACTION" in
          up|dhcp4-change|dhcp6-change|connectivity-change)
            if [ "$IFACE" = "end0" ]; then
              systemctl restart asymmetric-routing
            fi
            ;;
        esac
      '';
      type = "basic";
    }
  ];

  # Declarative NM connection profile for end0 with embedded routing rules
  # NM re-applies these ip rules on every connection activation, making them
  # survive NM restarts, DHCP renewals, and all interface events natively
  networking.networkmanager.ensureProfiles.profiles = {
    "end0-wired" = {
      connection = {
        id = "end0-wired";
        type = "ethernet";
        "interface-name" = "end0";
        autoconnect = "true";
        "autoconnect-priority" = "10";
        uuid = "a3f1d2e4-5b6c-7d8e-9f0a-1b2c3d4e5f6a";
      };
      ethernet = { };
      ipv4 = {
        method = "auto";
        "route-metric" = "100";
        # Force all traffic from 192.168.1.2 destined for 192.168.x.x back via
        # the wired gateway (192.168.1.1) so asymmetric replies use correct source IP
        "routing-rule1" = "priority 50 from 192.168.1.2/32 to 192.168.0.0/16 table 200";
        # Same fix for container network range (10.x.x.x)
        "routing-rule2" = "priority 51 from 192.168.1.2/32 to 10.0.0.0/8 table 200";
      };
      ipv6 = {
        method = "auto";
        "addr-gen-mode" = "default";
      };
    };
  };

  # Disable systemd-networkd-wait-online on this host. networkd exists here ONLY
  # to build the microVM/container bridges; the real uplinks (end0, wlp1s0f0) are
  # NetworkManager-owned and networkd-`unmanaged`, so `networkd-wait-online --any`
  # cannot count them. The only links it *can* count are the microVM bridges/taps
  # (`configured`, RequiredForOnline=yes by default) — but a bridge gains carrier
  # only once its VM boots, and the VMs are ordered behind network-online.target.
  # That self-referential deadlock burns the full 120s --timeout every boot/switch
  # (verified 2026-06-08: 12:21:57 → 12:23:57). NetworkManager-wait-online is the
  # sole, correct owner of network-online.target here (gated on the real uplink).
  # Only cloudflared-tunnel-data hard-Requires= the target (and it self-reconnects);
  # every other consumer is a soft Wants=. See memory project_vulcan_wait_online_rca
  # (2026-06-02 11-agent RCA, adversarially verified + re-confirmed live 2026-06-08).
  systemd.network.wait-online.enable = false;

  # Override NetworkManager-wait-online to use `nm-online -x` instead of `-s -q`.
  # `-s` waits for NM's one-shot "startup complete" event, which only fires during
  # initial autoconnect activation. On a `nixos-rebuild switch` the unit gets
  # restarted while NM is already in steady-state — no fresh startup-complete
  # event ever arrives, so nm-online times out at NM_ONLINE_TIMEOUT (60s) and
  # the unit lands in failed state. `-x` exits as soon as connectivity is
  # present, working correctly for both fresh boots and hot switches.
  # The leading empty ExecStart= is required for drop-in overrides to replace
  # rather than append to the upstream unit's ExecStart line.
  systemd.services.NetworkManager-wait-online.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${pkgs.networkmanager}/bin/nm-online -x -q"
  ];

  # ─── TEMPORARY (2026-06-08): NM-wait-online boot-state capture ──────────────
  # The NM half of the wait-online failure is unvalidated: `nm-online -x -q`
  # reportedly hangs ~60s at boot, which contradicts `-x` ("exit immediately if
  # NM is starting up or connecting"). This oneshot logs NM's real state timeline
  # plus a controlled, timed `nm-online -x -q` over the first ~100s of boot, so
  # the NEXT natural reboot reveals the true mechanism. It gates nothing (no
  # Before=), logs no secrets (states + rc codes only). After the next boot:
  #   journalctl -u nm-boot-state-capture -b 0 -o short-precise | grep NMCAP
  #   journalctl -u NetworkManager-wait-online -b 0 -o short-precise
  # then choose the NM fix and DELETE this block. See project_vulcan_wait_online_rca.
  systemd.services.nm-boot-state-capture = {
    description = "TEMP: capture NM state during boot (diagnose nm-online -x hang)";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" ];
    wants = [ "NetworkManager.service" ];
    path = [
      pkgs.networkmanager
      pkgs.coreutils
      pkgs.gnugrep
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = 180;
    };
    script = ''
      set +e
      # Reproduce the wait-online unit's exact call, timed, in the background.
      (
        t0=$(date +%s)
        timeout 90 nm-online -x -q; rcx=$?
        t1=$(date +%s)
        echo "NMCAP repro 'nm-online -x -q' rc=$rcx duration=$((t1 - t0))s finished=$(date +%H:%M:%S.%3N)"
      ) &
      # State timeline for ~100s.
      stop=$(( $(date +%s) + 100 ))
      while [ "$(date +%s)" -lt "$stop" ]; do
        gen=$(nmcli -t -f STATE,CONNECTIVITY general status 2>/dev/null | tr '\n' ' ')
        end0=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep '^end0:' || true)
        q=$(nm-online -q -t 1 >/dev/null 2>&1; echo $?)
        echo "NMCAP $(date +%H:%M:%S.%3N) general=[$gen] end0=[$end0] nm-online_-q_-t1=$q"
        sleep 2
      done
      wait
      exit 0
    '';
  };
  # ─── end TEMPORARY block ────────────────────────────────────────────────────

  # Policy routing for asymmetric routing support
  # Problem: Clients on 192.168.3.x reach 192.168.1.2 via router (arrives on end0),
  # but responses would go out via wlp1s0f0 with source IP 192.168.3.16 (wrong!)
  # Solution: Mark packets arriving on end0 from non-local subnets and route them
  # back via end0's gateway so responses have correct source IP (192.168.1.2)
  systemd.services.asymmetric-routing = {
    description = "Configure policy routing for cross-subnet DNS and NTP access";
    wantedBy = [ "network-online.target" ];
    after = [
      "network-online.target"
      "NetworkManager.service"
    ];
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

      # Add route for container network (10.88.0.0/16) via podman0
      # This is critical: rule 51 routes traffic from 192.168.1.2 to 10.0.0.0/8 through this table
      # Without this, DNS responses being de-NAT'd to container IPs would be routed to the gateway
      # instead of to podman0, causing container DNS to fail
      # Only add if podman0 exists - it won't exist if no containers are running
      if ${pkgs.iproute2}/bin/ip link show podman0 &>/dev/null; then
        ${pkgs.iproute2}/bin/ip route add 10.88.0.0/16 dev podman0 table end0_return 2>/dev/null || \
          ${pkgs.iproute2}/bin/ip route replace 10.88.0.0/16 dev podman0 table end0_return
      fi

      # Then add default route via gateway for cross-subnet traffic (e.g., to 192.168.3.x)
      ${pkgs.iproute2}/bin/ip route add default via $GATEWAY table end0_return 2>/dev/null || \
        ${pkgs.iproute2}/bin/ip route replace default via $GATEWAY table end0_return

      # Route ALL traffic from 192.168.1.2 destined to non-local subnets via the ethernet gateway.
      # Source-specific rules are critical: "from all" rules would intercept responses from
      # wlp1s0f0 (192.168.3.16) and misroute them via end0, breaking WiFi-interface services.
      ${pkgs.iproute2}/bin/ip rule add from 192.168.1.2 to 192.168.0.0/16 table end0_return priority 50 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add from 192.168.1.2 to 10.0.0.0/8 table end0_return priority 51 2>/dev/null || true

      echo "Asymmetric routing configured: all traffic from 192.168.1.2 routes via $GATEWAY"
    '';

    preStop = ''
      ${pkgs.iproute2}/bin/ip rule del from 192.168.1.2 to 192.168.0.0/16 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule del from 192.168.1.2 to 10.0.0.0/8 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip route del 10.88.0.0/16 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip route del 192.168.1.0/24 table end0_return 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip route del default table end0_return 2>/dev/null || true
    '';
  };
}
