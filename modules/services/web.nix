{ config, lib, pkgs, ... }:

{
  # ACME configuration for Let's Encrypt certificates
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "johnw@newartisans.com";
      # Use production Let's Encrypt server
      server = "https://acme-v02.api.letsencrypt.org/directory";
      # For testing, use staging server:
      # server = "https://acme-staging-v02.api.letsencrypt.org/directory";
    };
  };

  services = {
    jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      user = "johnw";
    };

    nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      # logError = "/var/log/nginx/error.log debug";

      appendHttpConfig = ''
        large_client_header_buffers 4 16k;
        proxy_headers_hash_max_size 1024;
        proxy_headers_hash_bucket_size 128;
      '';

      virtualHosts = {
        # HTTP to HTTPS redirect for all domains
        "redirect-http" = {
          serverName = "_";
          listen = [
            { addr = "0.0.0.0"; port = 80; }
          ];
          locations."/".return = "301 https://$host$request_uri";
        };

        smokeping = {
          listen = [
            { addr = "127.0.0.1"; port = 8081; }
          ];
        };

        "jellyfin.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/jellyfin.vulcan.lan.crt";
          sslCertificateKey = "/var/lib/nginx-certs/jellyfin.vulcan.lan.key";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8096/";
            proxyWebsockets = true;
          };
        };

        "smokeping.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/smokeping.vulcan.lan.crt";
          sslCertificateKey = "/var/lib/nginx-certs/smokeping.vulcan.lan.key";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8081/";
            proxyWebsockets = true;
          };
        };

        "postgres.vulcan.lan" = {
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

        "dns.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/dns.vulcan.lan.crt";
          sslCertificateKey = "/var/lib/nginx-certs/dns.vulcan.lan.key";
          locations."/" = {
            proxyPass = "http://127.0.0.1:5380/";
            proxyWebsockets = true;
          };
        };

        "uptime.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/uptime.vulcan.lan.crt";
          sslCertificateKey = "/var/lib/nginx-certs/uptime.vulcan.lan.key";
          locations."/" = {
            proxyPass = "http://127.0.0.1:3001/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header Host $host;
            '';
          };
        };

        "vulcan.lan" = {
          serverAliases = [ "vulcan" ];
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan.lan.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan.lan.key";
          locations."/".return = "301 https://organizr.vulcan.lan$request_uri";
        };

        # Internet-facing secure container with ACME
        "home.newartisans.com" = {
          forceSSL = true;
          enableACME = true;  # Let's Encrypt ACME certificates

          # Security headers for internet-facing service
          extraConfig = ''
            # Strict Transport Security
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

            # Additional security headers
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-XSS-Protection "1; mode=block" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;

            # CSP Header
            add_header Content-Security-Policy "default-src 'self' https:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';" always;
          '';

          locations."/" = {
            proxyPass = "http://10.233.1.2:8080/";
            proxyWebsockets = true;
            extraConfig = ''
              # Pass real IP to container
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Timeout settings for long-running connections
              proxy_connect_timeout 60s;
              proxy_send_timeout 60s;
              proxy_read_timeout 60s;
            '';
          };

          # Health check endpoint (proxied to container)
          locations."/health" = {
            proxyPass = "http://10.233.1.2:8080/health";
            extraConfig = ''
              access_log off;
            '';
          };
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    443    # nginx (HTTPS)
  ];
}
