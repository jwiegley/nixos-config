{
  config,
  lib,
  pkgs,
  hostPolicy,
  ...
}:

{
  # ============================================================================
  # ATD Nginx Virtual Host Configuration
  # ============================================================================

  # Nginx upstream for ATD web interface
  services.nginx.upstreams.atd = {
    servers = {
      "127.0.0.1:9281" = {
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
  services.nginx.virtualHosts."atd.${hostPolicy.dnsName}" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/atd.${hostPolicy.dnsName}.crt";
    sslCertificateKey = "/var/lib/nginx-certs/atd.${hostPolicy.dnsName}.key";

    locations."/" = {
      proxyPass = "http://atd/";
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

    # Health check endpoint
    locations."/health" = {
      proxyPass = "http://atd/health";
      extraConfig = ''
        # Allow health checks from monitoring systems
        allow 127.0.0.1;
        allow 192.168.0.0/16;
        deny all;
      '';
    };
  };

  # Certificate generation script service
  systemd.services.atd-certificate = {
    description = "Generate ATD TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [
      pkgs.openssl
      pkgs.step-cli
    ];

    # RemainAfterExit=false is LOAD-BEARING, do not "restore" it to true.
    #
    # This unit renews correctly (openssl -checkend 2592000 below, reissue
    # under 30 days) but until 2026-09-10 it had no timer and
    # RemainAfterExit=true, so it ran only at boot or on a definition change.
    # This host is rebooted deliberately -- uptime was 68 days -- and the
    # renewal has to land INSIDE the final 30 days, so there was often no
    # trigger at all. Proof: the cert still carried its original 2025
    # notBefore, and the unit's last run (2026-07-03) correctly skipped
    # because ~119 days remained.
    #
    # With RemainAfterExit=true the unit stays `active` forever after its
    # first run, and `systemctl start` on an active oneshot is a NO-OP --
    # verified 2026-09-10, ExecMainExitTimestamp did not move. So a timer
    # alone would have been worse than nothing: armed timer, "active" unit,
    # and the script never running again.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/atd.${hostPolicy.dnsName}.crt"
      KEY_FILE="$CERT_DIR/atd.${hostPolicy.dnsName}.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create a self-signed certificate as a fallback
      echo "Creating temporary self-signed certificate for atd.${hostPolicy.dnsName}"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=atd.${hostPolicy.dnsName}" \
        -addext "subjectAltName=DNS:atd.${hostPolicy.dnsName}"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown nginx:nginx "$CERT_FILE" "$KEY_FILE"

      echo "Certificate generated successfully"
    '';
  };

  # Daily renewal check for the ATD certificate.
  #
  # The service is a no-op while the cert has more than 30 days left (its own
  # `openssl -checkend 2592000` guard), so firing weekly costs one openssl call
  # and issues nothing until renewal is genuinely due. That guard is what makes a
  # frequent timer safe, and a frequent timer is what makes the guard reachable.
  #
  # NOT added to certs/renew-nginx-certs.sh instead: that script reissues
  # unconditionally every month, so listing this domain there as well would
  # double-issue. Its header documents the exclusion deliberately.
  systemd.timers.atd-certificate = {
    description = "Daily renewal check for the ATD TLS certificate";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # DAILY, not weekly. The service is a no-op above 30 days, so the cost is
      # one openssl call. Weekly was measured against the real timeline and lost:
      # budget.vulcan.lan crosses 30 days on 2026-09-30, but Monday firings land on
      # 09-28 (32 days left, skips) and then 10-05, leaving ~5 days where
      # CertificateExpiringSoon fires before the timer heals it. Daily closes that
      # to under a day, which keeps the alert meaningful -- if it fires and persists,
      # something really is wrong rather than just waiting for Monday.
      OnCalendar = "daily";
      # Catch up after downtime: the whole point is that this host may go a long
      # time without a reboot, so a missed window must not be skipped silently.
      Persistent = true;
      RandomizedDelaySec = "1h";
      Unit = "atd-certificate.service";
    };
  };
}
