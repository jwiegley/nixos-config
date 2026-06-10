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

  # Declarative NM connection profile for end0. NOTE: NM does NOT materialize the
  # ipv4.routing-rule1/2 declared below into the kernel (verified 2026-06-09 — the
  # only live priority 50/51 rules are `proto unspec`, i.e. added by the
  # asymmetric-routing oneshot, never `proto static` as NM would tag its own). The
  # oneshot (re-run by the NM dispatcher on every end0 up/dhcp event) is the SINGLE
  # authoritative writer. The dead routing-rule keys below are kept FOR NOW; remove
  # them once a cold reboot confirms the (now fail-loud) oneshot lands the rules at
  # boot — see docs/BOOT_SWITCH_ROBUSTNESS_AUDIT.md (asymmetric-routing, Phase B).
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

  # NetworkManager-wait-online: upstream default `nm-online -s -q` (wait-for-
  # startup) with a generous 60s timeout. A previous override used `-x` ("exit
  # immediately if NM is not running or connecting") on the theory that `-s`
  # hangs on `nixos-rebuild switch`. Boot capture on 2026-06-08 proved that
  # theory wrong both ways:
  #   * `-x` FAST-FAILS at boot — the unit runs while NM is still connecting, so
  #     `-x` exits rc=1 immediately (measured: failed 62ms after start at
  #     13:32:23.5 while NM was `disconnected:none`; the link reached
  #     `connected:full` ~10s later). It was releasing network-online.target
  #     before the network was up, and logging a failure every boot.
  #   * `-s -q` does NOT hang on switch — startup is already complete, so it
  #     returns 0 in ~13ms in steady state (measured 2026-06-08).
  # `-s -q` waits for startup-complete on boot and returns instantly on switch —
  # correct for both. -t 60 covers slow boots (end0 has been seen routable ~32s).
  # The leading empty ExecStart= is required for drop-in overrides to replace
  # rather than append to the upstream unit's ExecStart line.
  # See memory project_vulcan_wait_online_rca.
  systemd.services.NetworkManager-wait-online.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${pkgs.networkmanager}/bin/nm-online -s -q -t 60"
  ];

  # Keep systemd-networkd from deleting the asymmetric-routing oneshot's work.
  #
  # networkd here owns ONLY the microVM/container bridges (vm-hermes, vm-openclaw,
  # podman0, …). But with the systemd defaults ManageForeignRoutingPolicyRules=yes
  # and ManageForeignRoutes=yes, every time networkd RECONFIGURES a bridge — which
  # it does on EVERY `nixos-rebuild switch` that restarts a microvm@ unit — it also
  # flushes all routing rules and routes it did not itself create. That silently
  # wiped the priority 50/51 `ip rule`s and the `end0_return` table routes added by
  # the asymmetric-routing oneshot below (verified 2026-06-10: gauge
  # asymmetric_routing_rules_present went 1→0 at the 12:11 and 15:15 switches, each
  # coinciding with a "vm-*: Configuring with …" networkd log line; the NM
  # dispatcher only re-applies on end0 events, so a switch left the rules gone and
  # AsymmetricRoutingRulesMissing firing). Those rules/routes are owned by the
  # oneshot and by NetworkManager — never by networkd — so tell networkd to leave
  # all foreign rules/routes alone. networkd still fully manages its own bridges.
  systemd.network.config.networkConfig = {
    ManageForeignRoutingPolicyRules = false;
    ManageForeignRoutes = false;
  };

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
      # Add the source-policy rules idempotently, then VERIFY they landed. No
      # `|| true`: a silent add-failure means cross-subnet replies leave via the
      # wrong interface (WiFi) with the wrong source IP, so this oneshot MUST fail
      # loudly instead of reporting active(exited) with no rules in the kernel.
      # (Audit 2026-06-09: priority 50/51 rules were found absent post-boot.)
      add_rule_idempotent() {
        # $1=to-prefix  $2=priority
        if ! ${pkgs.iproute2}/bin/ip rule list | ${pkgs.gnugrep}/bin/grep -q "from 192.168.1.2 to $1 lookup end0_return"; then
          ${pkgs.iproute2}/bin/ip rule add from 192.168.1.2 to "$1" table end0_return priority "$2"
        fi
      }
      add_rule_idempotent 192.168.0.0/16 50
      add_rule_idempotent 10.0.0.0/8 51

      # Verify both rules are present; fail the unit if not.
      for prefix in 192.168.0.0/16 10.0.0.0/8; do
        if ! ${pkgs.iproute2}/bin/ip rule list | ${pkgs.gnugrep}/bin/grep -q "from 192.168.1.2 to $prefix lookup end0_return"; then
          echo "ERROR: asymmetric-routing rule for $prefix did not land" >&2
          exit 1
        fi
      done

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
