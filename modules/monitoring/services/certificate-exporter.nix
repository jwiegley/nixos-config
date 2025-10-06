{ config, lib, pkgs, ... }:

let
  # Directory for textfile collector metrics
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  # Certificate directories to check
  nginxCertDir = "/var/lib/nginx-certs";
  stepCaDir = "/var/lib/step-ca-state/certs";
  postgresqlCertDir = "/var/lib/postgresql/certs";
  dovecotCertDir = "/var/lib/dovecot-certs";
  postfixCertDir = "/var/lib/postfix-certs";

  # Warning and critical thresholds (in seconds)
  warningSeconds = 30 * 24 * 3600;  # 30 days
  criticalSeconds = 7 * 24 * 3600;   # 7 days

  # Certificate validation and metrics generation script
  certificateExporter = pkgs.writeShellScript "certificate-exporter" ''
    set -euo pipefail

    OUTPUT_FILE="${textfileDir}/certificates.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"

    # Write metrics header
    cat > "$TEMP_FILE" <<'HEADER'
# HELP certificate_expiry_seconds Time until certificate expiration in seconds
# TYPE certificate_expiry_seconds gauge
# HELP certificate_valid Whether the certificate is currently valid (1 = valid, 0 = invalid/expired)
# TYPE certificate_valid gauge
# HELP certificate_days_until_expiry Days until certificate expiration
# TYPE certificate_days_until_expiry gauge
# HELP certificate_file_exists Whether the certificate file exists (1 = exists, 0 = missing)
# TYPE certificate_file_exists gauge
# HELP certificate_key_matches Whether the certificate key matches (1 = matches, 0 = mismatch or missing)
# TYPE certificate_key_matches gauge
# HELP certificate_chain_valid Whether the certificate chain is valid (1 = valid, 0 = invalid, -1 = not checked)
# TYPE certificate_chain_valid gauge
HEADER

    # Function to check a single certificate and output metrics
    check_certificate() {
      local cert_path="$1"
      local cert_name="$2"
      local cert_type="$3"  # e.g., "nginx", "ca", "postgresql"

      # Check if file exists
      if [[ ! -f "$cert_path" ]]; then
        cat >> "$TEMP_FILE" <<EOF
certificate_file_exists{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_valid{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_expiry_seconds{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_days_until_expiry{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_key_matches{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_chain_valid{name="$cert_name",type="$cert_type",path="$cert_path"} -1
EOF
        return
      fi

      # File exists
      echo "certificate_file_exists{name=\"$cert_name\",type=\"$cert_type\",path=\"$cert_path\"} 1" >> "$TEMP_FILE"

      # Get certificate end date
      local end_date
      if ! end_date=$(${pkgs.openssl}/bin/openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2); then
        # Invalid certificate
        cat >> "$TEMP_FILE" <<EOF
certificate_valid{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_expiry_seconds{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_days_until_expiry{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_key_matches{name="$cert_name",type="$cert_type",path="$cert_path"} 0
certificate_chain_valid{name="$cert_name",type="$cert_type",path="$cert_path"} -1
EOF
        return
      fi

      # Calculate expiration time
      local end_epoch=$(${pkgs.coreutils}/bin/date -d "$end_date" +%s 2>/dev/null)
      local now_epoch=$(${pkgs.coreutils}/bin/date +%s)
      local seconds_remaining=$((end_epoch - now_epoch))
      local days_remaining=$((seconds_remaining / 86400))

      # Check if certificate is currently valid
      local is_valid=0
      if ${pkgs.openssl}/bin/openssl x509 -in "$cert_path" -noout -checkend 0 >/dev/null 2>&1; then
        is_valid=1
      fi

      # Write expiration metrics
      cat >> "$TEMP_FILE" <<EOF
certificate_valid{name="$cert_name",type="$cert_type",path="$cert_path"} $is_valid
certificate_expiry_seconds{name="$cert_name",type="$cert_type",path="$cert_path"} $seconds_remaining
certificate_days_until_expiry{name="$cert_name",type="$cert_type",path="$cert_path"} $days_remaining
EOF

      # Check if key exists and matches
      local key_path="''${cert_path%.crt}.key"
      local key_matches=0
      if [[ -f "$key_path" ]]; then
        local cert_modulus=$(${pkgs.openssl}/bin/openssl x509 -in "$cert_path" -noout -modulus 2>/dev/null | ${pkgs.coreutils}/bin/md5sum | cut -d' ' -f1)
        local key_modulus=$(${pkgs.openssl}/bin/openssl rsa -in "$key_path" -noout -modulus 2>/dev/null | ${pkgs.coreutils}/bin/md5sum | cut -d' ' -f1)
        if [[ "$cert_modulus" == "$key_modulus" ]]; then
          key_matches=1
        fi
      fi
      echo "certificate_key_matches{name=\"$cert_name\",type=\"$cert_type\",path=\"$cert_path\"} $key_matches" >> "$TEMP_FILE"

      # Check certificate chain for service certificates (not CA)
      local chain_valid=-1  # -1 = not checked
      if [[ "$cert_type" != "ca" && -f "${stepCaDir}/root_ca.crt" && -f "${stepCaDir}/intermediate_ca.crt" ]]; then
        if ${pkgs.openssl}/bin/openssl verify -CAfile "${stepCaDir}/root_ca.crt" -untrusted "${stepCaDir}/intermediate_ca.crt" "$cert_path" >/dev/null 2>&1; then
          chain_valid=1
        else
          chain_valid=0
        fi
      fi
      echo "certificate_chain_valid{name=\"$cert_name\",type=\"$cert_type\",path=\"$cert_path\"} $chain_valid" >> "$TEMP_FILE"
    }

    # Check Certificate Authority certificates
    if [[ -d "${stepCaDir}" ]]; then
      check_certificate "${stepCaDir}/root_ca.crt" "root-ca" "ca"
      check_certificate "${stepCaDir}/intermediate_ca.crt" "intermediate-ca" "ca"
    fi

    # Check Nginx service certificates
    if [[ -d "${nginxCertDir}" ]]; then
      for cert_file in "${nginxCertDir}"/*.crt; do
        if [[ -f "$cert_file" ]]; then
          cert_name=$(basename "$cert_file" .crt)
          # Skip chain files
          if [[ "$cert_name" == *"chain"* || "$cert_name" == *"fullchain"* ]]; then
            continue
          fi
          check_certificate "$cert_file" "$cert_name" "nginx"
        fi
      done
    fi

    # Check PostgreSQL certificates
    if [[ -d "${postgresqlCertDir}" ]]; then
      check_certificate "${postgresqlCertDir}/server.crt" "postgresql-server" "postgresql"
      # Check client certificates
      for cert_file in "${postgresqlCertDir}"/*.crt; do
        if [[ -f "$cert_file" ]]; then
          cert_name=$(basename "$cert_file" .crt)
          if [[ "$cert_name" != "server" && "$cert_name" != *"chain"* && "$cert_name" != *"ca"* ]]; then
            check_certificate "$cert_file" "postgresql-$cert_name" "postgresql"
          fi
        fi
      done
    fi

    # Check Dovecot certificates
    if [[ -d "${dovecotCertDir}" ]]; then
      for cert_file in "${dovecotCertDir}"/*.crt; do
        if [[ -f "$cert_file" ]]; then
          cert_name=$(basename "$cert_file" .crt)
          if [[ "$cert_name" != *"chain"* && "$cert_name" != *"fullchain"* ]]; then
            check_certificate "$cert_file" "$cert_name" "dovecot"
          fi
        fi
      done
    fi

    # Check Postfix certificates
    if [[ -d "${postfixCertDir}" ]]; then
      for cert_file in "${postfixCertDir}"/*.crt; do
        if [[ -f "$cert_file" ]]; then
          cert_name=$(basename "$cert_file" .crt)
          if [[ "$cert_name" != *"chain"* && "$cert_name" != *"fullchain"* ]]; then
            check_certificate "$cert_file" "$cert_name" "postfix"
          fi
        fi
      done
    fi

    # Add collection timestamp
    echo "# HELP certificate_exporter_last_run_timestamp_seconds Timestamp of last certificate check" >> "$TEMP_FILE"
    echo "# TYPE certificate_exporter_last_run_timestamp_seconds gauge" >> "$TEMP_FILE"
    echo "certificate_exporter_last_run_timestamp_seconds $(date +%s)" >> "$TEMP_FILE"

    # Atomically replace the metrics file
    ${pkgs.coreutils}/bin/mv "$TEMP_FILE" "$OUTPUT_FILE"
    ${pkgs.coreutils}/bin/chmod 644 "$OUTPUT_FILE"
  '';
in
{
  # Systemd service for certificate exporter
  systemd.services.certificate-exporter = {
    description = "Generate certificate metrics for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = certificateExporter;
      User = "root";  # Needs root to read various certificate directories
    };
  };

  # Timer for hourly certificate checks
  systemd.timers.certificate-exporter = {
    description = "Timer for certificate metrics exporter";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";  # Run every hour
      Persistent = true;
    };
  };
}
