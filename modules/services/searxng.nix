{
  config,
  lib,
  pkgs,
  ...
}:

let
  # SearXNG internal port (proxied through nginx)
  searxngPort = 8890;

  # Redis port for SearXNG rate limiting. NOTE: the limiter is currently
  # disabled (`limiter = false` below), so this instance is provisioned but
  # unused — verified empty (dbsize 0) on 2026-07-27.
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
        # Secret key loaded from the SOPS environment file (services.searx.
        # environmentFile above).
        #
        # MUST be $VAR, not @VAR@. searx-init renders settings.yml with
        # `envsubst`, which only understands shell-style $VAR / ${VAR}. The
        # previous value was "@SEARXNG_SECRET@", which envsubst leaves ALONE --
        # verified 2026-08-03 that the rendered /run/searx/settings.yml contained
        # that placeholder LITERALLY, so this instance had been running with a
        # publicly-guessable secret_key and the SOPS secret was inert. secret_key
        # signs preference URLs/cookies, so a predictable value lets those be
        # forged; low impact on a LAN-only instance, but the fix is free.
        #
        # Changing it invalidates any saved preference links, which is expected.
        secret_key = "$SEARXNG_SECRET";
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
        # Enable JSON output format so Vane can use SearXNG as its search backend
        formats = [
          "html"
          "json"
        ];
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
        # Explicitly disable wikidata - its init fails if network is unavailable at startup
        # and causes KeyError when searching (processor not registered but engine enabled)
        {
          name = "wikidata";
          engine = "wikidata";
          shortcut = "wd";
          disabled = true;
        }
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
          # Disabled: Brave's anti-bot measures cause brotli decompression failures
          disabled = true;
        }
        # Added 2026-08-03 for REDUNDANCY, after this instance was reduced to a
        # single working general engine.
        #
        # Measured that day: google returns HTTP 403 (suspended 180s), and BOTH
        # startpage and duckduckgo now serve CAPTCHAs -- 65 CAPTCHA events in 30
        # minutes. bing was the only general engine still answering, so any query
        # bing happened to miss returned ZERO results, and Vane (Perplexica)
        # replied "I could not find any relevant information" with 0 sources.
        # That is the user-visible symptom of a search backend with no depth left.
        #
        # Mojeek is the right addition because it operates its OWN crawler and
        # index rather than proxying Google/Bing, so it does not share their
        # bot-detection posture toward self-hosted instances. Brave above is a
        # separate matter -- disabled for a concrete technical failure (brotli),
        # not for blocking -- so it is deliberately left alone.
        #
        # TRIED AND IT DOES NOT WORK -- left here disabled so nobody spends the
        # same afternoon on it again. Enabled 2026-08-03, and mojeek returned
        # HTTP 403 (suspended_time=180) on the very first query, exactly like
        # google.
        #
        # What the 403 is NOT:
        #   - not this host's IP. Plain curl from vulcan with a browser
        #     User-Agent gets 200 from mojeek, duckduckgo AND bing.
        #   - not a stale User-Agent. This build's useragents.json templates
        #     Firefox/147.0 (current), and a manual curl with Firefox/147 gets
        #     200 from mojeek. Firefox/135 also gets 200.
        #   - not the engine being unsupported: it is a first-class searxng
        #     engine and it initialised fine.
        # curl's DEFAULT UA gets 403 from mojeek and a 202 challenge from
        # duckduckgo, so the engines are fingerprinting the CLIENT, and since UA
        # and IP are both exonerated the remaining candidate is the TLS/HTTP2
        # fingerprint of searxng's httpx stack. Nothing in settings.yml changes
        # that.
        #
        # Net effect of enabling it was one extra guaranteed-failing request per
        # search, so it is off. bing remains the only general engine that answers
        # this instance; when a query misses on bing, Vane returns 0 sources and
        # says it could not find anything. Fixing that needs an engine with an
        # API key (brave/google CSE) or an egress that is not fingerprinted --
        # both operator decisions, not config tweaks.
        {
          name = "mojeek";
          engine = "mojeek";
          shortcut = "mjk";
          disabled = true;
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

        # Note: X-Forwarded-For and X-Real-IP are already set by recommendedProxySettings
        # Don't duplicate them here as it causes invalid header values like "192.168.1.2, 192.168.1.2"

        # Buffering settings
        proxy_buffering off;
      '';
    };

    # Log search queries to a dedicated file for personal search history
    locations."/search" = {
      proxyPass = "http://127.0.0.1:${toString searxngPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        # Log queries using custom format (timestamp, IP, query, full request)
        access_log /var/log/nginx/searxng-queries.log searxng_queries;

        # Same proxy settings as main location
        proxy_read_timeout 60;
        proxy_connect_timeout 60;
        proxy_send_timeout 60;
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
