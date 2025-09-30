{ config, lib, pkgs, ... }:

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
            Grafana = {
              icon = "grafana.png";
              href = "https://grafana.vulcan.lan";
              description = "Monitoring & Analytics";
              ping = "grafana.vulcan.lan";
              widget = {
                type = "grafana";
                url = "http://127.0.0.1:3000";
                username = "admin";
                password = "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}";
              };
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
            Jellyfin = {
              icon = "jellyfin.png";
              href = "https://jellyfin.vulcan.lan";
              description = "Media Server";
              ping = "jellyfin.vulcan.lan";
              widget = {
                type = "jellyfin";
                url = "http://127.0.0.1:8096";
                key = "{{HOMEPAGE_VAR_JELLYFIN_API_KEY}}";
                enableBlocks = true;
                enableNowPlaying = true;
              };
            };
          }
          {
            Wallabag = {
              icon = "wallabag.png";
              href = "https://wallabag.vulcan.lan";
              description = "Read it Later Service";
              server = "docker";
              container = "wallabag";
            };
          }
          {
            "Silly Tavern" = {
              icon = "sillytavern.png";
              href = "https://silly-tavern.vulcan.lan";
              description = "AI Chat Interface";
              server = "docker";
              container = "silly-tavern";
            };
          }
        ];
      }
      {
        Monitoring = [
          {
            Smokeping = {
              icon = "smokeping.png";
              href = "https://smokeping.vulcan.lan";
              description = "Network Latency Monitoring";
              ping = "smokeping.vulcan.lan";
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
        ];
      }
      {
        "AI Services" = [
          {
            LiteLLM = {
              icon = "openai.png";
              href = "https://litellm.vulcan.lan/ui";
              description = "LLM Proxy Service";
              server = "docker";
              container = "litellm";
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
          disk = "/";
          uptime = true;
        };
      }
      {
        search = {
          provider = "google";
          target = "_blank";
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
          latitude = 37.7749;
          longitude = -122.4194;
          timezone = "America/Los_Angeles";
          units = "imperial";
          cache = 5;
        };
      }
      {
        docker = {
          type = "docker";
          url = "unix:///var/run/docker.sock";
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

    # Docker configuration for container integration
    docker = {};
  };

  # Ensure the service can access the Podman socket
  systemd.services.homepage-dashboard = {
    serviceConfig = {
      SupplementaryGroups = [ "podman" ];
      BindReadOnlyPaths = [ "/run/podman/podman.sock:/var/run/docker.sock" ];
    };
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
}
