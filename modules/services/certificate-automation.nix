{ config, lib, pkgs, ... }:

let
  postgresqlRenewalScript = pkgs.writeShellApplication {
    name = "postgresql-cert-renewal";
    runtimeInputs = with pkgs; [ bash coreutils systemd ];
    text = ''
      exec /etc/nixos/postgresql-cert-renew.sh
    '';
  };

  nginxRenewalScript = pkgs.writeShellApplication {
    name = "nginx-cert-renewal";
    runtimeInputs = with pkgs; [ bash coreutils systemd ];
    text = ''
      exec /etc/nixos/renew-nginx-certs.sh
    '';
  };

  postfixRenewalScript = pkgs.writeShellApplication {
    name = "postfix-cert-renewal";
    runtimeInputs = with pkgs; [ bash coreutils systemd ];
    text = ''
      exec /etc/nixos/postfix-cert-renew.sh
    '';
  };

  certificateValidationScript = pkgs.writeShellApplication {
    name = "certificate-validation-concise";
    runtimeInputs = with pkgs; [ bash openssl coreutils gawk gnugrep ];
    text = ''
      exec /etc/nixos/validate-certificates-concise.sh
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
      path = with pkgs; [ openssl step-cli systemd ];
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
      path = with pkgs; [ openssl step-cli systemd ];
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
      path = with pkgs; [ openssl step-cli systemd ];
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
      };
      path = with pkgs; [ openssl dnsutils nmap ];
    };
  };

  systemd.timers = {
    postgresql-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 03:00:00";  # First day of month at 3 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    nginx-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 03:30:00";  # First day of month at 3:30 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    postfix-cert-renewal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 04:00:00";  # First day of month at 4 AM
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    certificate-validation = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 06:00:00";  # Daily at 6 AM
        Persistent = true;
      };
    };
  };

  # Ensure scripts are executable and available
  system.activationScripts.certificateScripts = lib.stringAfter [ "users" ] ''
    # Ensure certificate scripts are executable
    for script in postgresql-cert-renew.sh renew-nginx-certs.sh postfix-cert-renew.sh validate-certificates-concise.sh; do
      if [ -f "/etc/nixos/$script" ]; then
        chmod +x "/etc/nixos/$script"
      fi
    done

    # Ensure the general renewal script is also executable
    if [ -f "/etc/nixos/renew-certificate.sh" ]; then
      chmod +x "/etc/nixos/renew-certificate.sh"
    fi
  '';
}
