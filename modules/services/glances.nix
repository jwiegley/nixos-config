{ config, lib, pkgs, ... }:

{
  # Glances system monitoring service
  # Provides real-time system monitoring with web interface and Prometheus metrics
  # https://github.com/nicolargo/glances

  # Create Glances configuration file
  environment.etc."glances/glances.conf".text = ''
    [global]
    # Refresh rate in seconds
    refresh=2
    # History size (for charts)
    history_size=1200

    [webserver]
    # Bind to localhost only (nginx will proxy)
    bind=127.0.0.1
    port=61208
    # No SSL - nginx handles it
    certfile=
    keyfile=

    [outputs]
    # Enable Prometheus export
    prometheus=True

    [cpu]
    # CPU thresholds
    careful=50
    warning=70
    critical=90

    [mem]
    # Memory thresholds
    careful=50
    warning=70
    critical=90

    [memswap]
    # Swap memory thresholds
    careful=50
    warning=70
    critical=90

    [load]
    # Load average thresholds (per CPU core)
    careful=0.7
    warning=1.0
    critical=5.0

    [network]
    # Hide loopback interface
    hide=lo

    [diskio]
    # Hide loopback and virtual devices
    hide=loop.*,ram.*

    [fs]
    # Filesystem thresholds
    careful=50
    warning=70
    critical=90
    # Hide common virtual filesystems
    hide=/boot.*,/run.*,/sys.*,/dev.*,/proc.*,/tmp.*

    [sensors]
    # Temperature thresholds (Celsius)
    temperature_core_careful=60
    temperature_core_warning=70
    temperature_core_critical=80
  '';

  # Glances systemd service
  systemd.services.glances = {
    description = "Glances system monitoring";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "glances";
      Group = "glances";

      # Run Glances in web server mode
      # Disable docker and ip plugins (ip plugin has netifaces issues in sandboxed environment)
      ExecStart = "${pkgs.glances}/bin/glances -w -C /etc/glances/glances.conf --disable-plugin docker --disable-plugin ip";

      Restart = "always";
      RestartSec = "10s";

      # Security hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/glances" ];

      # Systemd sandboxing
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;

      # Resource limits
      MemoryMax = "512M";
      TasksMax = 50;
    };

    # Ensure state directory exists
    preStart = ''
      mkdir -p /var/lib/glances
      chown glances:glances /var/lib/glances
    '';
  };

  # Create glances user and group
  users.users.glances = {
    isSystemUser = true;
    group = "glances";
    description = "Glances monitoring user";
    home = "/var/lib/glances";
    createHome = true;
  };

  users.groups.glances = {};

  # Create state directory
  systemd.tmpfiles.rules = [
    "d /var/lib/glances 0755 glances glances - -"
  ];

  # Nginx upstream for Glances
  services.nginx.upstreams.glances = {
    servers = {
      "127.0.0.1:61208" = {
        max_fails = 3;
        fail_timeout = "30s";
      };
    };
    extraConfig = ''
      keepalive 8;
      keepalive_timeout 60s;
    '';
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."glances.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/glances.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/glances.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://glances/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Standard timeouts
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
      '';
    };

    # Prometheus metrics endpoint
    locations."/api/prometheus" = {
      proxyPass = "http://glances/api/prometheus";
      extraConfig = ''
        # Allow Prometheus to scrape
        allow 127.0.0.1;
        deny all;
      '';
    };
  };

  # Certificate generation script service
  systemd.services.glances-certificate = {
    description = "Generate Glances TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [ pkgs.openssl pkgs.step-cli ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/glances.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/glances.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create a self-signed certificate as a fallback
      echo "Creating temporary self-signed certificate for glances.vulcan.lan"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=glances.vulcan.lan" \
        -addext "subjectAltName=DNS:glances.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown nginx:nginx "$CERT_FILE" "$KEY_FILE"

      echo "Certificate generated successfully"
    '';
  };

}
