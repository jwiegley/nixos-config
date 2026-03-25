{
  inputs,
  config,
  lib,
  pkgs,
  system,
  ...
}:

let
  # ============================================================================
  # Configuration Constants
  # ============================================================================
  # All tunables are defined here for easy reference and modification.

  # -- Network topology --
  bridgeName = "br-openclaw";
  tapName = "vm-openclaw";
  bridgeAddr = "10.99.0.1";
  vmAddr = "10.99.0.2";
  bridgeCidr = "${bridgeAddr}/30";
  vmCidr = "${vmAddr}/30";
  externalInterface = "end0";

  # -- VM hardware --
  vmVcpu = 4;
  vmMem = 4096; # MiB
  vmHostname = "openclaw-vm";

  # -- Service --
  servicePort = 18789;

  # -- User identity (must match host for virtiofs ownership) --
  openclawUid = 916;
  openclawGid = 908;

  # -- Directories --
  stateDir = "/var/lib/openclaw";
  openclawDir = "${stateDir}/.openclaw";
  microvmBase = "/var/lib/microvms/openclaw";
  secretsStagingDir = "${microvmBase}/secrets";

  # -- Packages from llm-agents flake input --
  openclawPkg = inputs.llm-agents.packages.${system}.openclaw;
  mcporterPkg = inputs.llm-agents.packages.${system}.mcporter;
  claudeCodePkg = pkgs.claude-code; # from overlay (llm-agents + USE_BUILTIN_RIPGREP patch)

  # -- Host-side loopback services that the VM needs to reach --
  # Strategy: guest OUTPUT DNAT 127.0.0.1:port -> 10.99.0.1:port
  #           host  PREROUTING DNAT 10.99.0.1:port -> 127.0.0.1:port on br-openclaw
  #           host  route_localnet=1 on br-openclaw
  dnatPorts = [
    443 # nginx (HTTPS) — needed for HA and other proxied services
    993 # Dovecot IMAPS — VM accesses host Dovecot via DNAT
    2525 # Postfix plain SMTP — VM sends mail (mynetworks, no TLS)
    4000 # LiteLLM
    5232 # Radicale CardDAV — VM accesses host Radicale via DNAT
    6333 # Qdrant HTTP REST API
    6334 # Qdrant gRPC API
    6335 # Qdrant inference bridge
    8123 # Home Assistant (direct HTTP)
  ];

  # Helper: format a list of ports for nftables "dnat to" rules
  dnatPortList = lib.concatStringsSep ", " (map toString dnatPorts);

  # Helper: individual iptables DNAT rules for host PREROUTING
  hostDnatRules = lib.concatMapStringsSep "\n" (port: ''
    iptables -t nat -A PREROUTING -i ${bridgeName} -d ${bridgeAddr} -p tcp --dport ${toString port} -j DNAT --to-destination 127.0.0.1:${toString port}
  '') dnatPorts;

  hostDnatCleanupRules = lib.concatMapStringsSep "\n" (port: ''
    iptables -t nat -D PREROUTING -i ${bridgeName} -d ${bridgeAddr} -p tcp --dport ${toString port} -j DNAT --to-destination 127.0.0.1:${toString port} 2>/dev/null || true
  '') dnatPorts;

in
{
  # ============================================================================
  # OpenClaw AI Gateway — microVM isolation
  # ============================================================================
  #
  # Architecture overview:
  #
  #   Host (vulcan)                           Guest VM (openclaw-vm)
  #   ─────────────                           ──────────────────────
  #   br-openclaw 10.99.0.1/30  <──TAP──>    eth0 10.99.0.2/30
  #         │                                     │
  #         ├── NAT (masquerade) ──> end0         ├── OpenClaw :18789
  #         ├── DNAT 10.99.0.1:P -> 127.0.0.1:P  ├── nftables DNAT
  #         │   (route_localnet=1)                │   127.0.0.1:P -> 10.99.0.1:P
  #         │                                     │
  #   Qdrant, LiteLLM, llama-swap,          virtiofs mounts:
  #   Dovecot on 127.0.0.1                   /nix/.ro-store (ro-store)
  #         │                                 /var/lib/openclaw (state)
  #   nginx proxy ──> 10.99.0.2:18789        /run/openclaw-secrets (secrets)
  #                                           /run/claude-host-config (claude-config, ro)
  #
  # The VM provides full kernel-level isolation: separate network namespace,
  # filesystem namespace, and process tree. No systemd hardening needed
  # inside the guest because the hypervisor IS the sandbox.
  #
  # Network: dedicated /30 bridge, NAT for internet, two-stage DNAT for
  # loopback service access. The guest's existing 127.0.0.1 config works
  # unchanged because guest-side nftables rewrites outgoing localhost
  # connections to the bridge gateway.
  #
  # State: /var/lib/openclaw is shared via virtiofs from host, preserving
  # ZFS snapshot capability. No disk image volumes needed.
  #
  # Secrets: SOPS decrypts on host, a prepare-secrets oneshot copies to a
  # staging directory, which is shared via virtiofs to the guest.

  # ============================================================================
  # Section 1: Host User/Group (pinned IDs for virtiofs ownership)
  # ============================================================================

  users.users.openclaw = {
    isSystemUser = true;
    uid = openclawUid;
    group = "openclaw";
    home = stateDir;
    shell = pkgs.bashInteractive;
    description = "OpenClaw AI Gateway service user";
  };
  users.groups.openclaw = {
    gid = openclawGid;
  };

  # ============================================================================
  # Section 2: SOPS Secrets
  # ============================================================================
  # The full openclaw.json config is stored as a multiline string value in
  # secrets.yaml under the "openclaw/config" key. SOPS decrypts it at
  # activation time; the prepare-secrets service copies it to the staging
  # directory for virtiofs sharing into the VM.

  sops.secrets."openclaw/config" = {
    owner = "openclaw";
    group = "openclaw";
    mode = "0400";
    restartUnits = [ "microvm@openclaw.service" ];
  };

  sops.secrets."openclaw/gcp-oauth-keys" = {
    owner = "openclaw";
    group = "openclaw";
    mode = "0400";
    restartUnits = [ "microvm@openclaw.service" ];
  };

  sops.secrets."openclaw/claude-code-token" = {
    owner = "openclaw";
    group = "openclaw";
    mode = "0400";
    restartUnits = [ "microvm@openclaw.service" ];
  };

  # ============================================================================
  # Section 3: Host Networking — Bridge, TAP, NetworkManager coexistence
  # ============================================================================

  # Tell NetworkManager to ignore the bridge and TAP interfaces.
  # systemd-networkd manages these instead, coexisting with NM.
  networking.networkmanager.unmanaged = [
    "interface-name:${bridgeName}"
    "interface-name:${tapName}"
  ];

  # Enable systemd-networkd for bridge + TAP management.
  # We do NOT set networking.useNetworkd = true (that would conflict with NM).
  systemd.network.enable = true;

  # Prevent systemd-networkd-wait-online from timing out.
  # It waits for ALL networkd-managed interfaces, but our bridge may not have
  # a carrier until the VM starts. Tell it to only require the bridge to be
  # "degraded" (has an IP but no carrier) or ignore it entirely.
  systemd.network.wait-online.anyInterface = true;

  # Bridge netdev
  systemd.network.netdevs."50-${bridgeName}".netdevConfig = {
    Kind = "bridge";
    Name = bridgeName;
  };

  # Bridge network — assign the host-side IP.
  # ConfigureWithoutCarrier allows the bridge to come up before the TAP
  # is attached (the VM may start later).
  systemd.network.networks."50-${bridgeName}" = {
    matchConfig.Name = bridgeName;
    addresses = [ { Address = bridgeCidr; } ];
    networkConfig.ConfigureWithoutCarrier = true;
  };

  # TAP interface auto-joins the bridge when it appears.
  systemd.network.networks."51-${tapName}" = {
    matchConfig.Name = tapName;
    networkConfig.Bridge = bridgeName;
  };

  # ============================================================================
  # Section 4: NAT — VM internet access
  # ============================================================================
  # Masquerade traffic from the /30 bridge out through the external interface.

  networking.nat = {
    enable = true;
    internalInterfaces = [ bridgeName ];
    externalInterface = externalInterface;
  };

  # ============================================================================
  # Section 5: Host-side DNAT for loopback service access
  # ============================================================================
  # The VM needs to reach host services bound to 127.0.0.1 (Qdrant, LiteLLM,
  # llama-swap, Dovecot). We use a two-stage DNAT approach:
  #
  #   1. Guest nftables: OUTPUT DNAT 127.0.0.1:PORT -> 10.99.0.1:PORT
  #      (so OpenClaw's existing localhost config works unchanged)
  #   2. Host iptables: PREROUTING DNAT 10.99.0.1:PORT -> 127.0.0.1:PORT
  #      on the br-openclaw interface
  #   3. Host sysctl: route_localnet=1 on br-openclaw allows routing to
  #      127.0.0.0/8 from the bridge interface
  #
  # This service manages the host-side (stage 2) iptables rules.

  boot.kernel.sysctl."net.ipv4.conf.${bridgeName}.route_localnet" = 1;

  systemd.services.openclaw-host-dnat = {
    description = "DNAT rules for OpenClaw VM to reach host loopback services";
    wantedBy = [ "microvm@openclaw.service" ];
    before = [ "microvm@openclaw.service" ];
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
      # Stage 2: host PREROUTING DNAT — rewrite bridge-destined packets to loopback
      ${hostDnatRules}

      # Allow forwarded return traffic from loopback back to the VM
      iptables -A FORWARD -i ${bridgeName} -o ${bridgeName} -j ACCEPT 2>/dev/null || true

      echo "OpenClaw host DNAT rules installed for ports: ${dnatPortList}"
    '';

    preStop = ''
      ${hostDnatCleanupRules}
      iptables -D FORWARD -i ${bridgeName} -o ${bridgeName} -j ACCEPT 2>/dev/null || true
    '';
  };

  # ============================================================================
  # Section 6: Egress Logging
  # ============================================================================
  # Log new outbound connections from the VM bridge for audit purposes.
  # Uses iptables FORWARD chain (not nftables) to stay consistent with the
  # host's iptables-nft backend.

  networking.firewall.extraCommands = ''
    # ── OpenClaw network isolation ──
    # Only allow VM traffic to the bridge gateway (${bridgeAddr}) or
    # loopback (127.0.0.1, post-DNAT rewrite) on explicitly allowed ports.
    # All other destinations — including other hosts on 192.168.0.0/16 —
    # are dropped.

    iptables -N openclaw-isolate 2>/dev/null || iptables -F openclaw-isolate

    # DNS to bridge gateway (Technitium binds to 0.0.0.0:53)
    iptables -A openclaw-isolate -d ${bridgeAddr} -p tcp --dport 53 -j RETURN
    iptables -A openclaw-isolate -d ${bridgeAddr} -p udp --dport 53 -j RETURN

    # DNAT service ports — allow to bridge (direct) and loopback (post-DNAT)
    ${lib.concatMapStringsSep "\n    " (
      port:
      "iptables -A openclaw-isolate -d ${bridgeAddr} -p tcp --dport ${toString port} -j RETURN\n    iptables -A openclaw-isolate -d 127.0.0.1 -p tcp --dport ${toString port} -j RETURN"
    ) dnatPorts}

    # Drop everything else from the VM
    iptables -A openclaw-isolate -j DROP
    iptables -I nixos-fw 3 -i ${bridgeName} -j openclaw-isolate

    # FORWARD chain: block private-network-bound traffic (NAT/routing path).
    iptables -A FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP

    # Egress logging — log new outbound connections from the bridge
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "openclaw-egress: " --log-level info
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i ${bridgeName} -j openclaw-isolate 2>/dev/null || true
    iptables -F openclaw-isolate 2>/dev/null || true
    iptables -X openclaw-isolate 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "openclaw-egress: " --log-level info 2>/dev/null || true
  '';

  # ============================================================================
  # Section 7: Firewall — allow DNS from VM to host
  # ============================================================================
  # Technitium DNS on the host binds to 0.0.0.0:53, so the VM can use the
  # bridge IP (10.99.0.1) as its DNS server. We need to allow DNS traffic
  # on the bridge interface.

  networking.firewall.interfaces.${bridgeName} = {
    allowedUDPPorts = [ 53 ]; # DNS
    # DNS over TCP + DNAT'ed host service ports.
    # After PREROUTING DNAT rewrites 10.99.0.1:PORT → 127.0.0.1:PORT,
    # the packet still arrives on br-openclaw, so the INPUT chain must
    # allow these ports on this interface.
    allowedTCPPorts = [ 53 ] ++ dnatPorts;
  };

  # ============================================================================
  # Section 8: Secrets Preparation
  # ============================================================================
  # SOPS decrypts "openclaw/config" on the host at activation time.
  # This oneshot service copies the decrypted secret to a staging directory
  # that is shared into the VM via virtiofs.

  systemd.services.openclaw-prepare-secrets = {
    description = "Stage SOPS secrets for OpenClaw microVM";
    wantedBy = [ "microvm@openclaw.service" ];
    before = [ "microvm@openclaw.service" ];
    after = [ "sops-nix.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Create staging directory (owned by root; virtiofs handles access)
      mkdir -p "${secretsStagingDir}"
      chmod 0755 "${secretsStagingDir}"

      # Copy the SOPS-decrypted openclaw config
      cp -f "${config.sops.secrets."openclaw/config".path}" "${secretsStagingDir}/openclaw-config"
      chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/openclaw-config"
      chmod 0400 "${secretsStagingDir}/openclaw-config"

      # Copy Google Calendar OAuth credentials
      GCP_OAUTH_SRC="${config.sops.secrets."openclaw/gcp-oauth-keys".path}"
      if [ -f "$GCP_OAUTH_SRC" ]; then
        cp -f "$GCP_OAUTH_SRC" "${secretsStagingDir}/gcp-oauth.keys.json"
        chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/gcp-oauth.keys.json"
        chmod 0400 "${secretsStagingDir}/gcp-oauth.keys.json"
        echo "Google Calendar OAuth credentials staged"
      fi

      # Stage IMAP password (reuse email-tester-imap-password — same Dovecot passdb)
      IMAP_PASS_SRC="${config.sops.secrets."email-tester-imap-password".path}"
      if [ -f "$IMAP_PASS_SRC" ]; then
        cp -f "$IMAP_PASS_SRC" "${secretsStagingDir}/imap-password"
        chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/imap-password"
        chmod 0400 "${secretsStagingDir}/imap-password"
        echo "IMAP credentials staged"
      fi

      # Stage Radicale CardDAV password (reuse vdirsyncer-johnw radicale credentials)
      RADICALE_PASS_SRC="${config.sops.secrets."vdirsyncer-johnw/radicale-password".path}"
      if [ -f "$RADICALE_PASS_SRC" ]; then
        cp -f "$RADICALE_PASS_SRC" "${secretsStagingDir}/radicale-password"
        chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/radicale-password"
        chmod 0400 "${secretsStagingDir}/radicale-password"
        echo "Radicale CardDAV credentials staged"
      fi

      # Stage Claude Code API token from SOPS secret
      # (replaces the old approach of copying ~/.claude/.credentials.json from the host)
      cp -f "${
        config.sops.secrets."openclaw/claude-code-token".path
      }" "${secretsStagingDir}/claude-code-token"
      chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/claude-code-token"
      chmod 0400 "${secretsStagingDir}/claude-code-token"
      echo "Claude Code API token staged"

      # Stage Claude Code config (.claude.json — non-secret runtime config)
      CLAUDE_CONFIG="/home/johnw/.claude/.claude.json"
      if [ -f "$CLAUDE_CONFIG" ]; then
        cp -f "$CLAUDE_CONFIG" "${secretsStagingDir}/claude-config.json"
        chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/claude-config.json"
        chmod 0400 "${secretsStagingDir}/claude-config.json"
        echo "Claude Code config staged"
      fi

      # Stage Claude Code settings.json (mode 0600 on host, not readable via virtiofs)
      CLAUDE_SETTINGS="/home/johnw/.claude/settings.json"
      if [ -f "$CLAUDE_SETTINGS" ]; then
        cp -f "$CLAUDE_SETTINGS" "${secretsStagingDir}/claude-settings.json"
        chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/claude-settings.json"
        chmod 0400 "${secretsStagingDir}/claude-settings.json"
        echo "Claude Code settings staged"
      fi

      echo "OpenClaw secrets staged to ${secretsStagingDir}"
    '';
  };

  # ============================================================================
  # Section 9: State Directory
  # ============================================================================
  # Ensure the state directory exists with correct ownership on the host.
  # This uses the safe "d" directive (creates if missing, preserves contents).
  # NEVER use "D" for persistent data — see CLAUDE.md.

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 openclaw openclaw -"
  ];

  # ============================================================================
  # Section 10: Nix Store Optimisation Warning
  # ============================================================================
  # When sharing /nix/store via virtiofs, automatic store optimisation can
  # cause stale file handles inside the guest. Disable it.

  nix.optimise.automatic = false;

  # ============================================================================
  # Section 11: microVM Definition
  # ============================================================================

  microvm.vms.openclaw = {
    # Guest config is in a separate file to ensure clean NixOS evaluation
    # (inline configs can inherit host modules). Variables are passed via
    # specialArgs.
    specialArgs = {
      openclawVmArgs = {
        inherit openclawPkg mcporterPkg claudeCodePkg;
        inherit bridgeAddr vmCidr;
        inherit stateDir secretsStagingDir;
        inherit dnatPortList servicePort;
        inherit
          tapName
          vmHostname
          vmVcpu
          vmMem
          ;
        inherit openclawUid openclawGid;
      };
    };

    config = {
      imports = [ ./openclaw-vm.nix ];
    };

    autostart = true;
  };

  # Extend the default microvm startup timeout — the VM needs time to boot
  # the guest kernel, mount virtiofs shares, and start the OpenClaw service.
  systemd.services."microvm@openclaw".serviceConfig.TimeoutStartSec = "300";

  # ============================================================================
  # Section 12: Bootstrap TLS Certificate
  # ============================================================================
  # Self-signed certificate for openclaw.vulcan.lan (identical to previous module).
  # Replace with a proper step-ca cert:
  #   sudo /etc/nixos/certs/renew-certificate.sh "openclaw.vulcan.lan" \
  #     -o "/var/lib/nginx-certs" -d 365 --owner "nginx:nginx"

  systemd.services.openclaw-certificate = {
    description = "Generate OpenClaw TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [ pkgs.openssl ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/openclaw.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/openclaw.vulcan.lan.key"

      # Exit early if cert is valid for >30 days
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate valid for >30 days, skipping generation"
          exit 0
        fi
      fi

      # Create self-signed bootstrap certificate
      echo "Creating bootstrap self-signed certificate for openclaw.vulcan.lan"
      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=openclaw.vulcan.lan" \
        -addext "subjectAltName=DNS:openclaw.vulcan.lan"

      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Bootstrap cert created. Replace with step-ca cert:"
      echo "  sudo /etc/nixos/certs/renew-certificate.sh openclaw.vulcan.lan \\"
      echo "    -o /var/lib/nginx-certs -d 365 --owner nginx:nginx"
    '';
  };

  # ============================================================================
  # Section 13: Nginx Reverse Proxy (host side)
  # ============================================================================
  # Proxy target is now the VM's IP instead of 127.0.0.1.

  services.nginx.virtualHosts."openclaw.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/openclaw.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/openclaw.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://${vmAddr}:${toString servicePort}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        # Long timeouts for agent operations -- LLM interactions and
        # multi-step workflows can take minutes to complete
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}
