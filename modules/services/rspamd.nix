{ config, lib, pkgs, ... }:

let
  # Helper script to scan mailboxes with rspamc
  mailboxScannerScript = pkgs.writeShellScript "rspamd-scan-mailboxes" ''
    set -euo pipefail

    # Configuration
    USERS=("johnw" "assembly")
    MAIL_ROOT="/var/mail"
    SPAM_THRESHOLD=6  # Rspamd score threshold for spam (matches "add header" action)
    RSPAMC="${pkgs.rspamd}/bin/rspamc"
    MESSAGES_SCANNED=0
    SPAM_MOVED=0

    # Function to scan a single maildir directory
    scan_maildir() {
      local maildir=$1
      local maildir_name=$2

      if [ ! -d "$maildir/new" ] && [ ! -d "$maildir/cur" ]; then
        return
      fi

      echo "Scanning: $maildir_name"
      local dir_count=0

      # Scan messages in new/ and cur/ directories
      for dir in new cur; do
        if [ -d "$maildir/$dir" ]; then
          for msg in "$maildir/$dir"/*; do
            # Skip if not a regular file or if it's a directory
            [ -f "$msg" ] || continue

            # Scan message with rspamc
            result=$($RSPAMC --json < "$msg" 2>/dev/null || true)
            MESSAGES_SCANNED=$((MESSAGES_SCANNED + 1))

            # Extract score from JSON result
            score=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.default.score // 0' 2>/dev/null || echo "0")

            # If score exceeds threshold, move to .Spam folder
            if (( $(echo "$score > $SPAM_THRESHOLD" | ${pkgs.bc}/bin/bc -l) )); then
              # Determine user from maildir path
              user=$(echo "$maildir" | sed 's|^/var/mail/\([^/]*\).*|\1|')
              spam_dir="$MAIL_ROOT/$user/.Spam/cur"
              mkdir -p "$spam_dir"

              # Move message to .Spam folder
              mv "$msg" "$spam_dir/"
              echo "  → SPAM (score: $score): $(basename "$msg")"
              SPAM_MOVED=$((SPAM_MOVED + 1))
              dir_count=$((dir_count + 1))
            fi
          done
        fi
      done

      if [ $dir_count -eq 0 ]; then
        echo "  No spam detected"
      fi
    }

    # Scan mailboxes for each user
    for user in "''${USERS[@]}"; do
      echo "Processing user: $user"
      user_root="$MAIL_ROOT/$user"

      # Check if user maildir exists
      if [ ! -d "$user_root" ]; then
        echo "  Maildir not found: $user_root"
        continue
      fi

      # # Scan root INBOX (flat maildir at /var/mail/user/)
      # if [ -d "$user_root/cur" ] || [ -d "$user_root/new" ]; then
      #   scan_maildir "$user_root" "$user/INBOX"
      # fi

      # Only scan the .Good folder (not all subfolders)
      if [ -d "$user_root/.Good" ]; then
        scan_maildir "$user_root/.Good" "$user/.Good"
      fi
    done

    echo ""
    echo "Mailbox scanning complete"
    echo "Messages scanned: $MESSAGES_SCANNED"
    echo "Spam messages moved: $SPAM_MOVED"
  '';

  # Sieve script for learning spam (when moved to TrainSpam)
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
  learnHamScript = pkgs.writeText "learn-ham.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainGood" {
      pipe :copy "rspamd-learn-ham.sh";
    }
  '';

  # Shell script to call rspamc learn_spam
  learnSpamShellScript = pkgs.writeShellScript "rspamd-learn-spam.sh" ''
    exec ${pkgs.rspamd}/bin/rspamc learn_spam
  '';

  # Shell script to call rspamc learn_ham
  learnHamShellScript = pkgs.writeShellScript "rspamd-learn-ham.sh" ''
    exec ${pkgs.rspamd}/bin/rspamc learn_ham
  '';

  # Sieve script to move trained spam to IsSpam folder
  moveToIsSpamScript = pkgs.writeText "move-to-isspam.sieve" ''
    require ["fileinto", "imap4flags"];

    # Move all messages in TrainSpam to IsSpam after learning
    fileinto "IsSpam";
  '';

  # Sieve script to move trained ham to IsGood folder
  moveToIsGoodScript = pkgs.writeText "move-to-isgood.sieve" ''
    require ["fileinto", "imap4flags"];

    # Move all messages in TrainGood to IsGood after learning
    fileinto "IsGood";
  '';
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
      '';
    };

    # Use local Redis instance for statistics
    locals = {
      "redis.conf".text = ''
        # Redis backend configuration for Bayes classifier
        servers = "127.0.0.1:6381";
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
        # Action thresholds
        reject = 15;
        add_header = 6;
        greylist = 4;
      '';

      "milter_headers.conf".text = ''
        # Add spam headers to messages
        use = ["x-spamd-bar", "x-spam-level", "x-spam-status", "authentication-results"];

        # Extended headers for better filtering
        extended_spam_headers = true;
      '';

      "metrics.conf".text = ''
        # Prometheus metrics export
        group "web" {
          path = "/metrics";
        }
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

  # Deploy Sieve scripts for spam/ham learning
  systemd.tmpfiles.rules = [
    "d /var/lib/dovecot/sieve/rspamd 0755 dovecot2 dovecot2 -"
    "L+ /var/lib/dovecot/sieve/rspamd/learn-spam.sieve - - - - ${learnSpamScript}"
    "L+ /var/lib/dovecot/sieve/rspamd/learn-ham.sieve - - - - ${learnHamScript}"
    "L+ /var/lib/dovecot/sieve/rspamd/move-to-isspam.sieve - - - - ${moveToIsSpamScript}"
    "L+ /var/lib/dovecot/sieve/rspamd/move-to-isgood.sieve - - - - ${moveToIsGoodScript}"
    "L+ /usr/local/bin/rspamd-learn-spam.sh - - - - ${learnSpamShellScript}"
    "L+ /usr/local/bin/rspamd-learn-ham.sh - - - - ${learnHamShellScript}"
  ];

  # Systemd service to scan mailboxes
  systemd.services.rspamd-scan-mailboxes = {
    description = "Scan mailboxes with Rspamd and move spam";

    # Ensure rspamd is running and mbsync is not active
    after = [ "rspamd.service" ];
    wants = [ "rspamd.service" ];
    conflicts = [ "mbsync-johnw.service" "mbsync-assembly.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${mailboxScannerScript}";
      User = "root";  # Need root to access /var/mail directories
      Group = "root";
    };
  };

  # Path unit to trigger scanner when mbsync completes
  systemd.paths.rspamd-scan-mailboxes = {
    description = "Trigger Rspamd scan after mbsync updates mailbox";
    wantedBy = [ "multi-user.target" ];

    pathConfig = {
      # Watch for changes in .Good folder (where new mail arrives)
      PathModified = "/var/mail/johnw/.Good";
      # Delay to ensure mbsync has fully completed
      TriggerLimitIntervalSec = "60s";
      TriggerLimitBurst = 1;
    };
  };

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
