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
  # Uses direct Nix store path - no indirection needed!
  learnSpamScript = pkgs.writeText "learn-spam.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainSpam" {
      pipe :copy "${learnSpamShellScript}";
    }
  '';

  # Sieve script for learning ham (when moved to TrainGood)
  # Uses direct Nix store path - no indirection needed!
  learnHamScript = pkgs.writeText "learn-ham.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainGood" {
      pipe :copy "${learnHamShellScript}";
    }
  '';

  # Sieve script to move trained spam to IsSpam folder
  moveToIsSpamScript = pkgs.writeText "move-to-isspam.sieve" ''
    require ["fileinto", "imap4flags"];

    # Move all messages in TrainSpam to IsSpam after learning
    fileinto "IsSpam";
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
      count = 1;
      extraConfig = ''
        milter = yes;
        timeout = 120s;
        upstream "local" {
          default = yes;
          self_scan = yes;
        }
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
        # Action thresholds - never reject, only add headers
        # Let Sieve handle spam filing based on X-Spam headers
        reject = 999;  # Effectively disable rejection
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
  # Note: Sieve scripts now use direct Nix store paths, no /usr/local/bin symlinks needed
  systemd.tmpfiles.rules = [
    "d /var/lib/dovecot/sieve/rspamd 0755 dovecot2 dovecot2 -"
    "L+ /var/lib/dovecot/sieve/rspamd/learn-spam.sieve - - - - ${learnSpamScript}"
    "L+ /var/lib/dovecot/sieve/rspamd/learn-ham.sieve - - - - ${learnHamScript}"
    "L+ /var/lib/dovecot/sieve/rspamd/move-to-isspam.sieve - - - - ${moveToIsSpamScript}"
    # move-to-good.sieve removed - TrainGood now uses process-good.sieve directly
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
