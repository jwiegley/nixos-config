{
  config,
  lib,
  pkgs,
  ...
}:

let
  # SearXNG internal port (proxied through nginx)
  searxngPort = 8890;

  # Redis port for SearXNG rate limiting
  redisPort = 6386;
in
{
  # SearXNG metasearch engine service
  services.searx = {
    enable = true;

    # Use uwsgi for production deployment (recommended for public/high-traffic)
    configureUwsgi = true;

    # Configure uwsgi
    uwsgiConfig = {
      http = "127.0.0.1:${toString searxngPort}";
      disable-logging = true;
      # Performance tuning for reasonable traffic
      processes = 4;
      threads = 4;
    };

    # Environment file for secrets (contains SEARXNG_SECRET)
    environmentFile = config.sops.secrets."searxng/env".path;

    # Enable local Redis for rate limiting and bot protection
    redisCreateLocally = false; # We manage Redis ourselves

    # SearXNG settings
    settings = {
      # General settings
      general = {
        debug = false;
        instance_name = "SearXNG";
        privacypolicy_url = false;
        donation_url = false;
        contact_url = false;
        enable_metrics = true;
      };

      # Server configuration
      server = {
        port = searxngPort;
        bind_address = "127.0.0.1";
        base_url = "https://searxng.vulcan.lan/";
        # Secret key loaded from environment file via $SEARXNG_SECRET
        secret_key = "@SEARXNG_SECRET@";
        # limiter requires Redis/Valkey (disabled for now due to configuration issues)
        limiter = false;
        # Image proxy for privacy
        image_proxy = true;
        # HTTP protocol version
        http_protocol_version = "1.1";
        # Method used to obfuscate searx request when using image proxy
        method = "GET";
      };

      # Valkey/Redis configuration for rate limiting
      valkey = {
        url = "redis://127.0.0.1:${toString redisPort}/0";
      };

      # UI settings
      ui = {
        static_use_hash = true;
        default_theme = "simple";
        center_alignment = true;
        infinite_scroll = true;
        default_locale = "en";
        query_in_title = true;
        results_on_new_tab = false;
        search_on_category_select = true;
      };

      # Search settings
      search = {
        safe_search = 0; # 0 = off, 1 = moderate, 2 = strict
        autocomplete = "duckduckgo";
        autocomplete_min = 2;
        default_lang = "en";
        languages = [
          "all"
          "en"
          "de"
          "fr"
          "es"
        ];
        ban_time_on_fail = 5;
        max_ban_time_on_fail = 120;
      };

      # Outgoing request settings
      outgoing = {
        request_timeout = 6.0;
        max_request_timeout = 15.0;
        useragent_suffix = "";
        pool_connections = 100;
        pool_maxsize = 20;
        enable_http2 = true;
      };

      # Engine settings - enable popular engines
      engines = [
        # General search engines
        {
          name = "duckduckgo";
          engine = "duckduckgo";
          shortcut = "ddg";
          disabled = false;
        }
        {
          name = "google";
          engine = "google";
          shortcut = "g";
          disabled = false;
        }
        {
          name = "bing";
          engine = "bing";
          shortcut = "b";
          disabled = false;
        }
        {
          name = "brave";
          engine = "brave";
          shortcut = "br";
          disabled = false;
        }
        # Wikipedia
        {
          name = "wikipedia";
          engine = "wikipedia";
          shortcut = "w";
          disabled = false;
        }
        # Tech search
        {
          name = "github";
          engine = "github";
          shortcut = "gh";
          disabled = false;
        }
        {
          name = "stackoverflow";
          engine = "stackexchange";
          shortcut = "st";
          api_site = "stackoverflow";
          disabled = false;
        }
        # Images
        {
          name = "google images";
          engine = "google_images";
          shortcut = "gi";
          disabled = false;
        }
        {
          name = "bing images";
          engine = "bing_images";
          shortcut = "bi";
          disabled = false;
        }
        # News
        {
          name = "google news";
          engine = "google_news";
          shortcut = "gn";
          disabled = false;
        }
        # Videos
        {
          name = "youtube";
          engine = "youtube_noapi";
          shortcut = "yt";
          disabled = false;
        }
        # Maps
        {
          name = "openstreetmap";
          engine = "openstreetmap";
          shortcut = "osm";
          disabled = false;
        }
        # Science and academic
        {
          name = "arxiv";
          engine = "arxiv";
          shortcut = "arx";
          disabled = false;
        }
        # IT documentation
        {
          name = "arch linux wiki";
          engine = "archlinux";
          shortcut = "aw";
          disabled = false;
        }
        {
          name = "nixos wiki";
          engine = "mediawiki";
          shortcut = "nw";
          base_url = "https://wiki.nixos.org/";
          search_type = "text";
          disabled = false;
        }
      ];
    };

    # Rate limiter settings
    limiterSettings = {
      real_ip = {
        x_for = 1;
        ipv4_prefix = 32;
        ipv6_prefix = 48;
      };
      botdetection = {
        ip_limit = {
          # Limit per IP per time period
          link_token = false;
          filter_link_token = true;
        };
        ip_lists = {
          pass_ip = [
            # Local network IPs can bypass limits
            "192.168.0.0/16"
            "10.0.0.0/8"
            "127.0.0.0/8"
          ];
          block_ip = [ ];
          pass_searxng_org = true;
        };
      };
    };
  };

  # Configure dedicated Redis instance for SearXNG
  services.redis.servers.searxng = {
    enable = true;
    port = redisPort;
    bind = "127.0.0.1";
    settings = {
      protected-mode = "yes";
      maxmemory = "64mb";
      maxmemory-policy = "allkeys-lru";
      # Disable persistence for rate limiting data (ephemeral)
      appendonly = "no";
    };
    # Disable RDB snapshots
    save = [ ];
  };

  # Allow Redis access from podman network (if needed in future)
  networking.firewall.interfaces.podman0.allowedTCPPorts = [ redisPort ];

  # SOPS secrets for SearXNG
  sops.secrets."searxng/env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "searx";
    group = "searx";
    restartUnits = [ "uwsgi.service" ];
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."searxng.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/searxng.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/searxng.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString searxngPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        # Timeout settings for search queries
        proxy_read_timeout 60;
        proxy_connect_timeout 60;
        proxy_send_timeout 60;

        # Pass real IP for rate limiting
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;

        # Buffering settings
        proxy_buffering off;
      '';
    };

    # Static files served directly
    locations."/static/" = {
      alias = "${pkgs.searxng}/share/static/";
      extraConfig = ''
        expires 1d;
        add_header Cache-Control "public, immutable";
      '';
    };
  };

  # Firewall - allow localhost access to SearXNG port
  networking.firewall.interfaces."lo".allowedTCPPorts = [ searxngPort ];
}
