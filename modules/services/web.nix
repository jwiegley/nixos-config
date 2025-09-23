{ config, lib, pkgs, ... }:

let
  # Helper function for common proxy redirect patterns
  mkRedirect = baseUrl: path: {
    locations."/".return = "301 ${baseUrl}${path}/";
  };

  # Helper for proxy pass with standard settings
  mkProxyLocation = port: path: {
    locations."${path}/" = {
      proxyPass = "http://127.0.0.1:${toString port}${path}/";
      proxyWebsockets = true;
    };
    locations."${path}" = {
      return = "301 ${path}/";
    };
  };
in
{
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
          sslCertificate = "/var/lib/nginx-certs/vulcan-fullchain.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan-1year.key";
          locations."/".proxyPass = "http://127.0.0.1:8096/";
        };

        "litellm.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan-fullchain.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan-1year.key";
          locations."/".proxyPass = "http://127.0.0.1:4000/";
        };

        "organizr.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan-fullchain.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan-1year.key";
          locations."/".proxyPass = "http://127.0.0.1:8080/";
        };

        "smokeping.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan-fullchain.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan-1year.key";
          locations."/".proxyPass = "http://127.0.0.1:8081/";
        };

        "wallabag.vulcan.lan" = {
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan-fullchain.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan-1year.key";
          locations."/".proxyPass = "http://127.0.0.1:9090/";
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

        "vulcan.lan" = {
          serverAliases = [ "vulcan" ];
          forceSSL = true;
          sslCertificate = "/var/lib/nginx-certs/vulcan-fullchain.crt";
          sslCertificateKey = "/var/lib/nginx-certs/vulcan-1year.key";
          locations."/".return = "301 https://organizr.vulcan.lan$request_uri";
        };
      };
    };
  };
}
