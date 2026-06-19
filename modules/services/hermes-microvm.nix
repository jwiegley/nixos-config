# Host-side parent module for the Hermes Agent microVM.
# Imported by /etc/nixos/hosts/vulcan/default.nix.
#
# Sibling to modules/services/openclaw-microvm.nix; intentionally on
# its own private /30 bridge so neither VM's networking can affect the
# other. No DNAT/inbound in Phase 1 — Hermes is outbound-only.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  # Imported here (in addition to hermes-vm.nix) so the host service has
  # something to key restart triggers on — changing models.nix should
  # restart microvm@hermes during the next nixos-rebuild switch.
  models = import ../../models.nix;

  bridgeName = "hermes-br0";
  tapName = "vm-hermes";
  bridgeAddr = "10.99.1.1";
  bridgeCidr = "${bridgeAddr}/30";
  vmAddr = "10.99.1.2";

  # External NIC used for VM NAT. Matches openclaw-microvm.nix:25 — the
  # host's physical interface on this Asahi/aarch64 box. Update both
  # files together if it ever changes.
  externalInterface = "end0";

  vmHostname = "hermes-vm";
  hermesUid = 932;
  hermesGid = 932;
  stateDir = "/var/lib/hermes";

  # Host-side staging dir for SOPS secret *content* shared into the VM via
  # virtiofs as /run/hermes-secrets. Mirrors openclaw-microvm.nix:43
  # ("${microvmBase}/secrets"). sops-nix decrypts on the host; the
  # hermes-prepare-secrets oneshot copies the content here at 0400
  # hermes:hermes before the VM starts (the guest has no sops-nix).
  secretsStagingDir = "/var/lib/microvms/hermes/secrets";

  # -- Host-side loopback services that the VM needs to reach --
  # Strategy mirrors openclaw-microvm.nix:115-118 — two-stage DNAT:
  #   1. Guest nftables OUTPUT: 127.0.0.1:port -> 10.99.1.1:port
  #   2. Host iptables PREROUTING (on hermes-br0): 10.99.1.1:port -> 127.0.0.1:port
  #   3. Host sysctl route_localnet=1 on hermes-br0 (allows the loopback hop)
  # Service-parity set (mirrors the OpenClaw service surface, minus
  # OpenClaw-only ports). The host PREROUTING DNAT, per-interface INPUT
  # accepts, and the hermes-isolate RETURN rules below are all
  # parameterized on this list, so adding a port here propagates to all
  # three automatically:
  #   443  nginx HTTPS (searxng.vulcan.lan, vane.vulcan.lan, trader.vulcan.lan)
  #   993  Dovecot IMAPS (email-contacts)
  #   2525 Postfix SMTP (email-contacts)
  #   4000 LiteLLM (hera/* model route + org-search embeddings)
  #   5232 Radicale CardDAV (contacts)
  #   5432 PostgreSQL (org-db read-only)
  #   8123 Home Assistant (mcp-proxy bridge)
  # Deliberately EXCLUDED: 6333/6334/6335 (Qdrant — OpenClaw-memory-specific)
  # and 9081 (the OpenClaw↔Hermes bridge — Hermes *is* Hermes).
  dnatPorts = [
    443
    993
    2525
    4000
    5232
    5432
    8123
    9082
    8236 # memory-vault-mcp — Hermes→Memory Vault MCP (streamable-http, native url)
  ];
  # NO-SPACE comma join: this string feeds both `iptables -m multiport
  # --dports` (host isolate chain below) and the guest's nftables
  # `tcp dport { ... }` set. iptables multiport rejects spaces (an unquoted
  # "443, 993" word-splits into a trailing-comma token -> "invalid port ''"),
  # and nftables sets accept the comma-only form fine. Was ", " when only
  # port 4000 was in the list, which hid the bug.
  dnatPortList = lib.concatStringsSep "," (map toString dnatPorts);
  hostDnatRules = lib.concatMapStringsSep "\n" (port: ''
    iptables -t nat -A PREROUTING -i ${bridgeName} -d ${bridgeAddr} -p tcp --dport ${toString port} -j DNAT --to-destination 127.0.0.1:${toString port}
  '') dnatPorts;
  hostDnatCleanupRules = lib.concatMapStringsSep "\n" (port: ''
    iptables -t nat -D PREROUTING -i ${bridgeName} -d ${bridgeAddr} -p tcp --dport ${toString port} -j DNAT --to-destination 127.0.0.1:${toString port} 2>/dev/null || true
  '') dnatPorts;
in
{
  # ---- Host user/group ----
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    description = "Hermes Agent runtime user";
  };
  users.groups.hermes.gid = hermesGid;

  # ---- Host-side persistent state ----
  # `d` directive — preserves contents across rebuilds (CLAUDE.md rule).
  # The Vulcan root CA is embedded into the VM's trust store at
  # evaluation time via security.pki.certificates (see hermes-vm.nix),
  # so no host-side staging is needed.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 hermes hermes -"
  ];

  # ---- NetworkManager coexistence ----
  networking.networkmanager.unmanaged = [
    "interface-name:${bridgeName}"
    "interface-name:${tapName}"
  ];

  # ---- systemd-networkd: bridge + TAP ----
  systemd.network.enable = true;
  # systemd-networkd-wait-online is disabled host-wide (modules/core/networking.nix);
  # the old `anyInterface` override here was moot and was removed.
  systemd.network.netdevs."50-${bridgeName}".netdevConfig = {
    Kind = "bridge";
    Name = bridgeName;
  };
  systemd.network.networks."50-${bridgeName}" = {
    matchConfig.Name = bridgeName;
    addresses = [ { Address = bridgeCidr; } ];
    networkConfig.ConfigureWithoutCarrier = true;
  };
  systemd.network.networks."51-${tapName}" = {
    matchConfig.Name = tapName;
    networkConfig.Bridge = bridgeName;
  };

  # ---- NAT: VM internet access ----
  networking.nat = {
    enable = true;
    internalInterfaces = [ bridgeName ];
    externalInterface = externalInterface;
  };

  # ---- Per-interface INPUT accepts ----
  # Technitium DNS on the host binds to 0.0.0.0:53, so the VM uses
  # bridgeAddr as its DNS server. PREROUTING DNAT rewrites
  # bridgeAddr:PORT → 127.0.0.1:PORT but the packet still arrives via
  # hermes-br0; the INPUT chain must whitelist the post-DNAT ports on
  # this interface or `nixos-fw-log-refuse` drops them at end-of-chain.
  # Matches openclaw-microvm.nix:479-486.
  networking.firewall.interfaces.${bridgeName} = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ] ++ dnatPorts;
  };

  # ---- Egress isolation (iptables-nft, matching OpenClaw) ----
  # Phase 1: outbound is allowed to the public internet (Discord +
  # OpenRouter via the hera/* route). The chain below only restricts
  # the VM's access *back* into the host's private network.
  #
  # TODO(phase-2): tighten egress to an allowlist of known endpoint
  # ranges — Discord runs behind Cloudflare (AS13335) and OpenRouter
  # publishes its egress addresses. Until then, a compromised Hermes
  # process could exfiltrate to arbitrary public IPs.
  networking.firewall.extraCommands = ''
    # ── Hermes network isolation ──
    iptables -N hermes-isolate 2>/dev/null || iptables -F hermes-isolate

    # DNS to bridge gateway (Technitium binds to 0.0.0.0:53)
    iptables -A hermes-isolate -d ${bridgeAddr} -p tcp --dport 53 -j RETURN
    iptables -A hermes-isolate -d ${bridgeAddr} -p udp --dport 53 -j RETURN

    # DNAT'd host services (LiteLLM, etc.) — accept inbound traffic to
    # bridgeAddr on these ports.  NOTE: PREROUTING DNAT rewrites the
    # destination to 127.0.0.1 BEFORE the INPUT chain (and therefore this
    # isolation chain) runs, so the post-DNAT packet has dst=127.0.0.1, not
    # bridgeAddr. We need BOTH rules — the bridgeAddr one is belt-and-
    # suspenders if the DNAT ever stops running (the connection then fails
    # noisily rather than silently slipping through), and the 127.0.0.1 one
    # is what actually matches in steady state. Matches openclaw-isolate.
    iptables -A hermes-isolate -d ${bridgeAddr} -p tcp -m multiport --dports ${dnatPortList} -j RETURN
    iptables -A hermes-isolate -d 127.0.0.1 -p tcp -m multiport --dports ${dnatPortList} -j RETURN

    # Drop everything else originating from the VM toward host services
    iptables -A hermes-isolate -j DROP
    iptables -I nixos-fw 3 -i ${bridgeName} -j hermes-isolate

    # Bridge→bridge forwarding for DNAT return path. The DNAT happens
    # in PREROUTING (host iptables nat:PREROUTING), then the kernel
    # routes 127.0.0.1 via lo. The reply packet's source is 127.0.0.1
    # which gets SNAT'd back to bridgeAddr via the FORWARD chain.
    iptables -A FORWARD -i ${bridgeName} -o ${bridgeName} -j ACCEPT

    # FORWARD chain: block private-network-bound traffic.
    iptables -A FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP

    # Allow conservative outbound set (per 7-day egress log review):
    # - TCP 443 (HTTPS — Discord, OpenRouter, internal hera)
    # - UDP 443 (HTTP/3 — Cloudflare-fronted services increasingly use it)
    # - TCP/UDP 53 (DNS)
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 443 -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 443 -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 53  -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 53  -j ACCEPT

    # Egress logging — log new outbound connections that didn't match
    # any ACCEPT above (i.e. about to be DROPped by the final rule).
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress-rejected: " --log-level info

    # Final DROP — anything not matched by the ACCEPT rules above is rejected
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -j DROP

    # Belt-and-suspenders IPv6: the guest has v6 disabled and the
    # bridge is v4-only, but if anything ever flips v6 forwarding on
    # this host (or adds a v6 addr to the bridge), the v4 rules above
    # silently fail to filter it. Drop any v6 forward off the bridge.
    ip6tables -A FORWARD -i ${bridgeName} -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i ${bridgeName} -j hermes-isolate 2>/dev/null || true
    iptables -F hermes-isolate 2>/dev/null || true
    iptables -X hermes-isolate 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${bridgeName} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 53  -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 53  -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress-rejected: " --log-level info 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -j DROP 2>/dev/null || true
    ip6tables -D FORWARD -i ${bridgeName} -j DROP 2>/dev/null || true
  '';

  # ---- Two-stage DNAT (stage 2: host PREROUTING) ----
  # See dnatPorts comment in `let` block. The guest's stage 1 (OUTPUT
  # DNAT 127.0.0.1:port -> bridgeAddr:port) is in hermes-vm.nix. This
  # piece rewrites the bridge-bound packets back to host loopback, and
  # the sysctl below lets the kernel actually route loopback via the
  # bridge interface.
  boot.kernel.sysctl."net.ipv4.conf.${bridgeName}.route_localnet" = 1;

  systemd.services.hermes-host-dnat = {
    description = "DNAT rules for Hermes VM to reach host loopback services";
    wantedBy = [ "microvm@hermes.service" ];
    before = [ "microvm@hermes.service" ];
    after = [
      "network-online.target"
      "sys-subsystem-net-devices-${bridgeName}.device"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [ pkgs.iptables ];

    script = ''
      ${hostDnatRules}
      echo "Hermes host DNAT rules installed for ports: ${dnatPortList}"
    '';

    preStop = ''
      ${hostDnatCleanupRules}
    '';
  };

  # ---- Nix store / virtiofs interaction ----
  # The guest mounts /nix/store via virtiofs in hermes-vm.nix.
  # Auto-optimise on the host can produce stale file handles inside
  # the guest — disable. Matches openclaw-microvm.nix:623.
  nix.optimise.automatic = false;

  # ---- SOPS secret staged for the VM's environmentFile ----
  # Note: NO `path` option — sops-nix's `path` writes a symlink at the
  # target, and inside the VM the symlink target /run/secrets/hermes/env
  # doesn't exist (the VM has no sops-nix). So we let sops deploy to its
  # default /run/secrets/hermes/env on the host, and a prepare-secrets
  # oneshot below copies the *content* into the state share at
  # ${stateDir}/env so the in-VM hermes-agent.service can read a real
  # file via virtio-fs. Same pattern as openclaw-microvm.nix:495.
  sops.secrets."hermes/env" = {
    mode = "0640";
    owner = "hermes";
    group = "hermes";
    # Restart both the staging service and the microVM when the secret
    # rotates so the new env vars propagate.
    restartUnits = [
      "hermes-prepare-secrets.service"
      "microvm@hermes.service"
    ];
  };

  # ---- Reused SOPS secrets: append Hermes restart triggers only ----
  # owner/group/mode for these five are declared by their canonical
  # owners (openclaw-microvm.nix, email-tester, vdirsyncer). Declaring
  # them again here would conflict; sops-nix `restartUnits` is a list
  # that merges across modules, so we add ONLY the restart triggers so
  # that rotating any of these re-stages the secret and restarts the VM.
  sops.secrets."email-tester-imap-password".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];
  sops.secrets."vdirsyncer-johnw/radicale-password".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];
  sops.secrets."openclaw/home-assistant-token".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];
  sops.secrets."openclaw/org-db-password".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];
  sops.secrets."openclaw/perplexity-api-key".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];

  # ---- Stage SOPS secret content into the VM's virtio-fs state share ----
  systemd.services.hermes-prepare-secrets = {
    description = "Stage SOPS secrets for Hermes microVM";
    wantedBy = [ "microvm@hermes.service" ];
    before = [ "microvm@hermes.service" ];
    after = [ "sops-nix.service" ];

    # Force re-stage when models.nix changes — Type=oneshot + RemainAfterExit
    # means switch-to-configuration would otherwise skip restarting this unit
    # on closure changes, leaving the staged config out of sync.
    restartTriggers = [ (builtins.toJSON { agent = models.llm.agent; }) ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      install -d -m 0750 -o hermes -g hermes "${stateDir}"
      install -m 0640 -o hermes -g hermes \
        "${config.sops.secrets."hermes/env".path}" \
        "${stateDir}/env"
      echo "Hermes env staged to ${stateDir}/env"

      # Staging dir for the virtio-fs hermes-secrets share. Owned by root
      # (0755); virtiofs handles per-file access, the files themselves are
      # 0400 hermes:hermes. Matches openclaw-prepare-secrets:570-571.
      mkdir -p "${secretsStagingDir}"
      chmod 0755 "${secretsStagingDir}"

      # Stage the five reused SOPS secrets' *content* into the share. These
      # are NOT hermes-owned SOPS entries (they're reused from OpenClaw /
      # email-tester / vdirsyncer), so guard each copy with `if [ -f ]` the
      # same way openclaw-prepare-secrets does for its reused secrets — a
      # missing source must not fail the unit and block the VM.

      # IMAP/SMTP password (reuse email-tester-imap-password — same Dovecot passdb)
      IMAP_PASS_SRC="${config.sops.secrets."email-tester-imap-password".path}"
      if [ -f "$IMAP_PASS_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$IMAP_PASS_SRC" "${secretsStagingDir}/imap-password"
        echo "IMAP credentials staged"
      fi

      # Radicale CardDAV password (reuse vdirsyncer-johnw radicale credentials)
      RADICALE_PASS_SRC="${config.sops.secrets."vdirsyncer-johnw/radicale-password".path}"
      if [ -f "$RADICALE_PASS_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$RADICALE_PASS_SRC" "${secretsStagingDir}/radicale-password"
        echo "Radicale CardDAV credentials staged"
      fi

      # Home Assistant long-lived access token (mcp-proxy bridge → /api/mcp)
      HA_TOKEN_SRC="${config.sops.secrets."openclaw/home-assistant-token".path}"
      if [ -f "$HA_TOKEN_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$HA_TOKEN_SRC" "${secretsStagingDir}/home-assistant-token"
        echo "Home Assistant token staged"
      fi

      # org PostgreSQL password (read-only role `openclaw`)
      ORG_DB_PASS_SRC="${config.sops.secrets."openclaw/org-db-password".path}"
      if [ -f "$ORG_DB_PASS_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$ORG_DB_PASS_SRC" "${secretsStagingDir}/org-db-password"
        echo "Org database password staged"
      fi

      # Perplexity API key (perplexity-mcp.py wrapper exports it from this file)
      PERPLEXITY_KEY_SRC="${config.sops.secrets."openclaw/perplexity-api-key".path}"
      if [ -f "$PERPLEXITY_KEY_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$PERPLEXITY_KEY_SRC" "${secretsStagingDir}/perplexity-api-key"
        echo "Perplexity API key staged"
      fi

      echo "Hermes secrets staged to ${secretsStagingDir}"
    '';
  };

  # Restart the host's microvm@hermes service whenever models.nix changes,
  # so a `nixos-rebuild switch` propagates new model selections into the
  # running VM without manual intervention.
  systemd.services."microvm@hermes".restartTriggers = [
    (builtins.toJSON { agent = models.llm.agent; })
  ];

  # ---- microvm.nix declaration ----
  microvm.vms.hermes = {
    autostart = true;
    config = {
      imports = [ ./hermes-vm.nix ];
      _module.args = {
        inherit
          bridgeAddr
          vmAddr
          vmHostname
          hermesUid
          hermesGid
          stateDir
          tapName
          ;
        # Secrets share root (guest mounts this as /run/hermes-secrets) and
        # the comma-joined DNAT port set (guest threads it into its
        # OUTPUT-DNAT rule, mirroring openclaw-vm.nix's dnatPortList arg).
        # Both inherit the single let-block source of truth so the host
        # firewall rules and the guest DNAT can never drift.
        inherit secretsStagingDir dnatPortList;
      };
    };
    specialArgs = { inherit inputs system; };
  };

  # Both the per-VM `autostart = true` (above) and this target list
  # are required by microvm.nix — the former installs the systemd unit
  # link, the latter drives microvms.target boot ordering. Don't
  # consolidate.
  microvm = {
    autostart = [ "hermes" ];
  };
}
