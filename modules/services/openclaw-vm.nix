# Guest NixOS configuration for the OpenClaw microVM.
# This file is imported by openclaw-microvm.nix via microvm.vms.openclaw.config.
# Variables are passed from the host module via specialArgs.
{
  config,
  pkgs,
  lib,
  openclawVmArgs,
  ...
}:

let
  inherit (openclawVmArgs)
    openclawPkg
    mcporterPkg
    bridgeAddr
    vmCidr
    stateDir
    secretsStagingDir
    dnatPortList
    servicePort
    tapName
    vmHostname
    vmVcpu
    vmMem
    openclawUid
    openclawGid
    ;

  openclawDir = "${stateDir}/.openclaw";
in
{
  networking.hostName = vmHostname;
  system.stateVersion = "25.11";

  # ========================================================================
  # microvm hardware configuration
  # ========================================================================

  microvm = {
    # QEMU is the safest hypervisor for aarch64 Asahi with 16K pages.
    hypervisor = "qemu";

    vcpu = vmVcpu;
    mem = vmMem;

    shares = [
      {
        proto = "virtiofs";
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
      }
      {
        proto = "virtiofs";
        tag = "state";
        source = stateDir;
        mountPoint = stateDir;
      }
      {
        proto = "virtiofs";
        tag = "secrets";
        source = secretsStagingDir;
        mountPoint = "/run/openclaw-secrets";
      }
    ];

    writableStoreOverlay = "/nix/.rw-store";

    interfaces = [
      {
        type = "tap";
        id = tapName;
        mac = "02:00:00:0c:1a:01";
      }
    ];
  };

  # ========================================================================
  # Guest networking
  # ========================================================================

  # Disable IPv6 — host NAT is IPv4 only, and Node.js undici's
  # Happy Eyeballs algorithm causes connection delays when IPv6 is
  # available but doesn't work.
  networking.enableIPv6 = false;
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
    # Allow routing 127.0.0.0/8 traffic on non-loopback interfaces.
    # Required for the nftables OUTPUT DNAT that rewrites localhost
    # connections to the host bridge IP — without this, the kernel
    # refuses to route packets with source 127.0.0.1 via eth0.
    "net.ipv4.conf.all.route_localnet" = 1;
  };

  # Static IP via systemd-networkd
  systemd.network.enable = true;
  systemd.network.networks."10-eth" = {
    matchConfig.Name = "e*";
    addresses = [ { Address = vmCidr; } ];
    routes = [ { Gateway = bridgeAddr; } ];
  };

  # DNS: use the host bridge IP (Technitium on host binds to 0.0.0.0:53)
  networking.nameservers = [ bridgeAddr ];

  # Override *.vulcan.lan hostnames to point to the bridge gateway so the
  # AI agent reaches host services directly. The egress filter blocks
  # 192.168.0.0/16, so normal DNS resolution (192.168.1.2) is unreachable.
  networking.hosts = {
    ${bridgeAddr} = [
      "hass.vulcan.lan"
      "qdrant.vulcan.lan"
      "litellm.vulcan.lan"
    ];
  };

  # ========================================================================
  # Guest-side DNAT (stage 1 of two-stage DNAT)
  # ========================================================================
  # Rewrite outgoing connections from 127.0.0.1:PORT to the host bridge IP
  # so that OpenClaw's existing config (which uses localhost) works unchanged.

  networking.nftables.enable = true;

  # NAT table: rewrite localhost connections to the host bridge IP so
  # OpenClaw's existing 127.0.0.1 config works unchanged.
  networking.nftables.tables.openclaw-dnat = {
    family = "ip";
    content = ''
      chain output {
        type nat hook output priority -100; policy accept;
        # Redirect localhost-bound traffic for host services to bridge gateway
        ip daddr 127.0.0.1 tcp dport { ${dnatPortList} } dnat to ${bridgeAddr}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Rewrite source 127.0.0.1 → VM eth0 IP for DNAT'ed packets.
        # Without this, Linux refuses to route loopback-sourced packets
        # out of a non-loopback interface.
        oifname "e*" ip saddr 127.0.0.0/8 masquerade
      }
    '';
  };

  # Filter table: block all private-network access except the explicitly
  # allowed host services (DNS + DNAT ports). Internet access is preserved.
  networking.nftables.tables.openclaw-egress = {
    family = "ip";
    content = ''
      chain output {
        type filter hook output priority 0; policy accept;

        # Allow established/related traffic
        ct state established,related accept

        # Allow DNS (UDP+TCP) to bridge gateway
        ip daddr ${bridgeAddr} udp dport 53 accept
        ip daddr ${bridgeAddr} tcp dport 53 accept

        # Allow DNAT service ports to bridge gateway
        ip daddr ${bridgeAddr} tcp dport { ${dnatPortList} } accept

        # Block all other traffic to RFC 1918 private networks
        ip daddr 10.0.0.0/8 drop
        ip daddr 172.16.0.0/12 drop
        ip daddr 192.168.0.0/16 drop
      }
    '';
  };

  # ========================================================================
  # Guest user (pinned UID/GID to match host for virtiofs)
  # ========================================================================

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

  # ========================================================================
  # Guest tmpfiles
  # ========================================================================
  # Safe "d" directive only — preserves contents.

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 openclaw openclaw -"
  ];

  # ========================================================================
  # OpenClaw systemd service
  # ========================================================================
  # NO systemd hardening needed — the VM IS the isolation boundary.

  systemd.services.openclaw = {
    description = "OpenClaw AI Gateway";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      nodejs_22
      pnpm
      git
      curl
      mcporterPkg
      coreutils
      bashInteractive
      gnugrep
      gnused
      jq
      socat
    ];

    environment = {
      HOME = stateDir;
      NODE_ENV = "production";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
    };

    serviceConfig = {
      User = "openclaw";
      Group = "openclaw";
      Type = "simple";
      Restart = "always";
      RestartSec = "10s";

      WorkingDirectory = stateDir;

      # Bind to LAN (all local interfaces) — the VM IS the isolation boundary.
      # Valid --bind modes: loopback, lan, tailnet, auto, custom
      ExecStart = "${openclawPkg}/bin/openclaw gateway run --bind lan --port ${toString servicePort} --auth token";

      # Log stdout/stderr to the shared state directory for host-side debugging
      StandardOutput = "append:${stateDir}/.openclaw/logs/gateway-vm.log";
      StandardError = "append:${stateDir}/.openclaw/logs/gateway-vm.err.log";

      # Resource limits
      MemoryMax = "4G";
      CPUQuota = "400%";
      TasksMax = 512;
      LimitNOFILE = 65536;
      LimitNPROC = 512;
    };

    preStart = ''
      # Create directory structure for OpenClaw state
      mkdir -p ${openclawDir}/agents/main/sessions
      mkdir -p ${openclawDir}/logs
      mkdir -p ${openclawDir}/cron
      mkdir -p ${openclawDir}/delivery-queue
      mkdir -p ${openclawDir}/workspace

      # Copy secret from virtiofs-mounted staging directory
      cp -f /run/openclaw-secrets/openclaw-config ${openclawDir}/openclaw.json

      # Patch runtime config for the VM environment:
      #  - CORS: allow host-header origin fallback (VM is the isolation boundary)
      #  - Embedding URL: rewrite localhost:8080 → localhost:4000 (LiteLLM)
      ${pkgs.jq}/bin/jq '
        .gateway.controlUi = {"dangerouslyAllowHostHeaderOriginFallback": true}
        | walk(if type == "string" then gsub("http://localhost:8080"; "http://127.0.0.1:4000") else . end)
      ' ${openclawDir}/openclaw.json > ${openclawDir}/openclaw.json.tmp
      mv ${openclawDir}/openclaw.json.tmp ${openclawDir}/openclaw.json

      chmod 600 ${openclawDir}/openclaw.json

      # Set up mcporter config symlink if present
      if [ -d "${openclawDir}/.mcporter" ]; then
        ln -sfn ${openclawDir}/.mcporter ${stateDir}/.mcporter
      fi

      # Rebuild sharp native module for aarch64-linux if needed
      SHARP_REL="${openclawDir}/workspace/skills/memory-qdrant/node_modules/sharp/build/Release"
      if [ -d "$SHARP_REL" ] && \
         [ ! -f "$SHARP_REL/sharp-linux-arm64v8.node" ]; then
        echo "Installing sharp linux-arm64 binary..."
        cd "${openclawDir}/workspace/skills/memory-qdrant"
        ${pkgs.nodejs_22}/bin/npm rebuild sharp 2>&1 || true
        cd "${stateDir}"
      fi
    '';
  };

  # ========================================================================
  # Guest firewall
  # ========================================================================

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ servicePort ];
  };

  # ========================================================================
  # Network isolation diagnostic (runs once at boot, writes to shared dir)
  # ========================================================================

  systemd.services.network-diag = {
    description = "Network isolation connectivity test";
    after = [
      "network-online.target"
      "nftables.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      curl
      nftables
      iproute2
      coreutils
    ];
    script = ''
      OUT="${stateDir}/.openclaw/netdiag.txt"
      echo "=== Network Isolation Diagnostic ===" > "$OUT"
      echo "Time: $(date -u)" >> "$OUT"
      echo "" >> "$OUT"

      # Dump guest nftables rules
      echo "--- Guest nftables rules ---" >> "$OUT"
      nft list ruleset >> "$OUT" 2>&1
      echo "" >> "$OUT"

      # Dump guest routing table
      echo "--- Guest routes ---" >> "$OUT"
      ip route >> "$OUT" 2>&1
      echo "" >> "$OUT"

      # Dump /etc/hosts
      echo "--- Guest /etc/hosts ---" >> "$OUT"
      cat /etc/hosts >> "$OUT" 2>&1
      echo "" >> "$OUT"

      echo "--- Connectivity Tests ---" >> "$OUT"

      # MUST BE BLOCKED: 192.168.1.2 (any port)
      for port in 443 993 25 80 22; do
        if curl -sk --connect-timeout 3 "https://192.168.1.2:$port/" >/dev/null 2>&1; then
          echo "FAIL: 192.168.1.2:$port REACHABLE (should be blocked)" >> "$OUT"
        else
          echo "PASS: 192.168.1.2:$port blocked" >> "$OUT"
        fi
      done

      # MUST BE BLOCKED: other 192.168.x.x hosts
      for host in 192.168.1.4 192.168.1.5 192.168.3.16; do
        if curl -sk --connect-timeout 3 "https://$host:443/" >/dev/null 2>&1; then
          echo "FAIL: $host:443 REACHABLE (should be blocked)" >> "$OUT"
        else
          echo "PASS: $host:443 blocked" >> "$OUT"
        fi
      done

      # MUST WORK: DNS resolution
      echo "--- DNS Tests ---" >> "$OUT"
      DNS_RESULT=$(${pkgs.dig}/bin/dig +short +timeout=3 @${bridgeAddr} example.com A 2>&1)
      if [ -n "$DNS_RESULT" ] && echo "$DNS_RESULT" | grep -qE '^[0-9]+\.[0-9]+'; then
        echo "PASS: DNS resolution works (example.com -> $DNS_RESULT)" >> "$OUT"
      else
        echo "FAIL: DNS resolution broken (result: $DNS_RESULT)" >> "$OUT"
      fi

      # MUST WORK: bridge gateway services (TCP connect test)
      echo "--- Bridge Gateway Services ---" >> "$OUT"
      for port in 443 4000 6333 8123; do
        if curl -sk --connect-timeout 3 "https://${bridgeAddr}:$port/" >/dev/null 2>&1 || \
           curl -s --connect-timeout 3 "http://${bridgeAddr}:$port/" >/dev/null 2>&1; then
          echo "PASS: ${bridgeAddr}:$port reachable (HTTP)" >> "$OUT"
        else
          # Raw TCP connect test using /dev/tcp
          if (echo > /dev/tcp/${bridgeAddr}/$port) 2>/dev/null; then
            echo "PASS: ${bridgeAddr}:$port reachable (TCP)" >> "$OUT"
          else
            echo "WARN: ${bridgeAddr}:$port not reachable" >> "$OUT"
          fi
        fi
      done

      # MUST WORK: internet by IP (bypasses DNS)
      echo "--- Internet Tests ---" >> "$OUT"
      if curl -s --connect-timeout 5 "http://93.184.215.14/" >/dev/null 2>&1; then
        echo "PASS: Internet by IP (93.184.215.14) reachable" >> "$OUT"
      else
        echo "FAIL: Internet by IP (93.184.215.14) NOT reachable" >> "$OUT"
      fi

      # Internet by name (tests DNS + connectivity)
      if curl -s --connect-timeout 5 "https://example.com" >/dev/null 2>&1; then
        echo "PASS: Internet by name (example.com) reachable" >> "$OUT"
      else
        echo "FAIL: Internet by name (example.com) NOT reachable" >> "$OUT"
      fi

      # MUST NOT WORK: localhost:8080 (old embedding server)
      echo "--- Negative Tests ---" >> "$OUT"
      if curl -s --connect-timeout 3 "http://127.0.0.1:8080/" >/dev/null 2>&1; then
        echo "INFO: 127.0.0.1:8080 reachable (unexpected)" >> "$OUT"
      else
        echo "PASS: 127.0.0.1:8080 not reachable (correct)" >> "$OUT"
      fi

      echo "" >> "$OUT"
      echo "=== Done ===" >> "$OUT"
    '';
  };

  # Allow password-less root login on serial console for debugging.
  # The VM is only accessible from the host via the bridge network;
  # this is safe because the serial console is only reachable by root
  # on the host (via the microvm journal).
  users.users.root.initialHashedPassword = "";
}
