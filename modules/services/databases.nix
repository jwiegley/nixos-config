{ config, lib, pkgs, ... }:

{
  services = {
    redis.servers.litellm = {
      enable = true;
      port = 8085;
      settings = {
        aclfile = "/etc/redis/users.acl";
      };
    };

    postgresql = {
      enable = true;
      enableTCPIP = true;

      settings = {
        port = 5432;

        # SSL/TLS configuration
        ssl = true;
        ssl_cert_file = "/var/lib/postgresql/certs/server.crt";  # Absolute path
        ssl_key_file = "/var/lib/postgresql/certs/server.key";   # Absolute path
        ssl_ca_file = "/var/lib/postgresql/certs/root_ca.crt";   # For client certificate validation
        ssl_ciphers = "HIGH:MEDIUM:+3DES:!aNULL";
        ssl_prefer_server_ciphers = true;
        ssl_min_protocol_version = "TLSv1.2";
        ssl_max_protocol_version = "TLSv1.3";
      };

      ensureDatabases = [ "db" "litellm" "wallabag" ];
      ensureUsers = [
        { name = "postgres"; }
      ];
      # dataDir = "/var/lib/postgresql/16";

      authentication = lib.mkOverride 10 ''
        # TYPE  DATABASE  USER  ADDRESS         METHOD

        # Localhost connections - no SSL required
        local   all       all                   trust
        host    all       all   127.0.0.1/32    trust
        host    all       all   ::1/128         trust

        # Podman network - no SSL required
        host    all       all   10.88.0.0/16    trust

        # Local networks - SSL required with stronger authentication
        hostssl all       all   192.168.1.0/24  scram-sha-256
        hostssl all       all   10.6.0.0/16     scram-sha-256
      '';
    };
  };

  # PostgreSQL certificate management
  systemd.services.postgresql-cert-init = {
    description = "Initialize PostgreSQL SSL certificates";
    wantedBy = [ "postgresql.service" ];
    before = [ "postgresql.service" ];
    after = [ "step-ca.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/postgresql-cert-renew.sh";
    };
  };

  # Weekly certificate renewal timer
  systemd.timers.postgresql-cert-renewal = {
    description = "PostgreSQL certificate renewal timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemd.services.postgresql-cert-renewal = {
    description = "Renew PostgreSQL SSL certificates";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/postgresql-cert-renew.sh";
      ExecStartPost = "${pkgs.systemd}/bin/systemctl reload postgresql";
    };
  };
}
