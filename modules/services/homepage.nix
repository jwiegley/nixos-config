{ config, lib, pkgs, ... }:
with lib;

{
  # Native Homepage Dashboard service configuration
  services.homepage-dashboard = {
    enable = true;

    # Use the same port as the container was using
    listenPort = 3005;

    # Allow access from nginx reverse proxy
    allowedHosts = "homepage.vulcan.lan,localhost,127.0.0.1";

    # Environment file for secrets
    environmentFile = "/var/lib/homepage-secrets.env";

    # Main dashboard settings
    settings = {
      title = "Vulcan Dashboard";

      background = {
        image = "https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=2560&q=80";
        blur = "sm";
        saturate = 100;
        brightness = 90;
        opacity = 100;
      };

      theme = "dark";
      color = "slate";
      iconStyle = "theme";
      headerStyle = "clean";
      statusStyle = "dot";
      target = "_blank";
      language = "en";

      layout = {
        Infrastructure = {
          style = "row";
          columns = 4;
        };
        "Media & Entertainment" = {
          style = "row";
          columns = 3;
        };
        Monitoring = {
          style = "row";
          columns = 4;
        };
        "AI Services" = {
          style = "row";
          columns = 2;
        };
        Containers = {
          style = "row";
          columns = 1;
        };
      };

      quicklaunch = {
        searchDescriptions = true;
        hideInternetSearch = false;
        hideVisitURL = false;
      };

      disableCollapse = false;
      hideVersion = false;

      providers = {
        openweathermap = "{{HOMEPAGE_VAR_WEATHER_API_KEY}}";
      };
    };

    # Services configuration
    services = [
      {
        Infrastructure = [
          {
            OPNsense = {
              icon = "opnsense.png";
              href = "https://192.168.1.1";
              description = "OPNsense Firewall";
              ping = "192.168.1.1";
            };
          }
          {
            "DNS Management" = {
              icon = "technitium-dns.png";
              href = "https://dns.vulcan.lan";
              description = "Technitium DNS Server";
              ping = "dns.vulcan.lan";
            };
          }
          {
            "PostgreSQL Admin" = {
              icon = "postgres.png";
              href = "https://postgres.vulcan.lan";
              description = "pgAdmin Interface";
              ping = "postgres.vulcan.lan";
            };
          }
        ];
      }
      {
        "Media & Entertainment" = [
          {
            Wallabag = {
              icon = "wallabag.png";
              href = "https://wallabag.vulcan.lan";
              description = "Read it Later Service";
              ping = "wallabag.vulcan.lan";
            };
          }
          {
            Jellyfin = {
              icon = "jellyfin.png";
              href = "https://jellyfin.vulcan.lan";
              description = "Media Server";
              ping = "jellyfin.vulcan.lan";
            };
          }
          {
            "Silly Tavern" = {
              icon = "sillytavern.png";
              href = "https://silly-tavern.vulcan.lan";
              description = "AI Chat Interface";
              ping = "silly-tavern.vulcan.lan";
            };
          }
        ];
      }
      {
        Monitoring = [
          {
            Grafana = {
              icon = "grafana.png";
              href = "https://grafana.vulcan.lan";
              description = "Monitoring & Analytics";
              ping = "grafana.vulcan.lan";
            };
          }
          {
            Prometheus = {
              icon = "prometheus.png";
              href = "https://prometheus.vulcan.lan";
              description = "Metrics & Time Series Database";
              ping = "prometheus.vulcan.lan";
            };
          }
          {
            Alertmanager = {
              icon = "alertmanager.png";
              href = "https://alertmanager.vulcan.lan";
              description = "Alert Management";
              ping = "alertmanager.vulcan.lan";
            };
          }
          {
            Smokeping = {
              icon = "smokeping.png";
              href = "https://smokeping.vulcan.lan";
              description = "Network Latency Monitoring";
              ping = "smokeping.vulcan.lan";
            };
          }
        ];
      }
      {
        "AI Services" = [
          {
            LiteLLM = {
              icon = "openai.png";
              href = "https://litellm.vulcan.lan/ui";
              description = "LLM Proxy Service";
              ping = "litellm.vulcan.lan";
            };
          }
        ];
      }
    ];

    # Widgets configuration
    widgets = [
      {
        resources = {
          cpu = true;
          memory = true;
          # disk = "/";
          uptime = true;
        };
      }
      {
        datetime = {
          locale = "en";
          format = {
            dateStyle = "long";
            timeStyle = "short";
          };
        };
      }
      {
        openmeteo = {
          latitude = 38.569626;
          longitude = -121.388395;
          timezone = "America/Los_Angeles";
          units = "imperial";
          cache = 5;
        };
      }
    ];

    # Bookmarks configuration
    bookmarks = [
      {
        Documentation = [
          {
            "NixOS Manual" = [
              {
                icon = "nix-snowflake.png";
                href = "https://nixos.org/manual/nixos/stable/";
                description = "Official NixOS documentation";
              }
            ];
          }
          {
            "NixOS Options" = [
              {
                icon = "nix-snowflake.png";
                href = "https://search.nixos.org/options";
                description = "Search NixOS configuration options";
              }
            ];
          }
          {
            "Homepage Docs" = [
              {
                icon = "homepage.png";
                href = "https://gethomepage.dev/";
                description = "Homepage dashboard documentation";
              }
            ];
          }
        ];
      }
      {
        Development = [
          {
            GitHub = [
              {
                icon = "github.png";
                href = "https://github.com";
                description = "Code repositories";
              }
            ];
          }
          {
            "Docker Hub" = [
              {
                icon = "docker.png";
                href = "https://hub.docker.com";
                description = "Container images";
              }
            ];
          }
        ];
      }
      {
        Community = [
          {
            "NixOS Discourse" = [
              {
                icon = "discourse.png";
                href = "https://discourse.nixos.org";
                description = "NixOS community forum";
              }
            ];
          }
          {
            "r/selfhosted" = [
              {
                icon = "reddit.png";
                href = "https://reddit.com/r/selfhosted";
                description = "Self-hosting community";
              }
            ];
          }
        ];
      }
    ];
  };

  # Keep the existing nginx configuration
  services.nginx.virtualHosts."homepage.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/homepage.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/homepage.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:3005/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts =
    lib.mkIf config.services.homepage-dashboard.enable [ 3005 ];
}
