{ config, lib, pkgs, ... }:

let
  # Fetchmail configuration template for Good folder (IDLE mode)
  # Delivers to INBOX via Sieve filtering
  fetchmailGoodTemplate = pkgs.writeText "fetchmailrc-good-template" ''
    # Global settings
    set no bouncemail
    set no spambounce
    set properties ""
    # Since we use --nodetach for IDLE mode, we cannot use logfile
    # set logfile /var/log/fetchmail-good/fetchmail.log

    # Fastmail IMAP account - Good folder only (IDLE mode)
    poll imap.fastmail.com protocol IMAP port 993
      user "johnw@newartisans.com"
      password "PASSWORD_PLACEHOLDER"
      folder "Good"

      # Deliver to local user via Postfix SMTP
      # Postfix will scan with rspamd (spam filtering), then deliver via LMTP to Dovecot
      # Dovecot's Sieve will check X-Spam headers and file messages appropriately
      smtphost localhost
      smtpname johnw
      is "johnw" here

      # Use IMAP IDLE for real-time notification
      idle

      # Do not keep messages on server
      fetchall

      # Don't rewrite delivery addresses
      no rewrite
  '';

  # Fetchmail configuration template for Spam folder (regular polling)
  # Delivers directly to local Spam folder
  fetchmailSpamTemplate = pkgs.writeText "fetchmailrc-spam-template" ''
    # Global settings
    set daemon 900
    set no bouncemail
    set no spambounce
    set properties ""
    set logfile /var/log/fetchmail-spam/fetchmail.log

    # Fastmail IMAP account - Spam folder only (polling every 15 minutes)
    poll imap.fastmail.com protocol IMAP port 993
      user "johnw@newartisans.com"
      password "PASSWORD_PLACEHOLDER"
      folder "Spam"

      # Deliver directly to Dovecot LMTP, bypassing Postfix/rspamd
      # These are already confirmed spam from Fastmail, no need to re-scan
      smtphost /var/run/dovecot2/lmtp
      lmtp
      is "johnw" here

      # Do not keep messages on server
      fetchall

      # Don't rewrite delivery addresses
      no rewrite
  '';

  # Script to generate Good folder config with password from SOPS credential
  generateGoodConfig = pkgs.writeShellScript "generate-fetchmail-good-config" ''
    PATH=${pkgs.gnused}/bin:${pkgs.coreutils}/bin:$PATH
    PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/fastmail-password")
    sed "s/PASSWORD_PLACEHOLDER/$PASSWORD/" ${fetchmailGoodTemplate} > /run/fetchmail-good/fetchmailrc
    chmod 600 /run/fetchmail-good/fetchmailrc
  '';

  # Script to generate Spam folder config with password from SOPS credential
  generateSpamConfig = pkgs.writeShellScript "generate-fetchmail-spam-config" ''
    PATH=${pkgs.gnused}/bin:${pkgs.coreutils}/bin:$PATH
    PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/fastmail-password")
    sed "s/PASSWORD_PLACEHOLDER/$PASSWORD/" ${fetchmailSpamTemplate} > /run/fetchmail-spam/fetchmailrc
    chmod 600 /run/fetchmail-spam/fetchmailrc
  '';
in
{
  # SOPS secret for Fastmail password (already exists, just declare usage)
  sops.secrets."johnw-fastmail-password" = {
    restartUnits = [ "fetchmail-good.service" "fetchmail-spam.service" ];
  };

  # Fetchmail user and group
  users.users.fetchmail = {
    isSystemUser = true;
    group = "fetchmail";
    description = "Fetchmail daemon user";
    home = "/var/lib/fetchmail";
    createHome = true;
  };
  users.groups.fetchmail = {};

  # Log directories and files
  systemd.tmpfiles.rules = [
    "d /var/log/fetchmail-good 0755 fetchmail fetchmail -"
    "f /var/log/fetchmail-good/fetchmail.log 0644 fetchmail fetchmail -"
    "d /var/log/fetchmail-spam 0755 fetchmail fetchmail -"
    "f /var/log/fetchmail-spam/fetchmail.log 0644 fetchmail fetchmail -"
  ];

  # Fetchmail systemd service for Good folder (IDLE mode)
  systemd.services.fetchmail-good = {
    description = "Fetchmail daemon for Good folder (IDLE mode)";
    after = [ "network-online.target" "dovecot.service" ];
    wants = [ "network-online.target" ];
    requires = [ "dovecot.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";  # IDLE mode runs in foreground
      User = "fetchmail";
      Group = "fetchmail";

      # Create runtime directory with proper ownership
      RuntimeDirectory = "fetchmail-good";
      RuntimeDirectoryMode = "0700";

      # Load SOPS secret as systemd credential
      LoadCredential = "fastmail-password:${config.sops.secrets."johnw-fastmail-password".path}";

      # Generate config with password from SOPS credential
      ExecStartPre = "${generateGoodConfig}";
      # Use --ssl and --nodetach for IDLE mode (runs in foreground)
      # Use --pidfile to avoid conflicts between multiple instances
      ExecStart = "${pkgs.fetchmail}/bin/fetchmail --ssl --nodetach --pidfile /run/fetchmail-good/fetchmail.pid -f /run/fetchmail-good/fetchmailrc";

      # Always restart - fetchmail exits after processing messages even in IDLE mode
      # It will re-enter IDLE mode on restart
      Restart = "always";
      RestartSec = "5s";

      # Hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/log/fetchmail-good" "/run/dovecot2" ];

      # Allow access to Dovecot LMTP socket
      SupplementaryGroups = [ "dovecot2" ];
    };
  };

  # Fetchmail systemd service for Spam folder (daemon mode with polling)
  systemd.services.fetchmail-spam = {
    description = "Fetchmail daemon for Spam folder (polling every 15 minutes)";
    after = [ "network-online.target" "dovecot.service" ];
    wants = [ "network-online.target" ];
    requires = [ "dovecot.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";  # Simple mode - fetchmail daemon doesn't fork cleanly for systemd
      User = "fetchmail";
      Group = "fetchmail";

      # Create runtime directory with proper ownership
      RuntimeDirectory = "fetchmail-spam";
      RuntimeDirectoryMode = "0700";

      # Load SOPS secret as systemd credential
      LoadCredential = "fastmail-password:${config.sops.secrets."johnw-fastmail-password".path}";

      # Generate config with password from SOPS credential
      ExecStartPre = "${generateSpamConfig}";
      # Use --ssl for daemon mode (polls every 15 minutes)
      # Use --pidfile to avoid conflicts between multiple instances
      ExecStart = "${pkgs.fetchmail}/bin/fetchmail --ssl --pidfile /run/fetchmail-spam/fetchmail.pid -f /run/fetchmail-spam/fetchmailrc";

      Restart = "on-failure";
      RestartSec = "30s";

      # Hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/log/fetchmail-spam" "/run/dovecot2" ];

      # Allow access to Dovecot LMTP socket
      SupplementaryGroups = [ "dovecot2" ];
    };
  };

  # Install fetchmail package
  environment.systemPackages = [ pkgs.fetchmail ];
}
