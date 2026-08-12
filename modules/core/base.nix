{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ============================================================================
  # Core Base Configuration
  # Consolidates: boot, nix, firewall, hardware, and DNS override settings
  # ============================================================================

  # --------------------------------------------------------------------------
  # Boot Configuration
  # --------------------------------------------------------------------------
  boot = {
    loader = {
      systemd-boot.enable = true;
      systemd-boot.configurationLimit = 10; # Keep only 10 boot entries to save /boot space
      efi.canTouchEfiVariables = false;
    };

    # Enable QEMU user-mode emulation for running amd64 containers on ARM64
    # Note: preferStaticEmulators causes build failures on ARM64
    # Using default (non-static) emulator configuration with wrapper for
    # container support
    binfmt = {
      emulatedSystems = [ "x86_64-linux" ];

      # Don't override fixBinary - let it default to false for non-static
      # emulators
      # This allows the QEMU wrapper (wrapQemuBinfmtP) to work correctly in
      # containers
    };

    # nixpkgs common kernel config includes NOVA_CORE (added in 25.11 cycle)
    # but the pinned asahi kernel 6.17.12 doesn't have this Kconfig option.
    # Mark it optional so the kernel build doesn't fail with "unused option".
    # Remove this patch once nixos-apple-silicon is updated to a kernel that
    # includes NOVA_CORE, or once nixpkgs marks it optional upstream.
    kernelPatches = [
      {
        name = "nova-core-compat";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          NOVA_CORE = lib.mkForce (option no);
        };
      }
    ];
  };

  # --------------------------------------------------------------------------
  # Nix Configuration
  # --------------------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Automatic garbage collection to prevent unbounded Nix store growth
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Configure Nix to use system CA bundle (includes step-ca root certificate)
  # This allows git+https:// flake inputs to work with internal services
  # using certificates signed by step-ca
  nix.settings.ssl-cert-file = "/etc/ssl/certs/ca-bundle.crt";

  # Limit build parallelism to prevent WiFi driver crashes on Asahi Linux
  # The brcmfmac driver becomes unstable under high CPU + network load
  # Reducing parallelism prevents kernel panics during nixos-rebuild
  nix.settings.max-jobs = 4; # Limit concurrent builds (default: auto = 10 cores)
  nix.settings.cores = 2; # Limit cores per build job (default: 0 = all cores)

  # GitHub API authentication for flake input resolution.
  #
  # Unauthenticated api.github.com allows 60 requests/hour PER IP. This flake has
  # ~20 `github:` inputs and each one costs a request, so `nix flake update`
  # exhausts the quota in a couple of runs and dies with
  #   error: unable to download '...': HTTP error 403
  #   "API rate limit exceeded for <ip>"
  # An authenticated request gets 5000/hour instead.
  #
  # The token is deliberately NOT placed in `nix.settings.access-tokens`: that
  # would render it into /etc/nix/nix.conf, which is world-readable (0444).
  # Instead sops-nix renders it into a 0440 root:wheel file that nix.conf
  # `!include`s, so the credential never enters the Nix store or a public file.
  #
  # SAFE FOR NON-WHEEL USERS -- verified empirically on nix 2.31.5 (2026-08-11)
  # rather than assumed, because a hard failure here would break nix for
  # gitea-runner and the container users:
  #   * a reader who CAN see the file gets the token
  #     (`nix config show access-tokens` reports it)
  #   * a reader who CANNOT gets an empty value and exit 0
  # i.e. the include fails SOFT. Do not tighten this to a mode that root alone
  # can read without re-testing: `nix flake update` runs as johnw, not root.
  #
  # Reuses the existing `github-token` secret (declared in
  # modules/maintenance/timers.nix:345) rather than storing a second copy of the
  # same credential.
  sops.templates."nix-access-tokens.conf" = {
    content = "access-tokens = github.com=${config.sops.placeholder."github-token"}";
    mode = "0440";
    owner = "root";
    group = "wheel";
  };

  nix.extraOptions = ''
    !include ${config.sops.templates."nix-access-tokens.conf".path}
  '';

  # Also set NIX_SSL_CERT_FILE environment variable for all users
  # This ensures git operations invoked by Nix use the correct CA bundle
  environment.variables.NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
  environment.variables.GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";

  # --------------------------------------------------------------------------
  # Firewall Configuration
  # --------------------------------------------------------------------------
  networking.firewall = {
    enable = true;
    logRefusedConnections = true;
    logRefusedPackets = false;
    logRefusedUnicastsOnly = true;
    logReversePathDrops = true;

    # Use loose reverse path filtering for asymmetric routing
    # Allows WiFi devices (192.168.3.x) to reach services at Ethernet IP (192.168.1.2)
    # when packets are routed between networks
    checkReversePath = "loose";

    # Allow IGMP (protocol 2) on WiFi interface
    # Router sends IGMP membership queries to 224.0.0.1 (all-hosts multicast)
    # These have unicast MAC but multicast IP, so logRefusedUnicastsOnly doesn't filter them
    # IGMP is harmless - just for multicast group management
    # NOTE ON ORDERING: the IGMP rule below APPENDS (-A), so it lands after the
    # port accepts. The default-deny rule after it must INSERT (-I) instead, so
    # it lands *before* them. Getting that backwards makes the deny a no-op.
    extraCommands = ''
      iptables -A nixos-fw -i wlp1s0f0 -p igmp -j nixos-fw-accept

      # ---- default-deny on interfaces we do not explicitly serve ----
      #
      # WHY: every `networking.firewall.allowedTCPPorts` in this repo (~10
      # modules: dovecot, web/nginx, databases, home-assistant, hermes-microvm,
      # ...) is emitted WITHOUT an `-i` filter — NixOS only adds one for
      # `firewall.interfaces.<name>` entries (firewall-iptables.nix:161-165,
      # 191-196). The result is 17 TCP + 6 UDP ports, including 445/SMB,
      # 5432/PostgreSQL, 53/DNS, 80+443 for every nginx vhost and 1883/MQTT,
      # that automatically apply to any interface that ever exists.
      #
      # Nothing is wrongly exposed TODAY — every current interface is one we
      # intend to serve. This rule is about the next one: a WireGuard or
      # headscale device (see docs/TAILSCALE_HEADSCALE_PLAN.md and obr
      # nixos-rqw), a new bridge, a VPN. Without it, such an interface silently
      # inherits all 23 ports the moment it appears.
      #
      # POSITION 3 IS DELIBERATE. NixOS always emits, in order:
      #   1  -i lo                       -> accept
      #   2  ctstate ESTABLISHED,RELATED -> accept
      # so inserting at 3 puts this ahead of every port accept while leaving
      # both invariants intact. That ordering is also the safety property that
      # makes this rule survivable: an already-established SSH session matches
      # rule 2 and is unaffected even if an interface name here is wrong, which
      # leaves room to roll back.
      #
      # The allowlist is every interface currently carrying legitimate traffic:
      #   end0, wlp1s0f0  - the wired and wireless uplinks
      #   podman0         - containers reaching host services (pinned 10.88.0.1)
      #   hermes-br0      - the hermes microVM bridge (it needs 53; see
      #                     modules/services/hermes-microvm.nix:309-310)
      #   ve+             - nspawn/container veths: ve-static-nginx,
      #                     ve-copyparty, veth0, veth1
      #   vm+             - microVM taps: vm-hermes
      # `+` is iptables' trailing wildcard. `lo` is absent on purpose: rule 1
      # accepts it before this rule is ever reached.
      #
      # IMPLEMENTED AS A GUARD CHAIN, not as one `! -i a ! -i b ...` rule:
      # iptables 1.8.11 (nf_tables) rejects that outright with
      #   "multiple --in-interface options not allowed"
      # so the negated-list form does not exist. Each allowed interface gets its
      # own RETURN rule; anything reaching the end of the chain is refused.
      # A RETURN resumes nixos-fw at the rule after the jump — i.e. the port
      # accepts — so allowed interfaces behave exactly as before.
      #
      # The chain is flushed and rebuilt on every firewall start so repeated
      # activations cannot accumulate duplicates.
      for ipt in iptables ip6tables; do
        $ipt -N nixos-fw-ifguard 2>/dev/null || true
        $ipt -F nixos-fw-ifguard
        $ipt -A nixos-fw-ifguard -i end0       -j RETURN
        $ipt -A nixos-fw-ifguard -i wlp1s0f0   -j RETURN
        $ipt -A nixos-fw-ifguard -i podman0    -j RETURN
        $ipt -A nixos-fw-ifguard -i hermes-br0 -j RETURN
        $ipt -A nixos-fw-ifguard -i ve+        -j RETURN
        $ipt -A nixos-fw-ifguard -i vm+        -j RETURN
        $ipt -A nixos-fw-ifguard -j nixos-fw-refuse
        # Drop any stale jump before re-inserting, so restarts do not stack them.
        $ipt -D nixos-fw -j nixos-fw-ifguard 2>/dev/null || true
        $ipt -I nixos-fw 3 -j nixos-fw-ifguard
      done
    '';
    extraStopCommands = ''
      iptables -D nixos-fw -i wlp1s0f0 -p igmp -j nixos-fw-accept 2>/dev/null || true

      # Mirror of the guard chain above: unhook it, then empty and delete it.
      # A chain cannot be deleted while it is still referenced, hence the order.
      for ipt in iptables ip6tables; do
        $ipt -D nixos-fw -j nixos-fw-ifguard 2>/dev/null || true
        $ipt -F nixos-fw-ifguard 2>/dev/null || true
        $ipt -X nixos-fw-ifguard 2>/dev/null || true
      done
    '';
  };

  # Enable loose reverse path filtering for asymmetric routing
  # This allows WiFi devices (192.168.3.0/24) to access services at the
  # Ethernet IP (192.168.1.2) without rpfilter dropping packets
  # Mode 2 = loose mode (allows packets from any interface)
  # Mode 1 = strict mode (default, drops asymmetric packets)
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;

    # Override nixpkgs default of 33. On aarch64 with 16K pages (Asahi Linux
    # kernel), CONFIG_ARCH_MMAP_RND_BITS_MAX is lower than 33, so applying the
    # default causes systemd-sysctl.service to fail with EINVAL. 28 is within
    # the valid range on this kernel and preserves strong ASLR entropy.
    "vm.mmap_rnd_bits" = 28;
  };

  # --------------------------------------------------------------------------
  # Hardware Configuration
  # --------------------------------------------------------------------------
  # Enable hardware graphics acceleration
  # Required for GPU support including Vulkan on Asahi Linux
  hardware.graphics = {
    enable = true;
    # Enable 32-bit support for compatibility (if needed)
    enable32Bit = false; # Not needed on aarch64
  };

  # Use modesetting driver for Apple Silicon GPU
  # Mesa provides OpenGL and Vulkan support via the Asahi driver
  services.xserver.videoDrivers = [ "modesetting" ];

  # --------------------------------------------------------------------------
  # NetworkManager DNS Override
  # --------------------------------------------------------------------------
  # NetworkManager dispatcher script to clear DHCP-provided DNS servers
  # This ensures only hard-coded DNS servers from networking.nameservers are used
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeText "clear-dhcp-dns" ''
        #!/bin/sh
        # Clear DNS servers from NetworkManager connections.
        # Skip loopback: resolvectl cannot manage DNS on lo, so it exits 1
        # there. NM fires this dispatcher on "lo up" during startup, and the
        # resulting failed-script status stalls NetworkManager-wait-online
        # for the full timeout when nixos-rebuild restarts NM.
        [ "$1" = "lo" ] && exit 0
        [ "$CONNECTION_TYPE" = "loopback" ] && exit 0
        if [ "$2" = "dhcp4-change" ] || [ "$2" = "dhcp6-change" ] || [ "$2" = "up" ]; then
          ${pkgs.systemd}/bin/resolvectl dns "$1" ""
        fi
      '';
      type = "basic";
    }
  ];
}
