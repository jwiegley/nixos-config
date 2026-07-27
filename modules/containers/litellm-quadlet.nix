# LiteLLM - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/litellm.nix)
# This file: Redis service, Nginx virtual host, SOPS secrets, firewall rules, and tmpfiles

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/litellm.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "litellm";
  #     image = "ghcr.io/berriai/litellm-database:main-stable";
  #     port = 4000;
  #     requiresPostgres = true;
  #     containerUser = "litellm";
  #     ...
  #   })
  # ];

  # Nginx virtual host
  services.nginx.virtualHosts."litellm.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/litellm.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/litellm.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:4000/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 20M;
        proxy_read_timeout 2h;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # SOPS secrets
  sops.secrets."litellm-secrets" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "litellm";
    path = "/run/secrets-litellm/litellm-secrets";
  };

  # tmpfiles rules
  systemd.tmpfiles.rules = [
    "d /etc/litellm 0755 litellm litellm -"
  ];

  # Redis server for litellm (rootless container access via localhost)
  services.redis.servers.litellm = {
    enable = true;
    port = 8085;
    # The rootless litellm container runs on slirp4netns with
    # allow_host_loopback, so it reaches this loopback bind at 10.0.2.2:8085
    # (see cache_params in modules/services/litellm-settings.nix). NOT via
    # host.containers.internal — that name is pinned to the podman0 address
    # 10.88.0.1 host-wide in quadlet.nix, which this bind does not answer on.
    bind = "127.0.0.1";
    settings = {
      protected-mode = "yes"; # Re-enable since only localhost
    };
  };

  # Redis binds to localhost only - no podman network dependency needed

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    4000 # litellm
    8085 # redis[litellm]
  ];
}
