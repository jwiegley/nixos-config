{ config, lib, pkgs, ... }:

{
  # SOPS secret for Roundcube database password
  # Group must be nginx because PHP-FPM runs as nginx user
  sops.secrets."roundcube-db-password" = {
    owner = "roundcube";
    group = "nginx";
    mode = "0440";  # Readable by owner and group
    # Don't restart services on secret change - manual restart required
    # restartUnits = [ "phpfpm-roundcube.service" "roundcube-setup.service" ];
  };

  # Roundcube group (user is created by roundcube module)
  users.groups.roundcube = {};
  users.groups.redis-roundcube = {};

  # Redis server for Roundcube session storage
  services.redis.servers.roundcube = {
    enable = true;
    port = 0;  # Unix socket only
    unixSocket = "/run/redis-roundcube/redis.sock";
    unixSocketPerm = 770;
  };

  # Roundcube webmail service
  services.roundcube = {
    enable = true;
    package = pkgs.roundcube;
    hostName = "webmail.vulcan.lan";

    # Disable automatic nginx configuration - we'll configure it manually
    configureNginx = false;

    # Maximum attachment size (25MB + 37% overhead = ~34MB actual)
    maxAttachmentSize = 25;

    # PostgreSQL database configuration
    # Use 127.0.0.1 instead of localhost to force TCP/IP connection
    # This ensures passwordFile is properly used in the DSN
    database = {
      host = "127.0.0.1";
      dbname = "roundcube";
      username = "roundcube";
      passwordFile = config.sops.secrets."roundcube-db-password".path;
    };

    # Enable plugins
    plugins = [
      "archive"
      "zipdownload"
      "managesieve"
      "markasjunk"
      "newmail_notifier"
    ];

    # Spell checking dictionaries
    dicts = with pkgs.aspellDicts; [ en en-computers en-science ];

    # Custom configuration for IMAP, SMTP, Redis, and other settings
    extraConfig = ''
      # IMAP Configuration (Dovecot on localhost)
      $config['default_host'] = 'ssl://localhost';
      $config['default_port'] = 993;  # IMAPS port
      $config['imap_conn_options'] = [
        'ssl' => [
          'verify_peer' => false,        # Localhost self-signed cert
          'verify_peer_name' => false,
        ],
      ];

      # SMTP Configuration (Postfix on localhost)
      $config['smtp_server'] = 'tls://localhost';
      $config['smtp_port'] = 587;  # Submission port with STARTTLS
      $config['smtp_user'] = '%u';  # Use IMAP username
      $config['smtp_pass'] = '%p';  # Use IMAP password
      $config['smtp_conn_options'] = [
        'ssl' => [
          'verify_peer' => false,        # Localhost self-signed cert
          'verify_peer_name' => false,
        ],
      ];

      # Session and cache configuration using database
      # Note: Redis requires php-redis extension which is not in default Roundcube package
      $config['session_storage'] = 'db';

      # Cache configuration using database
      $config['imap_cache'] = 'db';
      $config['messages_cache'] = 'db';

      # UI/UX Settings
      $config['product_name'] = 'Vulcan Webmail';
      $config['skin'] = 'elastic';  # Modern responsive skin
      $config['language'] = 'en_US';
      $config['date_format'] = 'Y-m-d';
      $config['time_format'] = 'H:i';
      $config['timezone'] = 'America/Los_Angeles';

      # Identity and compose settings
      $config['identities_level'] = 0;  # Users can edit all identity fields
      $config['reply_mode'] = 1;  # Reply above the quote
      $config['htmleditor'] = 1;  # Enable HTML editor by default
      $config['draft_autosave'] = 60;  # Autosave drafts every 60 seconds

      # Security settings
      $config['force_https'] = true;
      $config['login_autocomplete'] = 2;  # Autocomplete off
      $config['ip_check'] = true;  # Check IP in session validation
      $config['des_key'] = file_get_contents('/var/lib/roundcube/des_key');
      $config['useragent'] = 'Roundcube Webmail';  # Don't reveal version

      # Performance settings
      $config['enable_installer'] = false;
      $config['log_driver'] = 'syslog';
      $config['syslog_facility'] = LOG_MAIL;

      # Attachment settings
      $config['mime_param_folding'] = 1;  # Better attachment handling
      $config['message_cache_lifetime'] = '10d';

      # Address book settings
      $config['autocomplete_addressbooks'] = ['sql'];
    '';
  };

  # Configure PHP-FPM to listen on localhost TCP port instead of Unix socket
  services.phpfpm.pools.roundcube.settings = {
    "listen" = lib.mkForce "127.0.0.1:9001";
    "listen.owner" = lib.mkForce "nginx";
    "listen.group" = lib.mkForce "nginx";
  };

  # Nginx reverse proxy configuration for Roundcube
  # Roundcube runs on localhost:9001, nginx proxies to it
  # IMPORTANT: Disable ACME (enabled by default in roundcube module) to use Step-CA certificates
  services.nginx.virtualHosts."webmail.vulcan.lan" = {
    forceSSL = true;
    enableACME = lib.mkForce false;  # Override roundcube module's default enableACME=true
    sslCertificate = "/var/lib/nginx-certs/webmail.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/webmail.vulcan.lan.key";

    # Serve Roundcube static files and proxy PHP to FastCGI
    root = "${pkgs.roundcube}";

    locations."/" = {
      index = "index.php";
      extraConfig = ''
        add_header Cache-Control 'public, max-age=604800, must-revalidate';
      '';
    };

    # Block access to sensitive directories
    locations."~ ^/(SQL|bin|config|logs|temp|vendor)/" = {
      return = "404";
    };

    # Block access to sensitive files
    locations."~ ^/(CHANGELOG.md|INSTALL|LICENSE|README.md|SECURITY.md|UPGRADING|composer.json|composer.lock)" = {
      return = "404";
    };

    # PHP FastCGI proxy
    locations."~* \\.php(/|$)" = {
      extraConfig = ''
        fastcgi_pass 127.0.0.1:9001;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include ${pkgs.nginx}/conf/fastcgi.conf;
      '';
    };
  };

  # Create DES encryption key for Roundcube
  systemd.services.roundcube-setup-des-key = {
    description = "Generate Roundcube DES encryption key";
    wantedBy = [ "multi-user.target" ];
    before = [ "phpfpm-roundcube.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      if [ ! -f /var/lib/roundcube/des_key ]; then
        mkdir -p /var/lib/roundcube
        ${pkgs.openssl}/bin/openssl rand -base64 24 > /var/lib/roundcube/des_key
        chmod 400 /var/lib/roundcube/des_key
        chown roundcube:roundcube /var/lib/roundcube/des_key
      fi
    '';
  };

  # Create .pgpass file for roundcube-setup service
  # The NixOS module uses PGPASSFILE but needs proper .pgpass format
  systemd.services.roundcube-pgpass-setup = {
    description = "Generate .pgpass file for Roundcube database setup";
    wantedBy = [ "multi-user.target" ];
    before = [ "roundcube-setup.service" ];
    after = [ "postgresql.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "roundcube";
      Group = "roundcube";
      StateDirectory = "roundcube";
      StateDirectoryMode = "0700";
    };

    script = ''
      # Format: hostname:port:database:username:password
      echo "127.0.0.1:5432:roundcube:roundcube:$(cat ${config.sops.secrets."roundcube-db-password".path})" > /var/lib/roundcube/.pgpass
      chmod 600 /var/lib/roundcube/.pgpass
    '';
  };

  # Override roundcube-setup service to use systemd LoadCredential
  # LoadCredential creates an isolated copy the roundcube user can read
  systemd.services.roundcube-setup = {
    serviceConfig = {
      LoadCredential = "db-password:${config.sops.secrets."roundcube-db-password".path}";
    };

    script = lib.mkForce ''
      set -e

      # Export password from systemd credentials directory
      export PGPASSWORD="$(cat $CREDENTIALS_DIRECTORY/db-password)"

      version="$(psql -h 127.0.0.1 -U roundcube roundcube -t <<< "select value from system where name = 'roundcube-version';" || true)"
      if ! (grep -E '[a-zA-Z0-9]' <<< "$version"); then
        psql -h 127.0.0.1 -U roundcube roundcube -f ${pkgs.roundcube}/SQL/postgres.initial.sql
      fi

      if [ ! -f /var/lib/roundcube/des_key ]; then
        base64 /dev/urandom | head -c 24 > /var/lib/roundcube/des_key;
        # we need to log out everyone in case change the des_key
        # from the default when upgrading from nixos 19.09
        psql -h 127.0.0.1 -U roundcube roundcube <<< 'TRUNCATE TABLE session;'
      fi

      ${pkgs.php}/bin/php ${pkgs.roundcube}/bin/update.sh
    '';
  };

  # Add roundcube user to redis-roundcube and nginx groups
  # The roundcube user is created by the roundcube module, we just add extra groups
  # nginx group: needed to read SOPS secret (since PHP-FPM runs as nginx)
  # redis-roundcube group: needed to access Redis socket
  users.users.roundcube = {
    isSystemUser = true;
    group = "roundcube";
    extraGroups = [ "redis-roundcube" "nginx" ];
  };

}
