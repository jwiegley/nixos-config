{ config, lib, pkgs, ... }:

{
  services.step-ca = {
    enable = true;
    address = "127.0.0.1";
    port = 8443;
    intermediatePasswordFile = config.sops.secrets."step-ca-password".path;

    settings = {
      root = "/var/lib/step-ca-state/certs/root_ca.crt";
      federatedRoots = null;
      crt = "/var/lib/step-ca-state/certs/intermediate_ca.crt";
      key = "/var/lib/step-ca-state/secrets/intermediate_ca_key";
      address = ":8443";
      insecureAddress = "";
      dnsNames = [
        "vulcan"
        "vulcan.lan"
        "ca.vulcan.lan"
        "localhost"
      ];
      logger = {
        format = "text";
      };
      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca-state/db";
        badgerFileLoadingMode = "";
      };
      authority = {
        enableAdmin = true;
        # Provisioners will be created by the init script
        provisioners = [];
        template = {};
        claims = {
          minTLSCertDuration = "5m";
          maxTLSCertDuration = "8760h";
          defaultTLSCertDuration = "2160h";
          minHostSSHCertDuration = "5m";
          maxHostSSHCertDuration = "1680h";
          defaultHostSSHCertDuration = "720h";
          minUserSSHCertDuration = "5m";
          maxUserSSHCertDuration = "24h";
          defaultUserSSHCertDuration = "16h";
        };
      };
      tls = {
        cipherSuites = [
          "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
          "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        ];
        minVersion = 1.2;
        maxVersion = 1.3;
        renegotiation = false;
      };
    };
  };

  sops.secrets."step-ca-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "step-ca";
    group = "step-ca";
    mode = "0400";
  };

  environment.systemPackages = with pkgs; [
    step-cli
    step-ca
    (pkgs.writeScriptBin "step-ca-reset" ''
      #!${pkgs.bash}/bin/bash
      set -e
      echo "This will completely reset the step-ca installation!"
      echo "All certificates will be lost and need to be regenerated."
      read -p "Are you sure? (yes/no): " -r
      if [[ $REPLY == "yes" ]]; then
        echo "Stopping step-ca service..."
        sudo systemctl stop step-ca
        echo "Removing CA state..."
        sudo rm -rf /var/lib/step-ca-state/*
        echo "Restarting step-ca-init service..."
        sudo systemctl restart step-ca-init
        echo "Starting step-ca service..."
        sudo systemctl start step-ca
        echo "Reset complete!"
      else
        echo "Cancelled"
      fi
    '')
    (pkgs.writeScriptBin "step-ca-status" ''
      #!${pkgs.bash}/bin/bash
      echo "=== Step CA Status ==="
      echo
      echo "Service Status:"
      systemctl status step-ca --no-pager | head -15
      echo
      echo "CA Files:"
      if [ -d /var/lib/step-ca-state ]; then
        ls -la /var/lib/step-ca-state/certs/ 2>/dev/null || echo "No certificates found"
      else
        echo "CA directory not found"
      fi
      echo
      echo "Health Check:"
      step ca health --ca-url https://localhost:8443 --root /var/lib/step-ca-state/certs/root_ca.crt 2>&1 || echo "Health check failed"
    '')
  ];

  networking.firewall.allowedTCPPorts = lib.mkIf config.services.step-ca.enable [ 8443 ];

  # Override step-ca service to use correct directories
  systemd.services.step-ca = {
    serviceConfig = {
      StateDirectory = lib.mkForce "step-ca-state";
      ReadWritePaths = [ "/var/lib/step-ca-state" ];
    };
  };

  systemd.services.step-ca-init = {
    description = "Initialize step-ca if needed";
    wantedBy = [ "step-ca.service" ];
    before = [ "step-ca.service" ];
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "step-ca";
      Group = "step-ca";
      StateDirectory = "step-ca-state";
      WorkingDirectory = "/var/lib/step-ca-state";
    };
    path = [ pkgs.step-cli pkgs.step-ca pkgs.coreutils pkgs.openssl ];
    script = ''
      set -euo pipefail

      CA_DIR="/var/lib/step-ca-state"

      # Ensure proper directory structure exists
      mkdir -p "$CA_DIR"/{certs,secrets,config,db,templates}

      # Check multiple conditions to determine if CA is initialized
      CA_INITIALIZED=false

      if [ -f "$CA_DIR/certs/root_ca.crt" ] && \
         [ -f "$CA_DIR/certs/intermediate_ca.crt" ] && \
         [ -f "$CA_DIR/secrets/intermediate_ca_key" ] && \
         [ -f "$CA_DIR/config/ca.json" ]; then
        CA_INITIALIZED=true
      fi

      if [ "$CA_INITIALIZED" = "false" ]; then
        echo "Initializing Step CA..."

        # Check for password file
        if [ -f "${config.sops.secrets."step-ca-password".path}" ]; then
          PASSFILE="${config.sops.secrets."step-ca-password".path}"
          echo "Using SOPS password file"
        else
          echo "ERROR: SOPS password file not found at ${config.sops.secrets."step-ca-password".path}"
          echo "Cannot initialize CA without password"
          exit 1
        fi

        # Clean any partial initialization
        rm -f "$CA_DIR/contexts.json" 2>/dev/null || true

        # Initialize the CA
        export STEPPATH="$CA_DIR"
        export HOME="$CA_DIR"  # Ensure step doesn't write to wrong home

        step ca init \
          --name='Vulcan Certificate Authority' \
          --dns='vulcan,vulcan.lan,ca.vulcan.lan,localhost' \
          --address=':8443' \
          --provisioner='johnw@newartisans.com' \
          --password-file="$PASSFILE" \
          --provisioner-password-file="$PASSFILE" \
          --deployment-type=standalone \
          --no-db \
          2>&1 | tee /tmp/step-ca-init.log || {
            echo "Step CA init failed. Check /tmp/step-ca-init.log"
            exit 1
          }

        # Verify initialization was successful
        if [ -f "$CA_DIR/certs/root_ca.crt" ]; then
          echo "Step CA initialization successful"
          # Clean up contexts file that might interfere
          rm -f "$CA_DIR/contexts.json" 2>/dev/null || true
        else
          echo "ERROR: CA initialization failed - root certificate not created"
          exit 1
        fi
      else
        echo "Step CA already initialized - skipping"
        # Ensure no stale contexts.json file
        rm -f "$CA_DIR/contexts.json" 2>/dev/null || true
      fi

      # Final verification
      echo "Verifying CA state..."
      for file in certs/root_ca.crt certs/intermediate_ca.crt secrets/intermediate_ca_key config/ca.json; do
        if [ ! -f "$CA_DIR/$file" ]; then
          echo "ERROR: Missing required file: $file"
          exit 1
        fi
      done

      echo "Step CA is ready"
    '';
  };
}
