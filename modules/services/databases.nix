{ config, lib, pkgs, ... }:

{
  services = {
    postgresql = {
      enable = true;
      enableTCPIP = true;

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
      ];
      ensureUsers = [
        { name = "postgres"; }
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
}
