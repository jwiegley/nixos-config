{ config, lib, pkgs, ... }:
let
  portal = pkgs.stdenv.mkDerivation {
    name = "nginx-portal";
    src = ./nginx-portal;
    installPhase = ''
      mkdir -p $out
      cp -r $src/* $out/
    '';
  };

  attrNameList = attrs:
    builtins.concatStringsSep " " (builtins.attrNames attrs);
in
rec {
  system.stateVersion = "25.05";

  imports =
    [ ./hardware-configuration.nix
    ];

  nixpkgs.config.packageOverrides = pkgs: {
    python3Packages = pkgs.python3Packages.override {
      overrides = self: super: {
        litellm = super.litellm.overridePythonAttrs (old: {
          dependencies = (old.dependencies or [ ])
            ++ super.litellm.optional-dependencies.proxy;
          propagatedBuildInputs = (old.propagatedBuildInputs or [])
            ++ (with self; [
              asyncpg
              httpx
              redis
              sqlalchemy
              prisma
            ]);
        });
      };
    };
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    kernelParams = [
      "pcie_ports=native"  # instead of "pcie_ports=compat"
    ];

    supportedFilesystems = ["zfs"];
    # zfs.extraPools = [ "tank" ];

    initrd.services.udev.rules = ''
      ACTION=="add|change", SUBSYSTEM=="thunderbolt", \
      ATTR{unique_id}=="d4030000-0080-7708-2354-04990534401e" \
      ATTR{authorized}="1"
    '';

    postBootCommands = ''
      /run/current-system/sw/bin/sleep 60
      /run/current-system/sw/bin/echo 1 > /sys/bus/pci/rescan
      /run/current-system/sw/bin/boltctl enroll --policy auto \
        $(boltctl | grep -A 2 "ThunderBay" \
          | grep -o "[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}" \
          | head -n 1) || true
      /run/current-system/sw/bin/zpool import -a || true
      systemctl restart smokeping.service || true
    '';

  };

  time.timeZone = "America/Los_Angeles";

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "dvorak";
  };

  security = {
    polkit.enable = true;
    sudo.wheelNeedsPassword = false;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  networking = {
    hostId = "671bf6f5";
    hostName = "vulcan";
    domain = "local";

    interfaces.enp4s0 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "192.168.50.182";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.50.1";
    nameservers = [ "192.168.50.1" ];

    firewall = {

      allowedTCPPorts = [ 53 80 443 9997 3000 ]
        ++ [ 8384 22000 ]       # syncthing
        ++ [ 8083 ]             # silly-tavern
        ++ [ 5432 ]             # postgres
        # ++ [ 8123 ]             # home-assistant
        ;
      allowedUDPPorts = [ 53 67 ]
        ++ [ 22000 21027 ]      # syncthing
        ;
    };
    # networkmanager.enable = true;
  };

  users = {
    groups = {
      johnw = {};
      typingmind = {};
    };
    users =
      let keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAj2IzkXyXEl+ReCg9H+t55oa6GIiumPWeufcYCWy3F yubikey-gnupg"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAING2r8bns7h9vZIfZSGsX+YmTSe2Tv1X8f/Qlqo+RGBb yubikey-14476831-gnupg"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJD0sIKWWVF+zIWcNm/BfsbCQxuUBHD8nRNSpZV+mCf+ ShellFish@iPhone-28062024"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIZQeQ/gKkOwuwktwD4z0ZZ8tpxNej3qcHS5ZghRcdAd ShellFish@iPad-22062024"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPvP6nhCLyJLa2LsXLVYN1lbGHfv/ZL+Rt/y3Ao/hfGz Clio"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMeIfb6iRmTROLKVslU2R0U//dP9qze1fkJMhE9wWrSJ Athena"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJmBoRIHfrT5RfCh1qyJP+aRwH6zpKJKv8KSk+1Rj8N0 Hera"
      ]; in {
        root = {
          openssh.authorizedKeys = { inherit keys; };
        };
        johnw = {
          uid = 1000;
          isNormalUser = true;
          description = "John Wiegley";
          group = "johnw";
          extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
          openssh.authorizedKeys = { inherit keys; };
          home = "/home/johnw";
        };
        typingmind = {
          isSystemUser = true;
          group = "typingmind";
          home = "/var/lib/typingmind";
          createHome = true;
        };
      };
  };

  environment = {
    systemPackages = with pkgs; [
      mailutils
      zfs-prune-snapshots
      httm
      b3sum
    ];
  };

  programs = {
    git.enable = true;
    htop.enable = true;
    tmux.enable = true;
    vim.enable = true;
  };

  systemd = {
    services.syncthing.environment.STNODEFAULTFOLDER = "true";

    services.zpool-scrub = {
      description = "Scrub ZFS pool";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = "/run/current-system/sw/bin/zpool scrub rpool tank";
      };
    };

    timers.zpool-scrub = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "monthly";
        Unit = "zpool-scrub.service";
      };
    };

    services.git-workspace-archive = {
      description = "Archive Git repositories";
      path = with pkgs; [
        git
        gitAndTools.git-workspace
        openssh
      ];
      serviceConfig = {
        User = "johnw";
        Group = "johnw";
        ExecStart = "/home/johnw/bin/workspace-update --archive";
      };
    };

    timers.git-workspace-archive = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Unit = "git-workspace-archive.service";
      };
    };

    services.restic-check =
      let
        restic-check-script = pkgs.writeShellApplication {
          name = "restic-check";
          text = ''
            for fileset in ${attrNameList services.restic.backups} ; do \
              echo "=== $fileset ==="; \
              /run/current-system/sw/bin/restic-$fileset \
                --retry-lock=1h check; \
              /run/current-system/sw/bin/restic-$fileset \
                --retry-lock=1h prune; \
              /run/current-system/sw/bin/restic-$fileset \
                --retry-lock=1h repair snapshots; \
            done
          '';
        }; in {
          description = "Run restic check on backup repository";
          serviceConfig = {
            ExecStart = "${lib.getExe restic-check-script}";
            User = "root";
          };
        };

    timers.restic-check = {
      description = "Timer for restic check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };

    # services.podman-pihole = {
    #   requires = [ "unbound.service" ];
    #   bindsTo = [ "unbound.service" ];
    #   after = [
    #     "unbound.service"
    #     "network-online.target"
    #   ];
    # };

    services.typingmind = {
      description = "TypingMind Service";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      path = with pkgs; [
        nodejs
        rsync
        yarn
      ];

      serviceConfig =
        let
          typingmind-src = pkgs.fetchFromGitHub {
            owner = "TypingMind";
            repo = "typingmind";
            rev = "83e7f925777af04ffb8247e92ca9adedf3581686";
            sha256 = "sha256-FuWjC1+qdbuueB9RL9OJZj8hs+y7BY5V75vgTC4h+dU=";
          };
          typingmind-script = pkgs.writeShellApplication {
            name = "run-typingmind";
            text = ''
              rsync -a ${typingmind-src}/ ./
              chmod u+w . yarn.lock
              yarn install
              yarn start
            '';
          }; in {
            Type = "simple";
            User = "johnw";
            Group = "johnw";
            WorkingDirectory = users.users.johnw.home + "/typingmind";
            ExecStart = "${lib.getExe typingmind-script}";
            Restart = "on-failure";
          };
    };
  };

  services = rec {
    hardware.bolt.enable = true;

    pihole-ftl = {
      enable = true;
      openFirewallDHCP = true;
      queryLogDeleter.enable = true;
      lists = [
        {
          url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
          description = "Steven Black's unified adlist";
        }
      ];
      settings = {
        webserver = {
          port = 7272;
          api.cli_pw = true;
        };
        dns = {
          port = 5353;
          domainNeeded = true;
          expandHosts = true;
          interface = "enp4s0";
          listeningMode = "BIND";
          upstreams = [ "192.168.50.1#53" ];
        };
        dhcp = {
          active = false;
          # active = true;
          router = "192.168.50.1";
          start = "192.168.50.2";
          end = "192.168.50.255";
          leastTime = "1d";
          ipv6 = true;
          multiDNS = true;
          hosts = [
            # Static address for the current host
            "aa:bb:cc:dd:ee:ff,192.168.10.1,${config.networking.hostName},infinite"
          ];
          rapidCommit = true;
        };
        misc.dnsmasq_lines = [
          # This DHCP server is the only one on the network
          "dhcp-authoritative"
          # Source: https://data.iana.org/root-anchors/root-anchors.xml
          "trust-anchor=.,38696,8,2,683D2D0ACB8C9B712A1948B27F741219298D0A450D612C483AF444A4C0FB2B16"
        ];
      };
    };

    # Set proper ownership for the secret

    postfix = {
      enable = true;
      relayHost = "smtp.fastmail.com";
      relayPort = 587;
      config = {
        smtp_use_tls = "yes";
        smtp_sasl_auth_enable = "yes";
        smtp_sasl_security_options = "";
        smtp_sasl_password_maps = "texthash:/secrets/postfix_sasl";
      };
    };

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "yes";
      };
    };

    # unbound = {
    #   enable = true;
    #   settings = {
    #     server = {
    #       interface = [ "127.0.0.1" ];
    #       port = 5353;

    #       # Minimize data in DNS queries for better privacy
    #       qname-minimisation = true;

    #       # Hide server identity and version
    #       hide-identity = true;
    #       hide-version = true;

    #       # Protect against DNS rebinding attacks
    #       private-address = [
    #         "192.168.0.0/16"
    #         "169.254.0.0/16"
    #         "172.16.0.0/12"
    #         "10.0.0.0/8"
    #         "fd00::/8"
    #         "fe80::/10"
    #       ];

    #       # Use 0x20 bit encoding to help protect against forgery
    #       use-caps-for-id = true;

    #       # Query logging (for debugging purposes)
    #       log-queries = false;
    #       verbosity = 1;

    #       # Define the .local zone as static so you can add your own records
    #       local-zone = [ "local. static" ];

    #       # Add static host records
    #       local-data = [
    #         "\"router.local. IN A 192.168.50.1\""
    #         "\"hera.local. IN A 192.168.50.5\""
    #         "\"athena.local. IN A 192.168.50.235\""
    #         "\"vulcan.local. IN A 192.168.50.182\""
    #         "\"bazigush.local. IN A 192.168.50.33\""
    #       ];

    #       # For PTR records (reverse lookups)
    #       local-data-ptr = [
    #         "\"192.168.50.1 router.local.\""
    #         "\"192.168.50.5 hera.local.\""
    #         "\"192.168.50.235 athena.local.\""
    #         "\"192.168.50.182 vulcan.local.\""
    #         "\"192.168.50.33 bazigush.local.\""
    #       ];
    #     };
    #   };
    # };

    nginx = {
      enable = true;
      # logError = "/var/log/nginx/error.log debug";

      recommendedGzipSettings = true;
      recommendedProxySettings = true;

      appendHttpConfig = ''
        large_client_header_buffers 4 16k;
        proxy_headers_hash_max_size 1024;
        proxy_headers_hash_bucket_size 128;
      '';

      virtualHosts = {
        smokeping.listen = [
          { addr = "0.0.0.0"; port = 8081; }
        ];

        "vulcan.local" = {
          forceSSL = true;      # Optional, for HTTPS
          sslCertificate = "/etc/ssl/certs/vulcan.local.crt";
          sslCertificateKey = "/etc/ssl/private/vulcan.local.key";

          root = "${portal}";

          extraConfig = ''
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Allow-Headers' 'Authorization,Accept,Origin,DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Content-Range,Range';
            add_header 'Access-Control-Allow-Methods' 'GET,POST,OPTIONS,PUT,DELETE,PATCH';
          '';

          locations."/smokeping/" = {
            proxyPass = "http://127.0.0.1:8081/";
          };
          locations."/smokeping" = {
            return = "301 /smokeping/";
          };

          locations."/jellyfin/" = {
            proxyPass = "http://127.0.0.1:8096/jellyfin/";
            proxyWebsockets = true;
          };
          locations."/jellyfin" = {
            return = "301 /jellyfin/";
          };

          locations."/pi-hole/admin/" = {
            proxyPass = "http://127.0.0.1:8082/admin/";
            proxyWebsockets = true;
            extraConfig = ''
              # Fix Pi-hole's internal redirects
              proxy_redirect /admin/ /pi-hole/admin/;

              # Hide X-Frame-Options to allow API token display to work
              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Frame-Options "SAMEORIGIN";

              # Fix any hardcoded URLs in the Pi-hole interface
              sub_filter '/admin/' '/pi-hole/admin/';
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;

              # Pass the Host header
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Cookie handling
              proxy_cookie_path /admin/ /pi-hole/admin/;
            '';
          };
          # It would be preferable if this were not here; it may conflict with
          # some service in the future.
          locations."/api/" = {
            proxyPass = "http://127.0.0.1:8082/api/";
          };
          locations."/pi-hole" = {
            return = "301 /pi-hole/admin/";
          };
          locations."/pi-hole/" = {
            return = "301 /pi-hole/admin/";
          };

          locations."/syncthing/" = {
            proxyPass = "http://127.0.0.1:8384/";
            proxyWebsockets = true;
            extraConfig = ''
              # Hide X-Frame-Options to allow API token display to work
              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Frame-Options "SAMEORIGIN";

              # Pass the Host header
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Increase timeouts
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;

              proxy_redirect /rest/ /syncthing/rest/;

              sub_filter '/rest/' '/syncthing/rest/';
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;

              rewrite ^/syncthing/(.*)$ /$1 break;
            '';
          };
          locations."/rest/" = {
            proxyPass = "http://127.0.0.1:8384/rest/";
            proxyWebsockets = true;
          };
          locations."/syncthing" = {
            return = "301 /syncthing/";
          };

          locations."/glance/" = {
            proxyPass = "http://127.0.0.1:5678/";
          };

          locations."/typingmind/" = {
            proxyPass = "http://127.0.0.1:3000/";
            proxyWebsockets = true;
            extraConfig = ''
              # Hide X-Frame-Options to allow API token display to work
              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Frame-Options "SAMEORIGIN";

              # Pass the Host header
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Increase timeouts
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;

              sub_filter 'href="/' 'href="/typingmind/';
              sub_filter 'src="/' 'src="/typingmind/';
              sub_filter 'content="/' 'content="/typingmind/';
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;
            '';
          };

          locations."/silly-tavern/" = {
            proxyPass = "http://127.0.0.1:8083/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Frame-Options "SAMEORIGIN";

              proxy_set_header Host $host;
              # proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header Accept-Encoding "";

              sub_filter 'href="/' 'href="/silly-tavern/';
              sub_filter 'src="/' 'src="/silly-tavern/';
              sub_filter 'content="/' 'content="/silly-tavern/';
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;
            '';
          };
          locations."/silly-tavern" = {
            return = "301 /silly-tavern/";
          };
        };
      };
    };

    logwatch =
      let
        restic-script = pkgs.writeShellApplication {
          name = "logwatch-restic";
          text = ''
            for fileset in ${attrNameList restic.backups} ; do \
              echo "=== $fileset ==="; \
              /run/current-system/sw/bin/restic-$fileset snapshots --json | \
                ${pkgs.jq}/bin/jq -r \
                  'sort_by(.time) | reverse | .[:4][] | .time'; \
            done
          '';
        };
        zfs-snapshot-script = pkgs.writeShellApplication {
          name = "logwatch-zfs-snapshot";
          text = ''
            for fs in $(/run/current-system/sw/bin/zfs list \
                          -H -o name -t filesystem -r); do \
              /run/current-system/sw/bin/zfs list \
                -H -o name -t snapshot -S creation -d 1 "$fs" | head -1; \
            done
          '';
        };
        zpool-script = pkgs.writeShellApplication {
          name = "logwatch-zpool";
          text = "/run/current-system/sw/bin/zpool status";
        };
        systemctl-failed-script = pkgs.writeShellApplication {
          name = "logwatch-systemctl-failed";
          text = "/run/current-system/sw/bin/systemctl --failed";
        };
      in {
        enable = true;
        range = "since 24 hours ago for those hours";
        mailto = "johnw@newartisans.com";
        mailfrom = "johnw@newartisans.com";
        customServices = [
          { name = "systemctl-failed";
            title = "Failed systemctl services";
            script = "${lib.getExe systemctl-failed-script}";
          }
          { name = "sshd"; }
          { name = "restic";
            title = "Restic Snapshots";
            script = "${lib.getExe restic-script}"; }
          { name = "zpool";
            title = "ZFS Pool Status";
            script = "${lib.getExe zpool-script}"; }
          { name = "zfs-snapshot";
            title = "ZFS Snapshots";
            script = "${lib.getExe zfs-snapshot-script}"; }
        ];
      };

    sanoid = {
      enable = true;

      datasets = {
        "rpool".use_template = [ "active" ];

        "tank" = {
          use_template = [ "archival" ];
          recursive = true;
          process_children_only = true;
        };

        "tank/Downloads".use_template = [ "active" ];
        "tank/Backups/chainweb".use_template = [ "production" ];
      };

      templates = {
        active = {
          frequently = 0;
          hourly = 24;
          daily = 7;
          monthly = 3;
          autosnap = true;
          autoprune = true;
        };

        archival = {
          frequently = 0;
          hourly = 96;
          daily = 90;
          weekly = 26;
          monthly = 12;
          yearly = 30;
          autosnap = true;
          autoprune = true;
        };

        production = {
          frequently = 0;
          hourly = 24;
          daily = 14;
          weekly = 4;
          monthly = 3;
          yearly = 0;
          autosnap = true;
          autoprune = true;
        };
      };
    };

    smokeping = {
      enable = true;

      alertConfig = ''
        to = alertee@address.somewhere
        from = smokealert@company.xy

        +someloss
        type = loss
        # in percent
        pattern = >0%,*12*,>0%,*12*,>0%
        comment = loss 3 times  in a row
      '';

      databaseConfig = ''
        step     = 300
        pings    = 20

        # consfn mrhb steps total

        AVERAGE  0.5   1  1008
        AVERAGE  0.5  12  4320
        MIN  0.5  12  4320
        MAX  0.5  12  4320
        AVERAGE  0.5 144   720
        MAX  0.5 144   720
        MIN  0.5 144   720
      '';

      probeConfig = ''
        + FPing
        binary = ${pkgs.fping}/bin/fping

        + FPing6
        binary = ${pkgs.fping}/bin/fping
        protocol = 6

        + DNS
        binary = ${pkgs.dig}/bin/dig
        lookup = google.com
        pings = 5
        step = 300
      '';

      targetConfig = ''
        probe = FPing

        menu = Top
        title = Network Latency Grapher
        remark = Welcome to the SmokePing website of WORKS Company. \
        Here you will learn all about the latency of our network.

        + InternetSites

        menu = Internet Sites
        title = Internet Sites

        ++ Facebook
        menu = Facebook
        title = Facebook
        host = facebook.com

        ++ Youtube
        menu = YouTube
        title = YouTube
        host = youtube.com

        ++ JupiterBroadcasting
        menu = JupiterBroadcasting
        title = JupiterBroadcasting
        host = jupiterbroadcasting.com

        ++ GoogleSearch
        menu = Google
        title = google.com
        host = google.com

        ++ GoogleSearchIpv6
        menu = Google
        probe = FPing6
        title = ipv6.google.com
        host = ipv6.google.com

        ++ linuxserverio
        menu = linuxserver.io
        title = linuxserver.io
        host = linuxserver.io

        + Europe

        menu = Europe
        title = European Connectivity

        ++ Germany

        menu = Germany
        title = The Fatherland

        +++ TelefonicaDE

        menu = Telefonica DE
        title = Telefonica DE
        host = www.telefonica.de

        ++ Switzerland

        menu = Switzerland
        title = Switzerland

        +++ CernIXP

        menu = CernIXP
        title = Cern Internet eXchange Point
        host = cixp.web.cern.ch

        +++ SBB

        menu = SBB
        title = SBB
        host = www.sbb.ch/en

        ++ UK

        menu = United Kingdom
        title = United Kingdom

        +++ CambridgeUni

        menu = Cambridge
        title = Cambridge
        host = cam.ac.uk

        +++ UEA

        menu = UEA
        title = UEA
        host = www.uea.ac.uk

        + USA

        menu = North America
        title = North American Connectivity

        ++ MIT

        menu = MIT
        title = Massachusetts Institute of Technology Webserver
        host = web.mit.edu

        ++ IU

        menu = IU
        title = Indiana University
        host = www.indiana.edu

        ++ UCB

        menu = U. C. Berkeley
        title = U. C. Berkeley Webserver
        host = www.berkeley.edu

        ++ UCSD

        menu = U. C. San Diego
        title = U. C. San Diego Webserver
        host = ucsd.edu

        ++ UMN

        menu =  University of Minnesota
        title = University of Minnesota
        host = twin-cities.umn.edu

        ++ OSUOSL

        menu = Oregon State University Open Source Lab
        title = Oregon State University Open Source Lab
        host = osuosl.org

        + DNS
        menu = DNS
        title = DNS

        ++ GoogleDNS1
        menu = Google DNS 1
        title = Google DNS 8.8.8.8
        host = 8.8.8.8

        ++ GoogleDNS2
        menu = Google DNS 2
        title = Google DNS 8.8.4.4
        host = 8.8.4.4

        ++ OpenDNS1
        menu = OpenDNS1
        title = OpenDNS1
        host = 208.67.222.222

        ++ OpenDNS2
        menu = OpenDNS2
        title = OpenDNS2
        host = 208.67.220.220

        ++ CloudflareDNS1
        menu = Cloudflare DNS 1
        title = Cloudflare DNS 1.1.1.1
        host = 1.1.1.1

        ++ CloudflareDNS2
        menu = Cloudflare DNS 2
        title = Cloudflare DNS 1.0.0.1
        host = 1.0.0.1

        ++ L3-1
        menu = Level3 DNS 1
        title = Level3 DNS 4.2.2.1
        host = 4.2.2.1

        ++ L3-2
        menu = Level3 DNS 2
        title = Level3 DNS 4.2.2.2
        host = 4.2.2.2

        ++ Quad9
        menu = Quad9
        title = Quad9 DNS 9.9.9.9
        host = 9.9.9.9

        + DNSProbes
        menu = DNS Probes
        title = DNS Probes
        probe = DNS

        ++ GoogleDNS1
        menu = Google DNS 1
        title = Google DNS 8.8.8.8
        host = 8.8.8.8

        ++ GoogleDNS2
        menu = Google DNS 2
        title = Google DNS 8.8.4.4
        host = 8.8.4.4

        ++ OpenDNS1
        menu = OpenDNS1
        title = OpenDNS1
        host = 208.67.222.222

        ++ OpenDNS2
        menu = OpenDNS2
        title = OpenDNS2
        host = 208.67.220.220

        ++ CloudflareDNS1
        menu = Cloudflare DNS 1
        title = Cloudflare DNS 1.1.1.1
        host = 1.1.1.1

        ++ CloudflareDNS2
        menu = Cloudflare DNS 2
        title = Cloudflare DNS 1.0.0.1
        host = 1.0.0.1

        ++ L3-1
        menu = Level3 DNS 1
        title = Level3 DNS 4.2.2.1
        host = 4.2.2.1

        ++ L3-2
        menu = Level3 DNS 2
        title = Level3 DNS 4.2.2.2
        host = 4.2.2.2

        ++ Quad9
        menu = Quad9
        title = Quad9 DNS 9.9.9.9
        host = 9.9.9.9
      '';
    };

    restic.backups =
      let backup = {
        explicit ? false,
        path,
        name ? path,
        bucket ? name,
        exclude ? []
      }: {
        "${name}" = {
          paths = if explicit then [ path ] else [ "/tank/${path}" ];
          inherit exclude;
          repository = "s3:s3.us-west-001.backblazeb2.com/jwiegley-${bucket}";
          initialize = true;
          passwordFile = "/secrets/restic_password";
          environmentFile = "/secrets/aws_keys";
          timerConfig = {
            OnCalendar = "*-*-* 02:00:00";  # Daily at 2AM
            Persistent = true;
          };
          pruneOpts = [
            "--keep-daily 7"
            "--keep-weekly 5"
            "--keep-yearly 3"
          ];
        };
      };
      in
        # List snapshots to verify backups are being created:
        # > sudo restic-doc snapshots
        # Test a restore to verify data can be recovered:
        # > sudo restic-doc restore --target /path/to/restore/directory latest
        # Check repository integrity:
        # > sudo restic-doc check

        # These directories are either too large, too private, or are already
        # backed up via another cloud service.
        #
        # backup { path = "Desktop"; } //
        # backup { path = "Documents"; } //
        # backup { path = "Downloads"; } //
        # backup { path = "Machines"; } //
        # backup { path = "Models"; } //
        # backup { path = "Movies"; } //
        # backup { path = "Music"; } //
        # backup { path = "Pictures"; } //
        # backup { path = "kadena"; } //

        backup {
          path = "doc";
          exclude = [ "*.dtBase/Backup*" ];
        } //
        backup {
          path = "src";
          exclude = [
            "*.agdai"
            "*.aux"
            "*.cma"
            "*.cmi"
            "*.cmo"
            "*.cmx"
            "*.cmxa"
            "*.cmxs"
            "*.elc"
            "*.eln"
            "*.glob"
            "*.hi"
            "*.lia-cache"
            "*.lra-cache"
            "*.nia-cache"
            "*.nra-cache"
            "*.o"
            "*.vo"
            "*.vok"
            "*.vos"
            ".MAlonzo"
            ".cabal"
            ".cargo"
            ".coq-native"
            ".dist"
            ".dist-newstyle"
            ".ghc"
            ".ghc.*"
            ".lia.cache"
            ".local/share/vagrant"
            ".lra.cache"
            ".nia.cache"
            ".nra.cache"
            ".slocdata"
            ".vagrant"
            "result"
            "result-*"
          ];
        } //
        backup {
          path = "Home";
          exclude = [
            "Library/Application Support/Bookmap/Cache"
            "Library/Application Support/FileProvider"
            "Library/Application Support/MobileSync"
            "Library/CloudStorage/GoogleDrive-copper2gold1@gmail.com"
            "Library/Containers"
            "Library/Caches/GeoServices"
          ];
        } //
        backup {
          path = "Photos";
        } //
        backup {
          path = "Audio";
        } //
        backup {
          path = "Video";
          exclude = [
            "Bicycle"
            "Category Theory"
            "Cinema"
            "Finance"
            "Haskell"
            "Kadena"
            "Racial Justice"
            "Zoom"
          ];
        } //
        backup {
          path = "Backups";
          bucket = "Backups-Misc";
          exclude = [
            "Git"
            "Images"
            "chainweb"
          ];
        } //
        backup {
          path = "Nasim";
        }
        ;

    jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      user = "johnw";
    };

    syncthing = {
      enable = true;
      guiAddress = "0.0.0.0:8384";
      key = "/secrets/syncthing/key.pem";
      cert = "/secrets/syncthing/cert.pem";
      user = "johnw";
      dataDir = "/home/johnw/syncthing";
      configDir = "/home/johnw/.config/syncthing";
      overrideDevices = true;
      overrideFolders = true;
      settings = {
        devices = {
          vulcan.id =
            "AGFFJSH-MDGXYTO-FSR7GZM-VE4IR2U-OU4AKP4-OLY4WXR-WEF72EY-YRNI3AJ";
          iphone.id =
            "NK7DHKG-WVJZQTY-YOPUQXP-GPUOQY3-EK5ZJA6-M6NKQNJ-6BYBIO6-RUSRXQY";
          surface.id =
            "IXRXTO6-LDI6HZO-3TMVGVK-32CMPYV-TOPUWRZ-OUF3KWI-NEPF6T6-H7BDGAR";
        };
        folders = {
          "Nasim" = {
            path = "/tank/Nasim";
            devices = [ "vulcan" "surface" "iphone" ];
          };
        };
        gui = {
          user = "admin";
          password = "syncthing";
        };
      };
      # Opens 8384 (GUI), 22000 (sync), 21027/UDP (discovery)
      openDefaultPorts = true;
    };

    postgresql = {
      enable = true;
      ensureDatabases = [ "db" ];
      enableTCPIP = true;
      settings.port = 5432;
      # dataDir = "/var/lib/postgresql/16";

      # Create a default user and set authentication
      authentication = pkgs.lib.mkOverride 10 ''
        #type database DBuser auth-method
        local all all trust
      '';
      initialScript = pkgs.writeText "init.sql" ''
        CREATE ROLE johnw WITH LOGIN PASSWORD 'password' CREATEDB;
        CREATE DATABASE db;
        GRANT ALL PRIVILEGES ON DATABASE db TO johnw;
      '';
    };

    litellm = {
      enable = true;           # jww (2025-05-21): disabled for now
      package = pkgs.python3Packages.litellm;

      environmentFile = "/secrets/litellm.env";

      settings = {
        model_list = [
          {
            model_name = "deepseek-r1";
            litellm_params = {
              model = "openai/r1-1776";
              api_base = "http://192.168.50.5:8080";
            };
          }
          {
            model_name = "gpt4o";
            litellm_params = {
              model = "gpt-4o";
              api_key = "os.environ/OPENAI_API_KEY";
            };
          }
        ];

        general_settings = {
          master_key = "sk-system-key";
        };
      };

      environment = {
        OLLAMA_HOST = "127.0.0.1:11434";
      };

      host = "0.0.0.0";
      port = 7600;
      openFirewall = true;
    };

    glance = {
      enable = true;
      settings = {
        server = {
          port = 5678;
          base-url = "/glance";
        };
        pages = [
          {
            name = "Home";
            columns = [
              {
                size = "small";
                widgets = [
                  {
                    type = "calendar";
                    first-day-of-week = "monday";
                  }
                  {
                    type = "rss";
                    limit = 10;
                    collapse-after = 3;
                    cache = "12h";
                    feeds = [
                      {
                        url = "https://selfh.st/rss/";
                        title = "selfh.st";
                        limit = 4;
                      }
                      {
                        url = "https://ciechanow.ski/atom.xml";
                      }
                      {
                        url = "https://www.joshwcomeau.com/rss.xml";
                        title = "Josh Comeau";
                      }
                      {
                        url = "https://samwho.dev/rss.xml";
                      }
                      {
                        url = "https://ishadeed.com/feed.xml";
                        title = "Ahmad Shadeed";
                      }
                    ];
                  }
                  {
                    type = "twitch-channels";
                    channels = [
                      "theprimeagen"
                      "j_blow"
                      "piratesoftware"
                      "cohhcarnage"
                      "christitustech"
                      "EJ_SA"
                    ];
                  }
                ];
              }
              {
                size = "full";
                widgets = [
                  {
                    type = "group";
                    widgets = [
                      {
                        type = "dns-stats";
                        service = "pihole-v6";
                        url = "http://localhost:8082";
                        allow-insecure = true;
                        username = "admin";
                        # jww (2025-05-06): This makes the nix build impure
                        password = builtins.readFile "/secrets/pihole";
                      }
                      {
                        type = "hacker-news";
                      }
                      {
                        type = "lobsters";
                      }
                    ];
                  }
                  {
                    type = "videos";
                    channels = [
                      "UCXuqSBlHAE6Xw-yeJA0Tunw" # Linus Tech Tips
                      "UCR-DXc1voovS8nhAvccRZhg" # Jeff Geerling
                      "UCsBjURrPoezykLs9EqgamOA" # Fireship
                      "UCBJycsmduvYEL83R_U4JriQ" # Marques Brownlee
                      "UCHnyfMqiRRG1u-2MsSQLbXA" # Veritasium
                    ];
                  }
                  {
                    type = "group";
                    widgets = [
                      {
                        type = "reddit";
                        subreddit = "technology";
                        show-thumbnails = true;
                      }
                      {
                        type = "reddit";
                        subreddit = "selfhosted";
                        show-thumbnails = true;
                      }
                    ];
                  }
                ];
              }
              {
                size = "small";
                widgets = [
                  {
                    type = "clock";
                    timezone = "America/Los_Angeles";
                  }
                  {
                    type = "weather";
                    location = "Arden-Arcade, United States";
                    units = "imperial";
                    hour-format = "12h";
                  }
                  {
                    type = "server-stats";
                    servers = [
                      {
                        type = "local";
                        name = "Services";
                      }
                    ];
                  }
                  {
                    type = "markets";
                    markets = [
                      {
                        symbol = "SPY";
                        name = "S&P 500";
                      }
                      {
                        symbol = "BTC-USD";
                        name = "Bitcoin";
                      }
                      {
                        symbol = "NVDA";
                        name = "NVIDIA";
                      }
                      {
                        symbol = "AAPL";
                        name = "Apple";
                      }
                      {
                        symbol = "MSFT";
                        name = "Microsoft";
                      }
                    ];
                  }
                  # {
                    #   type = "releases";
                    #   cache = "1d";
                    #   repositories = [
                      #     "glanceapp/glance"
                      #     "go-gitea/gitea"
                      #     "immich-app/immich"
                      #     "syncthing/syncthing"
                      #   ];
                      # }
                ];
              }
            ];
          }
        ];
      };
    };

    # home-assistant = {
    #   enable = true;
    #   extraComponents = [
    #     "alexa"
    #     "nest"
    #     "lg_thinq"
    #   ];
    #   config = {
    #     default_config = {};
    #   };
    # };
  };

  virtualisation.oci-containers.containers = {
    pihole = {
      autoStart = true;
      image = "pihole/pihole:latest";
      ports = [
        "53:53/tcp"
        "53:53/udp"
        "67:67/udp"
        "8082:8082/tcp"
      ];
      environment = {
        TZ = "America/Los_Angeles";
        WEBPASSWORD = "your_secure_password";
        PIHOLE_INTERFACE = "enp4s0";
        FTLCONF_dns_listeningMode = "all";
        # DNS1 = "127.0.0.1#5353";
        # DNS2 = "127.0.0.1#5353";
      };
      volumes = [
        "/var/lib/pihole/etc-pihole:/etc/pihole"
        "/var/lib/pihole/etc-dnsmasq.d:/etc/dnsmasq.d"
      ];
      extraOptions = [
        "--network=host"
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
    };

    silly-tavern = {
      autoStart = true;
      image = "ghcr.io/sillytavern/sillytavern:latest";
      ports = [
        "8083:8000/tcp"
      ];
      environment = {
        NODE_ENV = "production";
        FORCE_COLOR = "1";
      };
      volumes = [
        "/var/lib/silly-tavern/config:/home/node/app/config"
        "/var/lib/silly-tavern/data:/home/node/app/data"
        "/var/lib/silly-tavern/plugins:/home/node/app/plugins"
        "/var/lib/silly-tavern/extensions:/home/node/app/public/scripts/extensions/third-party"
      ];
      extraOptions = [
      ];
    };
  };

  # system.activationScripts.consoleBlank = ''
  #   echo "Setting up console blanking..."
  #   ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 > /dev/tty1
  # '';
}
