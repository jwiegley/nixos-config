{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ACME configuration for Let's Encrypt certificates
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "johnw@newartisans.com";
      server = "https://acme-v02.api.letsencrypt.org/directory";
    };
  };

  services = {
    nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;

      # Force-close old worker processes after 5 minutes during config reloads.
      # Prevents workers from lingering indefinitely due to long-lived WebSocket
      # connections (e.g., Home Assistant). Clients reconnect automatically.
      appendConfig = ''
        worker_shutdown_timeout 300s;
      '';
      # Increase map_hash settings to handle many virtual hosts and the large zimit URL map
      # Default values (16384/256) are insufficient for ~8000+ URL map entries
      # lib.mkForce needed to override conflicting definitions in zimit.nix
      mapHashMaxSize = lib.mkForce 65536;
      mapHashBucketSize = lib.mkForce 512;
      # logError = "/var/log/nginx/error.log debug";

      # commonHttpConfig is placed BEFORE server blocks (needed for log_format definitions)
      commonHttpConfig = ''
        # Custom log format for SearXNG query logging
        # Captures: timestamp, client IP, query parameter, full request
        log_format searxng_queries '$time_iso8601 $remote_addr "$arg_q" "$request"';
      '';

      appendHttpConfig = ''
        large_client_header_buffers 4 16k;
        proxy_headers_hash_max_size 1024;
        proxy_headers_hash_bucket_size 128;

        # WebSocket upgrade support
        map $http_upgrade $connection_upgrade {
          default upgrade;
          ""      close;
        }
      '';

      virtualHosts = {
        # HTTP to HTTPS redirect for all domains
        "redirect-http" = {
          serverName = "_";
          listen = [
            {
              addr = "0.0.0.0";
              port = 80;
            }
          ];
          locations."/".return = "301 https://$host$request_uri";
        };

        "vulcan.lan" = {
          serverAliases = [ "vulcan" ];
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan.lan.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan.lan.key";
          locations."/".return = "301 https://glance.vulcan.lan$request_uri";
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = lib.mkIf config.services.nginx.enable [
    80
    443
  ];
}
