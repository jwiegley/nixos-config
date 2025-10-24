{ config, lib, pkgs, ... }:

{
  # LLaMA Swap Service
  # Converted from nix-darwin launchd.user.agents configuration
  #
  # Requirements:
  # 1. Config file must exist at: /home/johnw/Models/llama-swap.yaml
  # 2. SSL certificates for HTTPS proxy must be generated:
  #    sudo step ca certificate "llama-swap.vulcan.lan" \
  #      /var/lib/nginx-certs/llama-swap.vulcan.lan.crt \
  #      /var/lib/nginx-certs/llama-swap.vulcan.lan.key \
  #      --ca-url https://localhost:8443 \
  #      --root /var/lib/step-ca/certs/root_ca.crt
  # 3. Certificate ownership: sudo chown nginx:nginx /var/lib/nginx-certs/llama-swap.vulcan.lan.*

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
          --listen "0.0.0.0:8080" \
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

  # HTTPS proxy service using nginx on port 8443
  systemd.services.llama-swap-https-proxy = {
    description = "LLaMA Swap HTTPS Proxy (Nginx)";
    after = [ "network.target" "llama-swap.service" ];
    requires = [ "llama-swap.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.nginx ];

    serviceConfig = {
      Type = "simple";
      User = "johnw";
      Group = "users";
      Restart = "always";
      RestartSec = "5s";

      # RuntimeDirectory creates /run/llama-swap-proxy with proper permissions
      RuntimeDirectory = "llama-swap-proxy";
      RuntimeDirectoryMode = "0750";

      # Allow binding to privileged port 8443
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

      # Service command
      ExecStart = let
        nginxConfig = pkgs.writeText "llama-swap-nginx.conf" ''
          worker_processes 1;
          pid /run/llama-swap-proxy/nginx.pid;
          error_log /run/llama-swap-proxy/error.log warn;

          events {
            worker_connections 1024;
          }

          http {
            access_log /run/llama-swap-proxy/access.log;

            server {
              listen 8445 ssl;
              server_name llama-swap.vulcan.lan;

              # SSL Configuration
              ssl_certificate /var/lib/nginx-certs/llama-swap.vulcan.lan.crt;
              ssl_certificate_key /var/lib/nginx-certs/llama-swap.vulcan.lan.key;
              ssl_protocols TLSv1.2 TLSv1.3;
              ssl_prefer_server_ciphers on;
              ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;

              location / {
                proxy_pass http://localhost:8080;

                # Proxy headers
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;

                # Extended timeouts for LLM operations
                proxy_connect_timeout 600;
                proxy_send_timeout 600;
                proxy_read_timeout 600;
                send_timeout 600;

                # CORS headers
                add_header 'Access-Control-Allow-Origin' $http_origin always;
                add_header 'Access-Control-Allow-Credentials' 'true' always;
                add_header 'Access-Control-Allow-Headers' 'Authorization,Accept,Origin,DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Content-Range,Range' always;
                add_header 'Access-Control-Allow-Methods' 'GET,POST,OPTIONS,PUT,DELETE,PATCH' always;

                # Handle preflight requests
                if ($request_method = 'OPTIONS') {
                  add_header 'Access-Control-Max-Age' 1728000;
                  add_header 'Content-Type' 'text/plain; charset=utf-8';
                  add_header 'Content-Length' 0;
                  return 204;
                }
              }
            }
          }
        '';
      in "${pkgs.nginx}/bin/nginx -c ${nginxConfig} -g 'daemon off;'";

      # Security hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";

      # Allow reading SSL certificates
      ReadOnlyPaths = [ "/var/lib/nginx-certs" ];
    };
  };

  # Firewall configuration
  # Allow access to llama-swap on port 8080 and HTTPS proxy on port 8445
  networking.firewall.allowedTCPPorts = [ 8080 8445 ];
}
