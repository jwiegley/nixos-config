{ config, lib, pkgs, ... }:

{
  virtualisation.oci-containers.containers.litellm = {
    autoStart = true;
    image = "ghcr.io/berriai/litellm-database:main-stable";
    ports = [ "127.0.0.1:4000:4000/tcp" ];
    environment = {
      LITELLM_MASTER_KEY = "sk-1234";
      DATABASE_URL = "postgresql://litellm:sk-1234@host.containers.internal:5432/litellm";
      # REDIS_HOST = "localhost";
      # REDIS_PORT = "8085" ;
      # REDIS_PASSWORD = "sk-1234";
    };
    volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
    cmd = [
      "--config" "/app/config.yaml"
      # "--detailed_debug"
    ];
  };
}
