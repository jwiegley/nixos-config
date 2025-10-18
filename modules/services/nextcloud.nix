{ config, lib, pkgs, ... }:

{
  # SOPS secrets for Nextcloud
  sops.secrets = {
    "nextcloud-admin-password" = {
      sopsFile = ../../secrets.yaml;
      owner = "nextcloud";
      group = "nextcloud";
      mode = "0400";
    };
    "nextcloud-db-password" = {
      sopsFile = ../../secrets.yaml;
      owner = "postgres";
      group = "nextcloud";
      mode = "0440";
    };
    "nextcloud-monitoring-password" = {
      sopsFile = ../../secrets.yaml;
      owner = "nextcloud-exporter";
      group = "nextcloud-exporter";
      mode = "0400";
    };
  };

  # Nextcloud service configuration
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud32;
    hostName = "nextcloud.vulcan.lan";
    https = true;

    # Database configuration
    config = {
      dbtype = "pgsql";
      dbhost = "/run/postgresql";
      dbname = "nextcloud";
      dbuser = "nextcloud";
      dbpassFile = config.sops.secrets."nextcloud-db-password".path;
      adminuser = "admin";
      adminpassFile = config.sops.secrets."nextcloud-admin-password".path;
    };

    # Use default datadir (/var/lib/nextcloud/data)
    # We'll configure systemd.tmpfiles to bind mount /tank/Nextcloud to it

    # Enable Redis caching
    configureRedis = true;
    caching.redis = true;
    caching.apcu = true;

    # Enable ImageMagick for preview generation
    enableImagemagick = true;

    # Allow app installation from app store
    extraAppsEnable = true;
    appstoreEnable = true;

    # PHP configuration
    phpOptions = {
      # Memory settings
      "memory_limit" = lib.mkForce "512M";
      "upload_max_filesize" = lib.mkForce "10G";
      "post_max_size" = lib.mkForce "10G";
      "max_execution_time" = lib.mkForce "3600";
      "max_input_time" = lib.mkForce "3600";

      # OPcache configuration
      "opcache.enable" = lib.mkForce "1";
      "opcache.memory_consumption" = lib.mkForce "256";
      "opcache.interned_strings_buffer" = lib.mkForce "16";
      "opcache.max_accelerated_files" = lib.mkForce "10000";
      "opcache.validate_timestamps" = lib.mkForce "1";
      "opcache.revalidate_freq" = lib.mkForce "60";
    };

    # PHP-FPM pool settings
    poolSettings = {
      "pm" = "dynamic";
      "pm.max_children" = "50";
      "pm.start_servers" = "10";
      "pm.min_spare_servers" = "5";
      "pm.max_spare_servers" = "15";
      "pm.max_requests" = "500";
      "pm.status_path" = "/status";
    };

    # Nextcloud settings
    settings = {
      default_phone_region = "US";
      maintenance_window_start = 1;  # 1 AM maintenance window
      trusted_domains = [ "nextcloud.vulcan.lan" ];
      log_level = 2;  # Warning level

      # Redis configuration
      "memcache.local" = "\\OC\\Memcache\\APCu";
      "memcache.distributed" = "\\OC\\Memcache\\Redis";
      "memcache.locking" = "\\OC\\Memcache\\Redis";

      # Email configuration (using existing Postfix)
      mail_smtpmode = "smtp";
      mail_smtphost = "localhost";
      mail_smtpport = 25;
      mail_from_address = "nextcloud";
      mail_domain = "newartisans.com";
    };
  };

  # Redis server for Nextcloud
  services.redis.servers.nextcloud = {
    enable = true;
    port = 0;  # Unix socket only
    unixSocket = "/run/redis-nextcloud/redis.sock";
    unixSocketPerm = 770;
  };

  # Nginx virtual host
  services.nginx.virtualHosts."nextcloud.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/nextcloud.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/nextcloud.vulcan.lan.key";

    # Security headers
    extraConfig = ''
      # Strict Transport Security
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

      # Security headers
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-XSS-Protection "1; mode=block" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    '';

    # PHP-FPM status endpoint for monitoring
    locations."/fpm-status" = {
      extraConfig = ''
        access_log off;
        allow 127.0.0.1;
        deny all;
        include ${pkgs.nginx}/conf/fastcgi_params;
        fastcgi_pass unix:${config.services.phpfpm.pools.nextcloud.socket};
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
      '';
    };
  };

  # Prometheus Nextcloud exporter
  services.prometheus.exporters.nextcloud = {
    enable = true;
    port = 9205;
    url = "https://nextcloud.vulcan.lan";
    username = "monitoring";
    passwordFile = config.sops.secrets."nextcloud-monitoring-password".path;
  };

  # Create required Nextcloud directories with proper ownership
  # Include /var/lib/nextcloud/data so it exists even when tank isn't mounted
  systemd.tmpfiles.rules = [
    "d /var/lib/nextcloud/config 0750 nextcloud nextcloud -"
    "d /var/lib/nextcloud/store-apps 0750 nextcloud nextcloud -"
    "d /var/lib/nextcloud/apps 0750 nextcloud nextcloud -"
    "d /var/lib/nextcloud/data 0750 nextcloud nextcloud -"
  ];

  # Bind mount ZFS dataset to Nextcloud data directory
  fileSystems."/var/lib/nextcloud/data" = {
    device = "/tank/Nextcloud";
    options = [
      "bind"
      "nofail"  # Don't block boot/activation if mount fails
      "x-systemd.after=zfs-import-tank.service"
    ];
  };

  # Systemd hardening for PHP-FPM
  systemd.services.phpfpm-nextcloud.serviceConfig = {
    PrivateTmp = true;
    ProtectHome = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictRealtime = true;
  };

  # Fix nextcloud-setup service to wait for PostgreSQL AND the nextcloud data mount
  # Note: We use 'after' but not 'requires' for the mount to allow activation without tank
  systemd.services.nextcloud-setup = {
    after = [ "postgresql.service" "var-lib-nextcloud-data.mount" ];
    requires = [ "postgresql.service" ];
  };
}
