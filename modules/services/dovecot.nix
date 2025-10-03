{ config, lib, pkgs, ... }:

{
  # Create dovecot2 and mail groups for Dovecot
  users.groups.dovecot2 = {};
  users.groups.mail = {};

  # Create dovecot-exporter user for Prometheus monitoring
  users.users.dovecot-exporter = {
    isSystemUser = true;
    group = "dovecot-exporter";
  };
  users.groups.dovecot-exporter = {};

  services.dovecot2 = {
    enable = true;

    # Enable IMAP protocol
    enableImap = true;

    # Enable PAM authentication for system users
    enablePAM = true;

    # Mail location using Maildir format on ZFS storage
    mailLocation = "maildir:/var/mail/%u";

    # SSL/TLS certificate paths (will be created by step-ca)
    sslServerCert = "/var/lib/dovecot-certs/imap.vulcan.lan.fullchain.crt";
    sslServerKey = "/var/lib/dovecot-certs/imap.vulcan.lan.key";

    # Dovecot user and group
    user = "dovecot2";
    group = "dovecot2";

    # Enable mail plugins globally for old_stats (required for Prometheus exporter)
    # and FTS (full-text search) with Xapian-based Flatcurve backend
    mailPlugins.globally.enable = [ "old_stats" "fts" "fts_flatcurve" ];

    # Extra configuration for advanced settings
    extraConfig = ''
      # SSL/TLS configuration
      ssl = required
      ssl_min_protocol = TLSv1.2
      ssl_cipher_list = HIGH:!LOW:!SSLv2:!SSLv3:!EXP:!aNULL:!RC4:!DES:!MD5
      ssl_prefer_server_ciphers = yes
      ssl_dh = </var/lib/dovecot2/dh.pem

      # Disable plaintext authentication except over TLS
      disable_plaintext_auth = yes
      auth_mechanisms = plain login

      # Mail configuration
      mail_privileged_group = mail
      mail_access_groups = mail
      first_valid_uid = 1000

      # Protocol-specific settings
      protocol imap {
        mail_plugins = $mail_plugins old_stats fts fts_flatcurve
        imap_idle_notify_interval = 2 mins
        imap_capability = +IDLE SORT THREAD=REFERENCES THREAD=REFS MULTIAPPEND UNSELECT CHILDREN NAMESPACE UIDPLUS LIST-EXTENDED I18NLEVEL=1 LITERAL+ NOTIFY SPECIAL-USE
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

  # Ensure certificate and FTS index directories exist with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/dovecot-certs 0755 root root -"
    "d /var/lib/dovecot2 0755 dovecot2 dovecot2 -"
    "d /var/lib/dovecot 0755 root dovecot2 -"
    "d /var/lib/dovecot-fts 0755 dovecot2 dovecot2 -"
  ];

  # Override dovecot service to require /tank/Maildir mount
  systemd.services.dovecot = {
    # Ensure dovecot only starts after the mail storage is mounted
    after = [ "tank-Maildir.mount" ];
    requires = [ "tank-Maildir.mount" ];

    # Use RequiresMountsFor for more robust dependency handling
    unitConfig = {
      RequiresMountsFor = [ "/tank/Maildir" ];
    };

    # Pre-start check to verify mount and directories
    preStart = ''
      # Verify mount is actually available
      if ! ${pkgs.util-linux}/bin/mountpoint -q /tank/Maildir; then
        echo "ERROR: /tank/Maildir is not mounted"
        exit 1
      fi

      # Verify user directories exist or create them
      for user in johnw assembly; do
        if [ ! -d "/tank/Maildir/$user" ]; then
          echo "Creating mail directory for $user"
          mkdir -p "/tank/Maildir/$user"
          chown "$user:users" "/tank/Maildir/$user"
        else
          echo "Verified: /tank/Maildir/$user exists"
        fi
      done
    '';
  };

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

  networking.firewall.allowedTCPPorts =
    lib.mkIf config.services.dovecot2.enable [ 993 ];
}
