{ config, lib, pkgs, ... }:

{
  sops.secrets."litellm-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "podman-litellm.service" ];
  };

  services.redis.servers.litellm = {
    enable = true;
    port = 8085;
    bind = "10.88.0.1";
    settings = {
      aclfile = "/etc/redis/users.acl";
      protected-mode = "no";
    };
  };

  virtualisation.oci-containers.containers.litellm = {
    autoStart = true;
    image = "ghcr.io/berriai/litellm-database:main-stable";
    ports = [
      "127.0.0.1:4000:4000/tcp"
      "10.88.0.1:4000:4000/tcp"
    ];

    # Secret environment variables from SOPS
    environmentFiles = [
      config.sops.secrets."litellm-secrets".path
    ];

    volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
    cmd = [
      "--config" "/app/config.yaml"
      # "--detailed_debug"
    ];
  };

  # Ensure proper systemd dependencies
  systemd.services."podman-litellm" = {
    after = [ "sops-nix.service" "postgresql.service" ];
    wants = [ "sops-nix.service" ];
  };

  services.nginx.virtualHosts."litellm.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/litellm.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/litellm.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:4000/";
      proxyWebsockets = true;
      extraConfig = ''
        # (Optional) Disable proxy buffering for better streaming
        # response from models
        proxy_buffering off;

        # (Optional) Increase max request size for large attachments
        # and long audio messages
        client_max_body_size 20M;
        proxy_read_timeout 2h;
      '';
    };
  };
}
