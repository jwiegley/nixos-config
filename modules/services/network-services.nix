{ config, lib, pkgs, ... }:

{
  services = {
    eternal-terminal.enable = true;

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "yes";
      };
    };

    postfix = {
      enable = true;

      # Enable submission services for encrypted mail submission
      enableSubmission = true;   # Port 587 with STARTTLS
      enableSubmissions = true;  # Port 465 with implicit TLS (recommended)

      # TLS configuration for submission services
      submissionOptions = {
        smtpd_tls_security_level = "encrypt";
        smtpd_sasl_auth_enable = "yes";
        smtpd_client_restrictions = "permit_mynetworks,permit_sasl_authenticated,reject";
        smtpd_recipient_restrictions = "permit_mynetworks,permit_sasl_authenticated,reject";
        smtpd_relay_restrictions = "permit_mynetworks,permit_sasl_authenticated,reject";
        milter_macro_daemon_name = "ORIGINATING";
      };

      submissionsOptions = {
        smtpd_tls_wrappermode = "yes";
        smtpd_tls_security_level = "encrypt";
        smtpd_sasl_auth_enable = "yes";
        smtpd_client_restrictions = "permit_mynetworks,permit_sasl_authenticated,reject";
        smtpd_recipient_restrictions = "permit_mynetworks,permit_sasl_authenticated,reject";
        smtpd_relay_restrictions = "permit_mynetworks,permit_sasl_authenticated,reject";
        milter_macro_daemon_name = "ORIGINATING";
      };

      settings.main = {
        mynetworks = [
          "192.168.1.0/24"
          "10.6.0.0/24"
          "127.0.0.0/8"
        ];
        relayhost = [ "[smtp.fastmail.com]:587" ];
        smtp_use_tls = "yes";
        smtp_sasl_auth_enable = "yes";
        smtp_sasl_security_options = "";
        smtp_sasl_password_maps = "texthash:/secrets/postfix_sasl";

        # TLS certificate configuration
        smtpd_tls_cert_file = "/var/lib/postfix-certs/smtp.vulcan.lan.crt";
        smtpd_tls_key_file = "/var/lib/postfix-certs/smtp.vulcan.lan.key";
        smtpd_tls_chain_files = [
          "/var/lib/postfix-certs/smtp.vulcan.lan.key"
          "/var/lib/postfix-certs/smtp.vulcan.lan.fullchain.crt"
        ];

        # TLS parameters
        smtpd_tls_security_level = "may";  # Allow TLS on port 25 but don't require it
        smtpd_tls_auth_only = "yes";       # Require TLS for authentication
        smtpd_tls_loglevel = "1";
        smtpd_tls_received_header = "yes";
        smtpd_tls_session_cache_database = "btree:\${data_directory}/smtpd_scache";
        smtpd_tls_protocols = "!SSLv2,!SSLv3,!TLSv1,!TLSv1.1";
        smtpd_tls_ciphers = "medium";
        smtpd_tls_exclude_ciphers = "aNULL,DES,3DES,MD5,RC4";

        # Additional security
        tls_preempt_cipherlist = "yes";
      };
    };

    fail2ban = {
      enable = false;
      jails.sshd.settings = {
        enabled = true;
        maxretry = 10;        # Allow up to 10 failed attempts
        findtime = 3600;      # Count failures within an hour (3600 seconds)
        bantime = "24h";      # Ban for one day
        backend = "systemd";  # Use systemd journal (works best on NixOS)
      };
    };
  };
}
