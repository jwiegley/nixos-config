{
  config,
  lib,
  pkgs,
  ...
}:

let
  postgresqlRenewalScript = pkgs.writeShellApplication {
    name = "postgresql-cert-renewal";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      systemd
    ];
    text = ''
      exec /etc/nixos/certs/postgresql-cert-renew.sh
    '';
  };

  nginxRenewalScript = pkgs.writeShellApplication {
    name = "nginx-cert-renewal";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      systemd
    ];
    text = ''
      exec /etc/nixos/certs/renew-nginx-certs.sh
    '';
  };

  postfixRenewalScript = pkgs.writeShellApplication {
    name = "postfix-cert-renewal";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      systemd
    ];
    text = ''
      exec /etc/nixos/certs/postfix-cert-renew.sh
    '';
  };

  dovecotRenewalScript = pkgs.writeShellApplication {
    name = "dovecot-cert-renewal";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      systemd
    ];
    text = ''
      exec /etc/nixos/certs/dovecot-cert-renew.sh
    '';
  };

  certificateValidationScript = pkgs.writeShellApplication {
    name = "certificate-validation-concise";
    runtimeInputs = with pkgs; [
      bash
      openssl
      coreutils
      gawk
      gnugrep
    ];
    text = ''
      exec /etc/nixos/certs/validate-certificates-concise.sh
    '';
  };
in
{
  systemd.services = {
    postgresql-cert-renewal = {
      description = "Renew PostgreSQL SSL certificates";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe postgresqlRenewalScript;
        User = "root";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      path = with pkgs; [
        bash
        openssl
        step-cli
        systemd
        sudo
        sops
        gnugrep
        gawk
      ];
      after = [ "step-ca.service" ];
      wants = [ "step-ca.service" ];
    };

    nginx-cert-renewal = {
      description = "Renew Nginx virtual host certificates";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe nginxRenewalScript;
        User = "root";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      path = with pkgs; [
        bash
        openssl
        step-cli
        systemd
        sudo
        sops
        gnugrep
        gawk
      ];
      after = [ "step-ca.service" ];
      wants = [ "step-ca.service" ];
    };

    postfix-cert-renewal = {
      description = "Renew Postfix mail server certificates";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe postfixRenewalScript;
        User = "root";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      path = with pkgs; [
        bash
        openssl
        step-cli
        systemd
        sudo
        sops
        gnugrep
        gawk
      ];
      after = [ "step-ca.service" ];
      wants = [ "step-ca.service" ];
    };

    dovecot-cert-renewal = {
      description = "Renew Dovecot IMAP server certificates";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe dovecotRenewalScript;
        User = "root";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      path = with pkgs; [
        bash
        openssl
        step-cli
        systemd
        sudo
        sops
        gnugrep
        gawk
      ];
      after = [ "step-ca.service" ];
      wants = [ "step-ca.service" ];
    };

    certificate-validation = {
      description = "Validate all certificates and report status";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe certificateValidationScript;
        User = "root";
        StandardOutput = "journal";
        StandardError = "journal";

        # The validator reports severity through its exit code:
        #   0 = all certificates healthy
        #   1 = one or more inside the 30-day warning window
        #   2 = expired, critical (<7d), or unreadable
        #
        # Treat 1 as success. A warning is the script working correctly, not the
        # unit breaking, and it is already reported by the CertificateExpiringSoon
        # Prometheus alert. Without this the unit failed EVERY DAY from the moment
        # any of ~47 certificates crossed 30 days until it was renewed -- ten
        # consecutive days for nginx/vulcan.lan in August 2026 (clean 08-21/22,
        # then 'exit-code' 08-23 onward). That is duplicate signalling on the one
        # channel that is supposed to mean "this unit is broken", and it lands in
        # the routine failed-units sweep, buying an investigation each time.
        #
        # Exit 2 is deliberately NOT included: a genuinely expired or unreadable
        # certificate must still fail the unit loudly.
        SuccessExitStatus = "1";
      };
      path = with pkgs; [
        openssl
        dnsutils
        nmap
      ];
    };
  };

  systemd.timers = {
    postgresql-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 03:00:00"; # First day of month at 3 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    nginx-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 03:30:00"; # First day of month at 3:30 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    postfix-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 04:00:00"; # First day of month at 4 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    dovecot-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 04:30:00"; # First day of month at 4:30 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    certificate-validation = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 06:00:00"; # Daily at 6 AM
        Persistent = true;
      };
    };
  };

  # Ensure scripts are executable and available
  system.activationScripts.certificateScripts = lib.stringAfter [ "users" ] ''
    # Ensure certificate scripts are executable
    for script in postgresql-cert-renew.sh renew-nginx-certs.sh postfix-cert-renew.sh dovecot-cert-renew.sh validate-certificates-concise.sh; do
      if [ -f "/etc/nixos/certs/$script" ]; then
        chmod +x "/etc/nixos/certs/$script"
      fi
    done

    # Ensure the general renewal script is also executable
    if [ -f "/etc/nixos/certs/renew-certificate.sh" ]; then
      chmod +x "/etc/nixos/certs/renew-certificate.sh"
    fi
  '';
}
