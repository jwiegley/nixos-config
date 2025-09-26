{ config, lib, pkgs, ... }:

{
  # Enable Podman with dockerCompat and ensure network is configured
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings = {
      dns_enabled = false;  # Disable DNS to avoid conflict with Technitium DNS Server
      # Ensure the default podman network is configured
      subnets = [
        {
          subnet = "10.88.0.0/16";
          gateway = "10.88.0.1";
        }
      ];
    };
    autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
  };

  # Create a systemd service to ensure podman network exists
  systemd.services.ensure-podman-network = {
    description = "Ensure Podman network exists";
    after = [ "network.target" ];
    before = [ "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.podman}/bin/podman network exists podman || ${pkgs.podman}/bin/podman network create --disable-dns --subnet 10.88.0.0/16 --gateway 10.88.0.1 podman'";
    };
  };

  # Configure Quadlet containers with proper dependencies
  virtualisation.quadlet = {
    # LiteLLM container configuration - simplified to avoid network issues
    containers.litellm = {
      containerConfig = {
        image = "ghcr.io/berriai/litellm-database:main-stable";
        # Bind to both localhost and podman gateway for container access
        publishPorts = [
          "127.0.0.1:4000:4000/tcp"
          "10.88.0.1:4000:4000/tcp"
        ];
        environmentFiles = [ config.sops.secrets."litellm-secrets".path ];
        volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
        exec = "--config /app/config.yaml";
        # Use the default podman network
        networks = [ "podman" ];
      };
      unitConfig = {
        After = [ "sops-nix.service" "postgresql.service" "ensure-podman-network.service" "podman.service" ];
        Wants = [ "sops-nix.service" "ensure-podman-network.service" ];
      };
      serviceConfig = {
        # Add a startup delay to ensure network is ready
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      };
    };

    # Organizr container configuration
    containers.organizr = {
      containerConfig = {
        image = "ghcr.io/organizr/organizr:latest";
        publishPorts = [ "127.0.0.1:8080:80/tcp" ];
        environments = {
          PUID = "1000";
          PGID = "100";
          TZ = config.time.timeZone;
        };
        volumes = [ "/var/lib/organizr:/config:Z" ];
        networks = [ "podman" ];
      };
      unitConfig = {
        After = [ "ensure-podman-network.service" "podman.service" ];
        Wants = [ "ensure-podman-network.service" ];
      };
    };

    # SillyTavern container configuration
    containers.silly-tavern = {
      containerConfig = {
        image = "ghcr.io/sillytavern/sillytavern:latest";
        publishPorts = [ "127.0.0.1:8083:8000/tcp" ];
        environments = {
          USER_PASSWORD = "";
          AUTO_UPDATE = "false";
        };
        volumes = [
          "/var/lib/silly-tavern/config:/home/node/app/config:Z"
          "/var/lib/silly-tavern/data:/home/node/app/data:Z"
        ];
        networks = [ "podman" ];
      };
      unitConfig = {
        After = [ "ensure-podman-network.service" "podman.service" ];
        Wants = [ "ensure-podman-network.service" ];
      };
    };

    # Wallabag container configuration
    containers.wallabag = {
      containerConfig = {
        image = "docker.io/wallabag/wallabag:latest";
        publishPorts = [ "127.0.0.1:9091:80/tcp" ];
        environmentFiles = [ config.sops.secrets."wallabag-secrets".path ];
        environments = {
          SYMFONY__ENV__DATABASE_DRIVER = "pdo_pgsql";
          SYMFONY__ENV__DATABASE_HOST = "10.88.0.1";  # Use Podman bridge IP directly
          SYMFONY__ENV__DATABASE_PORT = "5432";
          SYMFONY__ENV__DATABASE_NAME = "wallabag";
          SYMFONY__ENV__DATABASE_USER = "wallabag";
          SYMFONY__ENV__DATABASE_CHARSET = "utf8";
          SYMFONY__ENV__DOMAIN_NAME = "https://wallabag.vulcan.lan";
          SYMFONY__ENV__SERVER_NAME = "Wallabag";
          SYMFONY__ENV__FOSUSER_CONFIRMATION = "false";
          SYMFONY__ENV__TWOFACTOR_AUTH = "false";
          POPULATE_DATABASE = "False";  # Database already exists, skip setup
        };
        volumes = [ ];  # Wallabag manages its own data internally
        networks = [ "podman" ];
      };
      unitConfig = {
        After = [ "sops-nix.service" "postgresql.service" "ensure-podman-network.service" "podman.service" ];
        Wants = [ "sops-nix.service" "ensure-podman-network.service" ];
      };
    };
  };

  # Configure firewall to allow container traffic on podman0 interface
  networking.firewall = {
    interfaces.podman0 = {
      allowedTCPPorts = [ 4000 5432 8085 ];
      allowedUDPPorts = [ 53 ];
    };
  };

  # Configure Nginx virtual hosts (these remain the same)
  services.nginx.virtualHosts = {
    "litellm.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/litellm.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/litellm.vulcan.lan.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:4000/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 20M;
          proxy_read_timeout 2h;
        '';
      };
    };

    "organizr.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/organizr.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/organizr.vulcan.lan.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
        '';
      };
    };

    "silly-tavern.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/silly-tavern.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/silly-tavern.vulcan.lan.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8083/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 100M;
        '';
      };
    };

    "wallabag.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/wallabag.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/wallabag.vulcan.lan.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:9091/";
        extraConfig = ''
          proxy_read_timeout 1h;
          proxy_buffering off;
        '';
      };
    };
  };

  # Redis server for litellm (bind to localhost for now)
  services.redis.servers.litellm = {
    enable = true;
    port = 8085;
    bind = "127.0.0.1";
    settings = {
      protected-mode = "no";
    };
  };

  # SOPS secrets configurations
  sops.secrets = {
    "litellm-secrets" = {
      sopsFile = ../../secrets.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "litellm.service" ];
    };
    "wallabag-secrets" = {
      sopsFile = ../../secrets.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "wallabag.service" ];
    };
  };

  # System packages for state directories
  systemd.tmpfiles.rules = [
    "d /var/lib/organizr 0755 1000 100 -"
    "d /var/lib/silly-tavern/config 0755 1000 100 -"
    "d /var/lib/silly-tavern/data 0755 1000 100 -"
    "d /var/lib/wallabag 0755 root root -"
    "d /etc/litellm 0755 root root -"
  ];

  # Add monitoring tools
  environment.systemPackages = with pkgs; [
    lazydocker
    podman-tui
  ];
}