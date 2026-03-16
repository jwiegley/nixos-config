{
  inputs,
  config,
  lib,
  pkgs,
  system,
  ...
}:

let
  # Package references from llm-agents flake input
  openclawPkg = inputs.llm-agents.packages.${system}.openclaw;
  mcporterPkg = inputs.llm-agents.packages.${system}.mcporter;

  # Directory paths
  stateDir = "/var/lib/openclaw";
  openclawDir = "${stateDir}/.openclaw";
in
{
  # ============================================================================
  # OpenClaw AI Gateway
  # ============================================================================
  # OpenClaw is an AI agent gateway that orchestrates LLM interactions,
  # tool use, and multi-step agent workflows.
  #
  # Architecture:
  #   - Binds to loopback on port 18789 with token authentication
  #   - Nginx reverse proxy at openclaw.vulcan.lan (TLS)
  #   - State stored at /var/lib/openclaw/.openclaw/
  #   - Config injected from SOPS-encrypted secret
  #
  # Security model:
  #   - Runs as dedicated system user with no login shell
  #   - Strict filesystem isolation via TemporaryFileSystem + BindPaths:
  #     /var/lib is mounted as a read-only tmpfs (hiding all other services),
  #     then only /var/lib/openclaw is bind-mounted back as read-write.
  #     This provides kernel-level guarantee that OpenClaw cannot see or
  #     access any other service's state directory.
  #   - Full systemd hardening: no capabilities, syscall filtering, etc.
  #   - MemoryDenyWriteExecute disabled because V8 JIT requires W^X mappings
  #
  # Dependencies:
  #   - inputs.llm-agents provides openclaw and mcporter packages
  #   - SOPS secret "openclaw/config" contains the full openclaw.json

  # ============================================================================
  # System User
  # ============================================================================

  users.users.openclaw = {
    isSystemUser = true;
    group = "openclaw";
    home = stateDir;
    shell = pkgs.bashInteractive;
    description = "OpenClaw AI Gateway service user";
  };
  users.groups.openclaw = { };

  # ============================================================================
  # SOPS Secrets
  # ============================================================================
  # The full openclaw.json config is stored as a multiline string value in
  # secrets.yaml under the "openclaw/config" key. SOPS decrypts it at
  # activation time; the preStart script copies it into the state directory.

  sops.secrets."openclaw/config" = {
    owner = "openclaw";
    group = "openclaw";
    mode = "0400";
    restartUnits = [ "openclaw.service" ];
  };

  # ============================================================================
  # Systemd Service
  # ============================================================================

  systemd.services.openclaw = {
    description = "OpenClaw AI Gateway";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # Tools that OpenClaw needs available in PATH
    path = with pkgs; [
      nodejs_22
      pnpm
      git
      curl
      himalaya
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

      # Managed directories (systemd creates and sets ownership automatically)
      StateDirectory = "openclaw";
      CacheDirectory = "openclaw";
      LogsDirectory = "openclaw";
      RuntimeDirectory = "openclaw";

      ExecStart = "${openclawPkg}/bin/openclaw gateway run --bind loopback --port 18789 --auth token";

      # ==================================================================
      # Filesystem Isolation (kernel-level restriction)
      # ==================================================================
      # This is the KEY security feature: mount /var/lib as a read-only
      # tmpfs, which hides ALL other services' state directories from
      # this process. Then selectively bind-mount only our own state
      # directory back in. The kernel enforces this -- even if the process
      # were compromised, it physically cannot see other services' data.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      TemporaryFileSystem = "/var/lib:ro";
      BindPaths = [ stateDir ];
      BindReadOnlyPaths = [
        "/nix/store"
        "-/etc/resolv.conf"
        "-/etc/ssl/certs"
        "-/etc/hosts"
        "-/etc/nsswitch.conf"
        "-/run/systemd/resolve"
      ];

      # ==================================================================
      # Kernel Protection
      # ==================================================================
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;

      # ==================================================================
      # Privilege Restriction
      # ==================================================================
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";

      # ==================================================================
      # Network Restriction
      # ==================================================================
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
      ];

      # ==================================================================
      # Syscall Filtering
      # ==================================================================
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      SystemCallArchitectures = "native";

      # ==================================================================
      # Memory & Execution
      # ==================================================================
      # MemoryDenyWriteExecute is intentionally false:
      # V8 (Node.js) JIT compiler requires writable+executable memory
      # mappings (W^X). Enabling this would crash the process.
      MemoryDenyWriteExecute = false;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      RemoveIPC = true;
      UMask = "0077";

      # ==================================================================
      # Resource Limits
      # ==================================================================
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

      # Copy SOPS-decrypted config into the state directory
      # The secret is decrypted by sops-nix at activation time; we copy
      # it here so OpenClaw can read it from its expected location.
      cp -f ${config.sops.secrets."openclaw/config".path} ${openclawDir}/openclaw.json
      chmod 600 ${openclawDir}/openclaw.json

      # Set up himalaya config symlink if present
      # (himalaya is used for email integration)
      if [ -d "${openclawDir}/.himalaya" ]; then
        mkdir -p ${stateDir}/.config/himalaya
        ln -sf ${openclawDir}/.himalaya/config.toml \
          ${stateDir}/.config/himalaya/config.toml
      fi

      # Set up mcporter config symlink if present
      # (mcporter is an MCP transport tool from llm-agents)
      if [ -d "${openclawDir}/.mcporter" ]; then
        ln -sfn ${openclawDir}/.mcporter ${stateDir}/.mcporter
      fi

      # Rebuild sharp native module for aarch64-linux if needed
      # (memory-qdrant plugin uses sharp for image processing)
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

  # ============================================================================
  # Bootstrap TLS Certificate
  # ============================================================================
  # Self-signed certificate for openclaw.vulcan.lan
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
  # Nginx Reverse Proxy
  # ============================================================================

  services.nginx.virtualHosts."openclaw.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/openclaw.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/openclaw.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:18789";
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

  # ============================================================================
  # Firewall
  # ============================================================================
  # Allow port 18789 on loopback only (nginx proxies external traffic)

  networking.firewall.interfaces."lo".allowedTCPPorts = [
    18789 # OpenClaw AI Gateway
  ];

  # ============================================================================
  # Tmpfiles
  # ============================================================================
  # Ensure the state directory exists with correct ownership

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 openclaw openclaw -"
  ];
}
