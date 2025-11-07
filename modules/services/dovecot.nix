{ config, lib, pkgs, ... }:

let
  # Sieve script to apply user's filtering rules when messages arrive in Good folder
  processGoodScript = pkgs.writeText "process-good.sieve" ''
    require ["include", "environment", "variables", "fileinto"];

    # Get the current user from the environment
    if environment :matches "imap.user" "*" {
      set "username" "''${1}";
    }

    # Include the user's personal filtering script
    # This applies their rules to messages that land in Good
    # Messages that don't match any rules will fall through to INBOX (implicit keep)
    include :personal "active";
  '';
in
{
  # Add Dovecot Pigeonhole (Sieve) support
  environment.systemPackages = with pkgs; [
    dovecot_pigeonhole
  ];

  # Create dovecot2 and mail groups for Dovecot
  users.groups.dovecot2 = {};
  users.groups.mail = {};

  # Create dovecot-exporter user for Prometheus monitoring
  users.users.dovecot-exporter = {
    isSystemUser = true;
    group = "dovecot-exporter";
  };
  users.groups.dovecot-exporter = {};

  # Users do NOT need dovecot2 group membership
  # Global Sieve scripts are pre-compiled by root during system activation
  # This maintains security by preventing users from modifying shared Dovecot files

  services.dovecot2 = {
    enable = true;

    # Enable IMAP protocol
    enableImap = true;

    # Enable PAM authentication for system users
    enablePAM = true;

    # Mail location using Maildir format
    mailLocation = "maildir:/var/mail/%u";

    # SSL/TLS certificate paths (will be created by step-ca)
    sslServerCert = "/var/lib/dovecot-certs/imap.vulcan.lan.fullchain.crt";
    sslServerKey = "/var/lib/dovecot-certs/imap.vulcan.lan.key";

    # Dovecot user and group
    user = "dovecot2";
    group = "dovecot2";

    # Enable mail plugins globally for old_stats (required for Prometheus exporter)
    # FTS (full-text search) with Xapian-based Flatcurve backend
    # Note: sieve is protocol-specific, not global - configured in LDA protocol below
    mailPlugins.globally.enable = [ "old_stats" "fts" "fts_flatcurve" ];

    # Extra configuration for advanced settings
    extraConfig = ''
      # Enable ManageSieve and LMTP protocols
      protocols = $protocols sieve lmtp

      # SSL/TLS configuration
      ssl = required
      ssl_min_protocol = TLSv1.2
      ssl_cipher_list = HIGH:!LOW:!SSLv2:!SSLv3:!EXP:!aNULL:!RC4:!DES:!MD5
      ssl_prefer_server_ciphers = yes
      ssl_dh = </var/lib/dovecot2/dh.pem

      # Disable plaintext authentication except over TLS
      disable_plaintext_auth = yes
      auth_mechanisms = plain login

      # Strip domain from usernames for system user authentication
      # This allows LMTP delivery to "user@localhost" or "user@domain" to match system user "user"
      auth_username_format = %Ln

      # Mail configuration
      mail_privileged_group = mail
      mail_access_groups = mail
      first_valid_uid = 1000

      # Protocol-specific settings
      protocol imap {
        mail_plugins = $mail_plugins old_stats fts fts_flatcurve imap_sieve
        imap_idle_notify_interval = 2 mins
        mail_max_userip_connections = 50
        imap_capability = +IDLE SORT THREAD=REFERENCES THREAD=REFS MULTIAPPEND UNSELECT CHILDREN NAMESPACE UIDPLUS LIST-EXTENDED I18NLEVEL=1 LITERAL+ NOTIFY SPECIAL-USE
      }

      # LDA (Local Delivery Agent) protocol
      protocol lda {
        mail_plugins = $mail_plugins sieve
      }

      # LMTP (Local Mail Transfer Protocol) for mail delivery
      # Used by fetchmail to deliver mail and trigger imapsieve
      protocol lmtp {
        mail_plugins = $mail_plugins sieve
      }

      # Service configuration
      service imap-login {
        inet_listener imap {
          port = 143
          ssl = no
        }
        inet_listener imaps {
          port = 993
          ssl = yes
        }

        # Connection limits
        service_count = 0
        process_min_avail = 3
        vsz_limit = 1024M
      }

      # IMAP service memory configuration
      service imap {
        # Increase memory limit to prevent OOM errors
        vsz_limit = 1024M

        # Process limits (optional, but recommended)
        process_limit = 1024
      }

      service auth {
        unix_listener auth-userdb {
          mode = 0666
          user = dovecot2
          group = dovecot2
        }
        # Increase client_limit to accommodate all protocol services
        # Calculated: managesieve-login(100) + lmtp(1024) + imap-urlauth-login(100) + imap-login(100) = 1324
        client_limit = 1500
      }

      # Old statistics service for Prometheus exporter compatibility
      service old-stats {
        unix_listener old-stats {
          user = dovecot-exporter
          group = dovecot-exporter
          mode = 0660
        }
        fifo_listener old-stats-mail {
          mode = 0666
          user = dovecot2
          group = dovecot2
        }
        fifo_listener old-stats-user {
          mode = 0666
          user = dovecot2
          group = dovecot2
        }
      }

      # New statistics service for general monitoring
      service stats {
        unix_listener stats-reader {
          user = dovecot-exporter
          group = dovecot-exporter
          mode = 0660
        }
        unix_listener stats-writer {
          user = dovecot2
          group = dovecot2
          mode = 0666
        }
      }

      # ManageSieve service for managing Sieve mail filtering scripts
      service managesieve-login {
        inet_listener sieve {
          port = 4190
        }
      }

      service managesieve {
        process_limit = 1024
      }

      # LMTP service for local mail delivery
      # Fetchmail will deliver to this UNIX socket to trigger imapsieve
      service lmtp {
        unix_listener lmtp {
          mode = 0666
          user = dovecot2
          group = dovecot2
        }
        process_limit = 1024
      }

      # Authentication configuration
      # First try passwd-file for Dovecot-specific accounts
      passdb {
        driver = passwd-file
        args = scheme=SHA512-CRYPT username_format=%n /var/lib/dovecot/users
      }

      # Fall back to PAM for system users
      passdb {
        driver = pam
        args = dovecot2
      }

      # User database from passwd-file first
      userdb {
        driver = passwd-file
        args = username_format=%n /var/lib/dovecot/users
      }

      # Fall back to system passwd
      userdb {
        driver = passwd
        args = blocking=no
      }

      # Logging
      log_path = syslog
      syslog_facility = mail
      auth_verbose = no
      auth_debug = no
      mail_debug = no
      verbose_ssl = no

      # Performance tuning
      mail_fsync = optimized
      mail_nfs_storage = no
      mail_nfs_index = no
      mmap_disable = yes

      # Lock timeout settings to prevent deadlocks
      mail_max_lock_timeout = 300s
      lock_method = fcntl

      # Index corruption prevention
      mail_index_rewrite_min_log_bytes = 8k
      mail_index_rewrite_max_log_bytes = 128k
      mail_cache_purge_delete_percentage = 20
      mail_cache_purge_continued_percentage = 200
      mail_cache_purge_header_continue_count = 4

      # mdbox-specific settings and FTS configuration
      plugin {
        # mdbox rotation size (10MB)
        mdbox_rotate_size = 10M
        # Keep mdbox index files in ALT storage if configured
        mdbox_altmove = 1w
        # Old stats configuration for Prometheus exporter
        old_stats_refresh = 30 secs
        old_stats_track_cmds = yes

        # Full-Text Search (FTS) with Flatcurve (Xapian-based)
        fts = flatcurve
        fts_autoindex = yes
        fts_enforced = body
        fts_languages = en
        fts_tokenizers = generic email-address
        fts_tokenizer_generic = algorithm=simple

        # Sieve mail filtering configuration
        # User scripts in home directory (Dovecot best practice)
        # Users can manage scripts via ManageSieve (port 4190)
        sieve = file:~/sieve;active=~/.dovecot.sieve
        sieve_global_dir = /var/lib/dovecot/sieve/global/
        sieve_default = /var/lib/dovecot/sieve/default.sieve
        sieve_default_name = default

        # Store compiled binaries for global imapsieve scripts in user's home directory
        # This prevents permission errors when Dovecot tries to cache compiled binaries
        # for global scripts referenced by imapsieve (process-good.sieve)
        sieve_script_bin_path = ~/sieve-bin

        # Sieve extensions
        sieve_extensions = +notify +imapflags +vacation-seconds +editheader +include
        sieve_max_script_size = 1M
        sieve_max_actions = 32
        sieve_max_redirects = 4

        # Rspamd training: TrainSpam folder (learn spam, then move to IsSpam)
        # Note: COPY includes IMAP MOVE operations (destination side)
        imapsieve_mailbox1_name = TrainSpam
        imapsieve_mailbox1_causes = COPY APPEND
        imapsieve_mailbox1_before = file:/var/lib/dovecot/sieve/rspamd/learn-spam.sieve
        imapsieve_mailbox1_after = file:/var/lib/dovecot/sieve/rspamd/move-to-isspam.sieve

        # Rspamd training: TrainGood folder (learn ham, then re-filter via Sieve)
        imapsieve_mailbox2_name = TrainGood
        imapsieve_mailbox2_causes = COPY APPEND
        imapsieve_mailbox2_before = file:/var/lib/dovecot/sieve/rspamd/learn-ham.sieve
        imapsieve_mailbox2_after = file:/var/lib/dovecot/sieve/process-good.sieve

        # Process Good folder: Apply user filtering rules to sort messages
        imapsieve_mailbox3_name = Good
        imapsieve_mailbox3_causes = COPY APPEND
        imapsieve_mailbox3_before = file:/var/lib/dovecot/sieve/process-good.sieve

        # Sieve pipe configuration
        # Note: Using sieve_extprograms with direct Nix store paths, no bin_dir needed
        sieve_plugins = sieve_imapsieve sieve_extprograms

        # Sieve debug logging (enabled for troubleshooting LMTP mailbox visibility)
        sieve_trace_debug = yes
        sieve_trace_addresses = yes

        # Disable compiled binary caching for global/shared scripts
        # Users can't write to /var/lib/dovecot/sieve, so don't try to save .svbin files there
        sieve_global_extensions = +vnd.dovecot.pipe +editheader +notify +imapflags
      }

      # Mailbox configuration
      namespace inbox {
        type = private
        separator = /
        prefix =
        inbox = yes

        # Gmail-compatible folder mapping
        mailbox "[Gmail]/Drafts" {
          special_use = \Drafts
        }
        mailbox "[Gmail]/Sent Mail" {
          special_use = \Sent
        }
        mailbox "[Gmail]/Trash" {
          special_use = \Trash
        }
        mailbox "[Gmail]/Spam" {
          special_use = \Junk
        }
      }
    '';
  };

  # Prometheus Dovecot exporter
  services.prometheus.exporters.dovecot = {
    enable = true;
    port = 9166;
    socketPath = "/var/run/dovecot2/old-stats";
    user = "dovecot-exporter";
    group = "dovecot-exporter";
  };

  # Ensure certificate, FTS index, Sieve, and mail directories exist with
  # proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/dovecot-certs 0755 root root -"
    "d /var/lib/dovecot2 0755 dovecot2 dovecot2 -"
    "d /var/lib/dovecot 0755 root dovecot2 -"
    "d /var/lib/dovecot-fts 0755 dovecot2 dovecot2 -"
    # Sieve directory with restrictive permissions (read-only for non-dovecot users)
    # Scripts are pre-compiled during system activation, users don't need write access
    "d /var/lib/dovecot/sieve 0755 dovecot2 dovecot2 -"
    "d /var/lib/dovecot/sieve/global 0755 dovecot2 dovecot2 -"
    "d /var/mail/johnw 0700 johnw users -"
    "d /var/mail/assembly 0700 assembly users -"
    "L+ /var/lib/dovecot/sieve/process-good.sieve - - - - ${processGoodScript}"
    # Create sieve-bin directory for compiled binaries from global scripts
    "d /home/johnw/sieve-bin 0700 johnw users -"
    "d /home/assembly/sieve-bin 0700 assembly users -"
  ];

  # Pre-compile global Sieve scripts to avoid permission errors
  systemd.services.dovecot-sieve-compile = {
    description = "Pre-compile Dovecot global Sieve scripts";
    wantedBy = [ "dovecot2.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    before = [ "dovecot2.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ dovecot_pigeonhole coreutils ];
    script = ''
      # Pre-compile all global Sieve scripts so users don't need write permission
      # IMPORTANT: Touch .svbin files after compilation to ensure they have NEWER
      # timestamps than .sieve sources. Dovecot considers binaries "outdated" if
      # timestamps are identical or older, causing recompilation attempts that fail
      # due to correct restrictive permissions.
      echo "Pre-compiling global Sieve scripts..."

      for script in /var/lib/dovecot/sieve/global/*.sieve /var/lib/dovecot/sieve/rspamd/*.sieve /var/lib/dovecot/sieve/*.sieve; do
        if [ -f "$script" ]; then
          echo "  Compiling: $script"
          if sievec "$script"; then
            # Touch the compiled binary to ensure it has a newer timestamp
            binary="''${script%.sieve}.svbin"
            if [ -f "$binary" ]; then
              touch "$binary"
              echo "  ✓ Compiled and timestamp updated: $binary"
            fi
          else
            echo "  ✗ Warning: Failed to compile $script"
          fi
        fi
      done

      echo "Sieve compilation complete"
    '';
  };

  # Note: dovecot-sieve-migrate service removed - user scripts now managed
  # via ManageSieve protocol in ~/sieve directory per Dovecot best practices

  # Generate DH parameters if they don't exist
  systemd.services.dovecot-dh-params = {
    description = "Generate Dovecot DH parameters";
    wantedBy = [ "dovecot2.service" ];
    before = [ "dovecot2.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.openssl ];
    script = ''
      if [ ! -f /var/lib/dovecot2/dh.pem ]; then
        echo "Generating DH parameters for Dovecot (this may take a while)..."
        openssl dhparam -out /var/lib/dovecot2/dh.pem 2048
        chmod 644 /var/lib/dovecot2/dh.pem
        chown dovecot2:dovecot2 /var/lib/dovecot2/dh.pem
      fi
    '';
  };

  # Prometheus scrape configuration for Dovecot exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "dovecot";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.dovecot.port}" ];
      }];
    }
  ];

  networking.firewall.allowedTCPPorts =
    lib.mkIf config.services.dovecot2.enable [ 993 4190 ];

  # Increase file descriptor limit for Dovecot to accommodate auth client_limit
  # client_limit=1500 requires fd limit >= 1500
  systemd.services.dovecot.serviceConfig.LimitNOFILE = 2048;
}
