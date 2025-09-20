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
      settings.port = 5432;

      ensureDatabases = [ "db" "litellm" "wallabag" ];
      ensureUsers = [
        { name = "postgres"; }
      ];
      # dataDir = "/var/lib/postgresql/16";

      authentication = lib.mkOverride 10 ''
        local all all trust
        host all all 127.0.0.1/32 trust
        host all all 10.88.0.0/16 trust
        host all all 192.168.1.0/24 md5
        host all all 10.6.0.0/16 md5
        host all all ::1/128 md5
      '';

      initialScript = pkgs.writeText "init.sql" ''
        CREATE ROLE johnw WITH LOGIN PASSWORD 'password' CREATEDB;
        CREATE DATABASE db;
        GRANT ALL PRIVILEGES ON DATABASE db TO johnw;
        \c db
        GRANT ALL ON SCHEMA public TO johnw;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO johnw;
        ALTER DATABASE db OWNER TO johnw;

        CREATE ROLE litellm WITH LOGIN PASSWORD 'sk-1234' CREATEDB;
        CREATE DATABASE litellm;
        GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
        \c litellm
        GRANT ALL ON SCHEMA public TO litellm;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO litellm;
        ALTER DATABASE litellm OWNER TO litellm;

        CREATE ROLE wallabag WITH LOGIN PASSWORD 'bag-1234' CREATEDB;
        CREATE DATABASE wallabag;
        GRANT ALL PRIVILEGES ON DATABASE wallabag TO wallabag;
        \c wallabag
        GRANT ALL ON SCHEMA public TO wallabag;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO wallabag;
        ALTER DATABASE wallabag OWNER TO wallabag;
      '';
    };
  };
}
