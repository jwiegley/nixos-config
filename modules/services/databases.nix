{ config, lib, pkgs, ... }:

let
  # Import helper functions
  common = import ../lib/common.nix { };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL passwords for database users
    (mkPostgresUserSetup {
      user = "nextcloud";
      database = "nextcloud";
      secretPath = config.sops.secrets."nextcloud-db-password".path;
      dependentService = "nextcloud-setup.service";
    })
    (mkPostgresUserSetup {
      user = "ragflow";
      database = "ragflow";
      secretPath = config.sops.secrets."ragflow-db-password".path;
      dependentService = "ragflow.service";
    })
    (mkPostgresUserSetup {
      user = "nocobase";
      database = "nocobase";
      secretPath = config.sops.secrets."nocobase-db-password".path;
      dependentService = "nocobase.service";
    })
  ];

  services = {
    postgresql = {
      enable = true;
      enableTCPIP = true;

      package = pkgs.postgresql_17.withPackages (p: [ p.pgvector ]);

      settings = {
        port = 5432;

        # Network Security - Restrict to specific interfaces
        listen_addresses = lib.mkForce "localhost,192.168.1.2,10.88.0.1";
        ssl = true;
        ssl_cert_file = "/var/lib/postgresql/certs/server.crt";
        ssl_key_file = "/var/lib/postgresql/certs/server.key";
        ssl_ca_file = "/var/lib/postgresql/certs/root_ca.crt";
        ssl_ciphers = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4:!3DES";
        ssl_prefer_server_ciphers = true;
        ssl_min_protocol_version = "TLSv1.2";
        ssl_max_protocol_version = "TLSv1.3";

        # Authentication settings
        password_encryption = "scram-sha-256";
      };

      ensureDatabases = [
        "litellm"
        "wallabag"
        "nextcloud"
        "ragflow"
        "nocobase"
      ];
      ensureUsers = [
        { name = "postgres"; }
        { name = "johnw"; }
        { name = "litellm"; }
        { name = "wallabag"; }
        {
          name = "nextcloud";
          ensureDBOwnership = true;
        }
        {
          name = "ragflow";
          ensureDBOwnership = true;
        }
        {
          name = "nocobase";
          ensureDBOwnership = true;
        }
      ];

      authentication = lib.mkOverride 10 ''
        # TYPE  DATABASE  USER  ADDRESS         METHOD  OPTIONS

        # Unix socket connections - require password for non-postgres users
        local   all       postgres                peer
        local   all       all                     scram-sha-256

        # Localhost connections - require password
        host    all       postgres   127.0.0.1/32    scram-sha-256
        host    all       all        127.0.0.1/32    scram-sha-256
        host    all       all        ::1/128         scram-sha-256

        # Podman network - require password (containers should use passwords)
        host    all       all        10.88.0.0/16    scram-sha-256

        # Local networks - SSL required with client certificate verification
        hostssl all       postgres   192.168.0.0/16  scram-sha-256
        hostssl all       all        192.168.0.0/16  scram-sha-256

        # Nebula network - SSL required
        hostssl all       all        10.6.0.0/24     scram-sha-256

        # Reject all other connections
        host    all       all        0.0.0.0/0       reject
        host    all       all        ::/0            reject
      '';
    };
  };

  services.nginx.virtualHosts."postgres.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/postgres.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/postgres.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5050/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Script-Name "";
        proxy_set_header Host $host;
        proxy_redirect off;
      '';
    };
  };

  # SOPS secrets for database passwords
  sops.secrets."ragflow-db-password" = {
    sopsFile = common.secretsPath;
    owner = "postgres";
    group = "postgres";
    mode = "0400";
  };

  sops.secrets."nocobase-db-password" = {
    sopsFile = common.secretsPath;
    owner = "postgres";
    group = "postgres";
    mode = "0400";
  };

  networking.firewall = {
    allowedTCPPorts =
      lib.mkIf config.services.postgresql.enable [ 5432 ];
    interfaces.podman0.allowedTCPPorts =
      lib.mkIf config.services.postgresql.enable [ 5432 ];
  };
}
