{ config, lib, pkgs, ... }:

let
  # Helper script to scan mailboxes with rspamc and process training folders
  mailboxScannerScript = pkgs.writeShellScript "rspamd-scan-mailboxes" ''
    set -euo pipefail

    # Configuration
    USERS=("johnw" "assembly")
    MAIL_ROOT="/var/mail"
    SPAM_THRESHOLD=6  # Rspamd score threshold for spam (matches "add header" action)
    RSPAMC="${pkgs.rspamd}/bin/rspamc"
    DOVEADM="${pkgs.dovecot}/bin/doveadm"

    # Counters
    GOOD_SCANNED=0
    GOOD_SPAM_MOVED=0
    GOOD_HAM_DELIVERED=0
    TRAIN_GOOD_LEARNED=0
    TRAIN_GOOD_DELIVERED=0
    TRAIN_SPAM_LEARNED=0
    TRAIN_SPAM_MOVED=0

    # Process .Good folder: scan with rspamd, move spam or deliver ham via sieve
    process_good() {
      local user=$1
      local maildir="$MAIL_ROOT/$user/.Good"

      if [ ! -d "$maildir" ]; then
        return
      fi

      echo "Processing .Good for $user..."

      # Process messages in new/ and cur/
      for dir in new cur; do
        if [ ! -d "$maildir/$dir" ]; then
          continue
        fi

        for msg in "$maildir/$dir"/*; do
          [ -f "$msg" ] || continue

          # Scan with rspamd
          result=$($RSPAMC --json < "$msg" 2>/dev/null || true)
          score=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.default.score // 0' 2>/dev/null || echo "0")

          GOOD_SCANNED=$((GOOD_SCANNED + 1))

          # Check if spam
          if (( $(echo "$score > $SPAM_THRESHOLD" | ${pkgs.bc}/bin/bc -l) )); then
            # Move to .Spam
            spam_dir="$MAIL_ROOT/$user/.Spam/cur"
            mkdir -p "$spam_dir"
            mv "$msg" "$spam_dir/"
            echo "  → SPAM (score: $score): $(basename "$msg")"
            GOOD_SPAM_MOVED=$((GOOD_SPAM_MOVED + 1))
          else
            # Deliver ham through sieve filter
            if [ -f "/var/lib/dovecot/sieve/users/$user/.dovecot.sieve" ]; then
              if $DOVEADM sieve filter -u "$user" /var/lib/dovecot/sieve/users/$user/.dovecot.sieve < "$msg" 2>/dev/null; then
                rm -f "$msg"
                echo "  → HAM delivered via sieve: $(basename "$msg")"
                GOOD_HAM_DELIVERED=$((GOOD_HAM_DELIVERED + 1))
              else
                echo "  ⚠ Sieve delivery failed, keeping in .Good: $(basename "$msg")"
              fi
            else
              echo "  ⚠ No sieve script found for $user, keeping in .Good: $(basename "$msg")"
            fi
          fi
        done
      done
    }

    # Process .TrainGood folder: learn as ham, then deliver via sieve
    process_train_good() {
      local user=$1
      local maildir="$MAIL_ROOT/$user/.TrainGood"

      if [ ! -d "$maildir" ]; then
        return
      fi

      echo "Processing .TrainGood for $user..."

      for dir in new cur; do
        if [ ! -d "$maildir/$dir" ]; then
          continue
        fi

        for msg in "$maildir/$dir"/*; do
          [ -f "$msg" ] || continue

          # Learn as ham
          if $RSPAMC learn_ham < "$msg" >/dev/null 2>&1; then
            echo "  → Learned HAM: $(basename "$msg")"
            TRAIN_GOOD_LEARNED=$((TRAIN_GOOD_LEARNED + 1))

            # Deliver through sieve filter
            if [ -f "/var/lib/dovecot/sieve/users/$user/.dovecot.sieve" ]; then
              if $DOVEADM sieve filter -u "$user" /var/lib/dovecot/sieve/users/$user/.dovecot.sieve < "$msg" 2>/dev/null; then
                rm -f "$msg"
                echo "  → Delivered via sieve: $(basename "$msg")"
                TRAIN_GOOD_DELIVERED=$((TRAIN_GOOD_DELIVERED + 1))
              else
                echo "  ⚠ Sieve delivery failed, removing from .TrainGood: $(basename "$msg")"
                rm -f "$msg"
              fi
            else
              echo "  ⚠ No sieve script found for $user, removing: $(basename "$msg")"
              rm -f "$msg"
            fi
          else
            echo "  ⚠ Failed to learn: $(basename "$msg")"
          fi
        done
      done
    }

    # Process .TrainSpam folder: learn as spam, then move to .Spam (unread)
    process_train_spam() {
      local user=$1
      local maildir="$MAIL_ROOT/$user/.TrainSpam"

      if [ ! -d "$maildir" ]; then
        return
      fi

      echo "Processing .TrainSpam for $user..."

      spam_dest="$MAIL_ROOT/$user/.IsSpam/new"
      mkdir -p "$spam_dest"

      for dir in new cur; do
        if [ ! -d "$maildir/$dir" ]; then
          continue
        fi

        for msg in "$maildir/$dir"/*; do
          [ -f "$msg" ] || continue

          # Learn as spam
          if $RSPAMC learn_spam < "$msg" >/dev/null 2>&1; then
            echo "  → Learned SPAM: $(basename "$msg")"
            TRAIN_SPAM_LEARNED=$((TRAIN_SPAM_LEARNED + 1))

            # Move to .IsSpam/new (unread)
            mv "$msg" "$spam_dest/"
            echo "  → Moved to .IsSpam: $(basename "$msg")"
            TRAIN_SPAM_MOVED=$((TRAIN_SPAM_MOVED + 1))
          else
            echo "  ⚠ Failed to learn: $(basename "$msg")"
          fi
        done
      done
    }

    # Main processing loop
    echo "=== Rspamd Mailbox Scanner ==="
    echo ""

    for user in "''${USERS[@]}"; do
      echo "User: $user"
      user_root="$MAIL_ROOT/$user"

      if [ ! -d "$user_root" ]; then
        echo "  Maildir not found: $user_root"
        echo ""
        continue
      fi

      # Process all three mailboxes
      process_good "$user"
      process_train_good "$user"
      process_train_spam "$user"

      echo ""
    done

    # Summary
    echo "=== Summary ==="
    echo ".Good: scanned=$GOOD_SCANNED, spam_moved=$GOOD_SPAM_MOVED, ham_delivered=$GOOD_HAM_DELIVERED"
    echo ".TrainGood: learned=$TRAIN_GOOD_LEARNED, delivered=$TRAIN_GOOD_DELIVERED"
    echo ".TrainSpam: learned=$TRAIN_SPAM_LEARNED, moved=$TRAIN_SPAM_MOVED"
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

        # IMPORTANT: Use single controller worker for RRD support
        # Multiple controller workers break RRD graphs
        count = 1;
      '';
    };

    # Use local Redis instance for statistics
    locals = {
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
