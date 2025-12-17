{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Windows 11 ARM container for running Windows applications
  # Uses dockurr/windows-arm with KVM acceleration
  # https://github.com/dockur/windows-arm

  # Quadlet container configuration
  virtualisation.quadlet.containers.windows11 = {
    # Manual start (don't auto-start on boot due to high memory usage)
    autoStart = false;

    containerConfig = {
      image = "docker.io/dockurr/windows-arm:latest";

      # Environment variables
      environments = {
        VERSION = "11"; # Windows 11 Pro
        CPU_CORES = "4"; # Allocate 4 CPU cores
        RAM_SIZE = "8G"; # Allocate 8GB RAM
        DISK_SIZE = "128G"; # 128GB virtual disk
        # Note: DHCP=Y removed - macvlan+macvtap doesn't work properly with Podman
        # Windows uses NAT through the container (passt user-mode networking)
        USER_PORTS = "3389"; # Forward RDP port to Windows via passt
      };

      # Port mappings - noVNC and RDP on localhost (nginx proxies externally)
      publishPorts = [
        "127.0.0.1:8006:8006/tcp" # Web interface (noVNC)
        "127.0.0.1:13389:3389/tcp" # RDP mapped to 13389 (nginx proxies 3389->13389)
      ];

      # Volume mounts
      volumes = [
        "/var/lib/windows:/storage" # Persistent Windows installation
        "/var/lib/windows/shared:/shared:z" # Shared folder for CTA installer
      ];

      # Device passthrough and capabilities via podmanArgs
      podmanArgs = [
        "--device=/dev/kvm" # KVM acceleration for virtualization
        "--device=/dev/net/tun" # TUN device for networking
        "--cap-add=NET_ADMIN" # Network administration capability
        "--stop-timeout=120" # Allow 2 minutes for graceful Windows shutdown
      ];

      # Use default podman bridge network (NAT mode)
      # Note: macvlan removed - doesn't work with nested macvtap for QEMU
    };

    # Systemd unit configuration
    unitConfig = {
      Description = "Windows 11 ARM Container for CTA Software";
      After = [ "podman.service" ];
      Wants = [ "podman.service" ];
    };

    # Systemd service configuration
    serviceConfig = {
      # Restart policy - only restart on failure, not when manually stopped
      Restart = "on-failure";
      RestartSec = "30s";

      # Timeout for stopping (allow Windows to shut down gracefully)
      TimeoutStopSec = "180s";

      # Exit code 143 (SIGTERM) is a successful stop for containers
      SuccessExitStatus = "143";

      # Runs as root by default (required for KVM device access)
      # No explicit User/Group needed - quadlet system containers run as root
    };
  };

  # Ensure storage directories exist with correct permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/windows 0755 root root -"
    "d /var/lib/windows/shared 0755 root root -"
  ];

  # Nginx reverse proxy for web interface
  services.nginx.virtualHosts."windows.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/windows.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/windows.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:8006/";
      proxyWebsockets = true;
      extraConfig = ''
        # Increase timeouts for long-running connections
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;

        # No buffering for WebSocket
        proxy_buffering off;
      '';
    };
  };

  # Generate SSL certificate for web interface
  systemd.services.windows-certificate = {
    description = "Generate Windows container TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [
      pkgs.openssl
      pkgs.step-cli
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/windows.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/windows.vulcan.lan.key"

      # Check if certificate exists and is valid for at least 30 days
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Generate certificate using Step CA
      echo "Generating certificate for windows.vulcan.lan"
      if ! /etc/nixos/certs/renew-certificate.sh "windows.vulcan.lan" \
        -o "$CERT_DIR" \
        -d 365 \
        --owner "nginx:nginx" \
        --cert-perms "644" \
        --key-perms "600"; then

        # Fallback to self-signed if Step CA unavailable
        echo "Step CA unavailable, creating self-signed certificate"
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
          -keyout "$KEY_FILE" \
          -out "$CERT_FILE" \
          -days 365 \
          -nodes \
          -subj "/CN=windows.vulcan.lan" \
          -addext "subjectAltName=DNS:windows.vulcan.lan"

        chmod 644 "$CERT_FILE"
        chmod 600 "$KEY_FILE"
        chown nginx:nginx "$CERT_FILE" "$KEY_FILE"
      fi

      echo "Certificate generated successfully"
    '';
  };

  # Open firewall for podman interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    8006
    13389
  ];

  # Open firewall for external RDP access
  networking.firewall.allowedTCPPorts = [ 3389 ];

  # Nginx stream proxy for RDP (TCP passthrough)
  # This allows external RDP clients to connect via windows.vulcan.lan:3389
  # External 3389 -> nginx -> 127.0.0.1:13389 (container) -> Windows 3389
  services.nginx.streamConfig = ''
    # RDP TCP proxy to Windows container
    upstream windows_rdp {
      server 127.0.0.1:13389;
    }

    server {
      listen 3389;
      listen [::]:3389;
      proxy_pass windows_rdp;
      proxy_connect_timeout 10s;
      proxy_timeout 1h;  # Long timeout for RDP sessions
    }
  '';
}
