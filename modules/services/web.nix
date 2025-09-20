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
      # logError = "/var/log/nginx/error.log debug";

      appendHttpConfig = ''
        large_client_header_buffers 4 16k;
        proxy_headers_hash_max_size 1024;
        proxy_headers_hash_bucket_size 128;
      '';

      virtualHosts = {
        smokeping = {
          listen = [
            { addr = "127.0.0.1"; port = 8081; }
          ];
        };

        "jellyfin.vulcan.lan".locations."/".proxyPass = "http://127.0.0.1:8096/";
        "litellm.vulcan.lan".locations."/".proxyPass = "http://127.0.0.1:4000/";
        "organizr.vulcan.lan".locations."/".proxyPass = "http://127.0.0.1:8080/";
        "smokeping.vulcan.lan".locations."/".proxyPass = "http://127.0.0.1:8081/";
        "wallabag.vulcan.lan".locations."/".proxyPass = "http://127.0.0.1:9090/";

        "vulcan.lan" = {
          serverAliases = [ "vulcan" ];

          locations."/".return = "301 http://organizr.vulcan.lan";
        };
      };
    };
  };
}
