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
    };
    path = [ pkgs.step-cli pkgs.step-ca pkgs.coreutils ];
    script = ''
      CA_DIR="/var/lib/step-ca-state"

      # Check if CA is already initialized
      if [ ! -f "$CA_DIR/certs/root_ca.crt" ]; then
        echo "Initializing Step CA for the first time..."

        # Use the actual password from SOPS if available, else generate temporary
        if [ -f "${config.sops.secrets."step-ca-password".path}" ]; then
          TEMP_PASSFILE="${config.sops.secrets."step-ca-password".path}"
        else
          # Generate a temporary password for initialization
          TEMP_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -base64 32)
          TEMP_PASSFILE=$(mktemp)
          chmod 644 $TEMP_PASSFILE
          echo "$TEMP_PASSWORD" > $TEMP_PASSFILE
        fi

        # Initialize the CA - we're already running as step-ca user
        export STEPPATH=$CA_DIR
        step ca init \
          --name='Vulcan Certificate Authority' \
          --dns='vulcan,vulcan.lan,ca.vulcan.lan,localhost' \
          --address=':8443' \
          --provisioner='johnw@newartisans.com' \
          --password-file=$TEMP_PASSFILE \
          --provisioner-password-file=$TEMP_PASSFILE \
          --deployment-type=standalone

        # Clean up temporary password only if we created it
        if [ ! -f "${config.sops.secrets."step-ca-password".path}" ] || [ "$TEMP_PASSFILE" != "${config.sops.secrets."step-ca-password".path}" ]; then
          rm -f $TEMP_PASSFILE
        fi

        echo "Step CA initialization complete"
      else
        echo "Step CA already initialized"
      fi
    '';
  };
}
