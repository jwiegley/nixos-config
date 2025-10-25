{ config, lib, pkgs, ... }:

{
  # Main llama-swap service on port 8080
  systemd.services.llama-swap = {
    description = "LLaMA Swap Service";
    documentation = [ "https://github.com/mostlygeek/llama-swap" ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "johnw";
      Group = "users";
      Restart = "always";
      RestartSec = "5s";

      # Service command
      ExecStart = ''
        ${pkgs.llama-swap}/bin/llama-swap \
          --listen "127.0.0.1:8080" \
          --config /home/johnw/Models/llama-swap.yaml
      '';

      # Security hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "/home/johnw/Models" ];
    };
  };

  services.nginx.virtualHosts."llama-swap.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/llama-swap.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/llama-swap.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://localhost:8080";
      recommendedProxySettings = true;
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts = [ 8080 ];
}
