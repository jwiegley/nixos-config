{ config, lib, pkgs, ... }:

let
  # Shell script to call rspamc learn_spam
  learnSpamShellScript = pkgs.writeShellScript "rspamd-learn-spam.sh" ''
    exec ${pkgs.rspamd}/bin/rspamc learn_spam
  '';

  # Shell script to call rspamc learn_ham
  learnHamShellScript = pkgs.writeShellScript "rspamd-learn-ham.sh" ''
    exec ${pkgs.rspamd}/bin/rspamc learn_ham
  '';

  # Sieve script for learning spam (when moved to TrainSpam)
  # References script by name from sieve_pipe_bin_dir
  learnSpamScript = pkgs.writeText "learn-spam.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainSpam" {
      pipe :copy "rspamd-learn-spam.sh";
    }
  '';

  # Sieve script for learning ham (when moved to TrainGood)
  # References script by name from sieve_pipe_bin_dir
  learnHamScript = pkgs.writeText "learn-ham.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainGood" {
      pipe :copy "rspamd-learn-ham.sh";
    }
  '';

  # Sieve script to move trained spam to IsSpam folder
  moveToIsSpamScript = pkgs.writeText "move-to-isspam.sieve" ''
    require ["fileinto", "imap4flags"];

    # Move all messages in TrainSpam to IsSpam after learning
    fileinto "IsSpam";

    # Mark the original message in TrainSpam as deleted
    addflag "\\Deleted";
  '';

  # Shell script to rescan message and redeliver via Postfix
  retrainShellScript = pkgs.writeShellScript "rspamd-retrain.sh" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Receive username as argument from Sieve
    USER="$1"

    if [ -z "$USER" ]; then
      echo "ERROR: No username provided" >&2
      exit 1
    fi

    # Reinject via sendmail to trigger full Postfix delivery pipeline:
    # Postfix → rspamd milter (adds/updates X-Spam headers) → dovecot LMTP → Sieve filtering
    # Use setuid wrapper to handle Postfix permissions
    # -G: gateway submission (don't add headers)
    # -i: ignore single dots on lines by themselves
    # -f: envelope sender
    exec /run/wrappers/bin/sendmail -G -i -f "$USER@localhost" "$USER@localhost"
  '';

  # Sieve script for retraining (when moved to Retrain folder)
  retrainScript = pkgs.writeText "retrain.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

    # Capture the username from IMAP session
    if environment :matches "imap.user" "*" {
      set "username" "''${1}";
    }

    # Only process if in Retrain mailbox
    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "Retrain" {
      # Pipe message through rspamd for rescanning, then redeliver via LDA
      # Pass username as argument so dovecot-lda knows where to deliver
      pipe :copy "rspamd-retrain.sh" ["''${username}"];
    }
  '';

  # Sieve script to clean up retrained messages
  retrainCleanupScript = pkgs.writeText "retrain-cleanup.sieve" ''
    require ["imap4flags"];

    # Mark the original message in Retrain as deleted
    # User's mail client will expunge it on next sync
    addflag "\\Deleted";
  '';

  # Note: moveToGoodScript removed - TrainGood now uses process-good.sieve directly
  # to re-filter messages via active.sieve instead of moving to Good folder first
in
{
  # SOPS secret for Rspamd controller password
  sops.secrets."rspamd-controller-password" = {
    owner = "rspamd";
    mode = "0400";
    restartUnits = [ "rspamd.service" ];
  };

  # SOPS secret for Rspamd PostgreSQL password
  sops.secrets."rspamd-db-password" = {
    owner = "rspamd";
    mode = "0400";
    restartUnits = [ "rspamd.service" ];
  };

  # Enable Rspamd service using NixOS module
  services.rspamd = {
    enable = true;

    # Configure workers to include override directory for password
    workers.controller = {
      includes = [ "/var/lib/rspamd/override.d/worker-controller.inc" ];
      # Explicitly configure secure IPs and bind socket
      extraConfig = ''
        # Secure web interface access from localhost
        secure_ip = "127.0.0.1";
        secure_ip = "::1";

        # IMPORTANT: Use single controller worker for RRD support
        # Multiple controller workers break RRD graphs
        count = 1;
      '';
    };

    # Configure proxy worker for milter protocol integration with Postfix
    workers.rspamd_proxy = {
      type = "rspamd_proxy";
      bindSockets = [ "localhost:11332" ];
      count = 4;
      extraConfig = ''
        milter = yes;
        timeout = 30s;
        upstream "local" {
          default = yes;
          self_scan = yes;
        }
      '';
    };

    # Use local Redis instance for statistics
    locals = {
      "options.inc".text = ''
        # DNS configuration for better performance
        # Rspamd can make 20-64 concurrent DNS queries per message for RBLs/SURBLs/URIBLs
        # Use Unbound recursive resolver to avoid blocklist rate-limiting/blocking
        dns {
          nameserver = ["192.168.1.1"];  # Use local Unbound recursive resolver
          timeout = 2s;                   # Timeout for DNS queries
          sockets = 32;                   # Number of concurrent DNS sockets
          retransmits = 2;                # Number of retries for failed queries
        }
      '';

      "redis.conf".text = ''
        # Redis backend configuration for Bayes classifier
        servers = "127.0.0.1:6381";
      '';

      "rrd.conf".text = ''
        # RRD configuration for historical statistics and graphs
        # Enable RRD for throughput page
        rrd = "/var/lib/rspamd/rspamd.rrd";
      '';

      "statistic.conf".text = ''
        # Statistics configuration
        classifier "bayes" {
          backend = "redis";
          servers = "127.0.0.1:6381";

          # Tokenizer settings
          tokenizer {
            name = "osb";
          }

          # Cache settings
          cache {
            type = "redis";
            servers = "127.0.0.1:6381";
          }

          # Minimum learns before autolearn kicks in
          min_learns = 10;

          # Autolearn settings
          autolearn {
            spam_threshold = 12.0;
            ham_threshold = -5.0;
          }

          # Statfiles required for classifier (Redis-backed)
          statfile {
            symbol = "BAYES_HAM";
            spam = false;
          }
          statfile {
            symbol = "BAYES_SPAM";
            spam = true;
          }
        }
      '';

      "actions.conf".text = ''
        # Action thresholds - never reject, only add headers
        # Let Sieve handle spam filing based on X-Spam headers
        reject = 999;  # Effectively disable rejection
        add_header = 6;
        greylist = 4;
      '';

      "milter_headers.conf".text = ''
        # Add spam headers to messages
        # x-spam adds "X-Spam: Yes/No" header used by Sieve for spam filing
        use = ["x-spam", "x-spamd-bar", "x-spam-level", "x-spam-status", "authentication-results"];

        # Extended headers for better filtering
        extended_spam_headers = true;
      '';

      "metrics.conf".text = ''
        # Prometheus metrics export
        group "web" {
          path = "/metrics";
        }
      '';

      "dkim_signing.conf".text = ''
        # Disable DKIM signing for local/private domains
        # DKIM is only useful for public internet domains
        sign_local = false;

        # Still allow signing for authenticated users with public domains
        # but don't fail if key is missing
        allow_hdrfrom_mismatch_sign_networks = false;
      '';

      # Worker controller configuration for web UI
      "worker-controller.inc".text = ''
        # Enable web UI
        static_dir = "${pkgs.rspamd}/share/rspamd/www";

        # Secure IPs that don't require password
        secure_ip = "127.0.0.1";
        secure_ip = "::1";
      '';
    };
  };

  # Systemd service override to inject password into controller configuration
  systemd.services.rspamd = {
    preStart = ''
      # Create override directory for controller worker
      mkdir -p /var/lib/rspamd/override.d

      # Read password from SOPS secret and write to controller override file
      if [ -f "${config.sops.secrets."rspamd-controller-password".path}" ]; then
        PASSWORD_HASH=$(cat "${config.sops.secrets."rspamd-controller-password".path}")
        {
          echo "# Auto-generated password configuration from SOPS"
          echo "password = \"$PASSWORD_HASH\";"
          echo "enable_password = \"$PASSWORD_HASH\";"
        } > /var/lib/rspamd/override.d/worker-controller.inc

        chown rspamd:rspamd /var/lib/rspamd/override.d/worker-controller.inc
        chmod 600 /var/lib/rspamd/override.d/worker-controller.inc
      fi
    '';

    serviceConfig = {
      # Ensure SOPS secrets are available before starting
      LoadCredential = "rspamd-password:${config.sops.secrets."rspamd-controller-password".path}";
    };
  };

  # Redis instance for Rspamd (separate from other Redis instances)
  services.redis.servers.rspamd = {
    enable = true;
    port = 6381;
    bind = "127.0.0.1";
    requirePass = null;  # No password for local-only access
    save = [
      [900 1]    # Save after 900 sec if at least 1 key changed
      [300 10]   # Save after 300 sec if at least 10 keys changed
      [60 10000] # Save after 60 sec if at least 10000 keys changed
    ];
  };

  # PostgreSQL database for Rspamd history
  services.postgresql.ensureDatabases = [ "rspamd" ];
  services.postgresql.ensureUsers = [
    {
      name = "rspamd";
      ensureDBOwnership = true;
    }
  ];

  # Deploy Sieve scripts and pipe executables for spam/ham learning
  # Sieve scripts reference executables by name from sieve_pipe_bin_dir
  # NOTE: Directory creation moved to dovecot.nix to ensure correct parent/child ordering
  systemd.tmpfiles.rules = [
    # Sieve scripts symlinks (directory created in dovecot.nix)
    "L+ /var/lib/dovecot/sieve/global/rspamd/learn-spam.sieve - - - - ${learnSpamScript}"
    "L+ /var/lib/dovecot/sieve/global/rspamd/learn-ham.sieve - - - - ${learnHamScript}"
    "L+ /var/lib/dovecot/sieve/global/rspamd/move-to-isspam.sieve - - - - ${moveToIsSpamScript}"
    # Retrain folder scripts
    "L+ /var/lib/dovecot/sieve/global/rspamd/retrain.sieve - - - - ${retrainScript}"
    "L+ /var/lib/dovecot/sieve/global/rspamd/retrain-cleanup.sieve - - - - ${retrainCleanupScript}"
    # move-to-good.sieve removed - TrainGood now uses process-good.sieve directly

    # Sieve pipe executables directory
    # Dovecot requires pipe scripts to be in sieve_pipe_bin_dir for security
    "d /var/lib/dovecot/sieve-pipe-bin 0755 dovecot2 dovecot2 -"
    "L+ /var/lib/dovecot/sieve-pipe-bin/rspamd-learn-spam.sh - - - - ${learnSpamShellScript}"
    "L+ /var/lib/dovecot/sieve-pipe-bin/rspamd-learn-ham.sh - - - - ${learnHamShellScript}"
    "L+ /var/lib/dovecot/sieve-pipe-bin/rspamd-retrain.sh - - - - ${retrainShellScript}"
  ];

  # Nginx virtual host for Rspamd web UI
  services.nginx.virtualHosts."rspamd.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/rspamd.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/rspamd.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:11334/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };

    # Metrics endpoint for Prometheus
    locations."/metrics" = {
      proxyPass = "http://127.0.0.1:11334/metrics";
      extraConfig = ''
        # Allow Prometheus to scrape metrics
        allow 127.0.0.1;
        deny all;
      '';
    };
  };

  # Prometheus scrape configuration for Rspamd metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "rspamd";
      static_configs = [{
        targets = [ "localhost:11334" ];
      }];
      metrics_path = "/metrics";
    }
  ];

  # System packages for Rspamd utilities
  environment.systemPackages = with pkgs; [
    rspamd
  ];
}
