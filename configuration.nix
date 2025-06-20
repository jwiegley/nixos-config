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
in rec {
  system.stateVersion = "25.05";

  imports =
    [ ./hardware-configuration.nix
    ];

  nixpkgs.config = {
    allowUnfree = true;
    # packageOverrides = pkgs: {
    #   python3Packages = pkgs.python3Packages.override {
    #     overrides = self: super: {
    #     };
    #   };
    # };
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

    hosts = {
      "127.0.0.2" = lib.mkForce [];
      "192.168.50.182" = [ "vulcan.local" "vulcan" ];
    };

    interfaces.enp4s0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "192.168.50.182";
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = "192.168.50.1";
    nameservers = [ "192.168.50.1" ];

    firewall = {

      allowedTCPPorts = [ 53 80 443 ]
        ++ [ 5432 ]             # postgres
        ++ [ 8096 ]             # jellyfin
        ;
      # allowedUDPPorts = [ 53 67 ]
      allowedUDPPorts = [ 53 ]
        ;
    };
    # networkmanager.enable = true;
  };

  users = {
    groups = {
      johnw = {};
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
      };
  };

  environment =
    let
      dh = pkgs.writeScriptBin "dh" ''
        #!/usr/bin/env bash

        if ! command -v zfs > /dev/null 2>&1; then
            echo "ERROR: ZFS not installed on this system"
            exit 1
        fi

        sort=""
        type="filesystem,volume"
        fields="name,used,refer,avail,compressratio,mounted"

        if [[ "$1" == "-u" ]]; then
            sort="-s used"
            shift
        elif [[ "$1" == "-s" ]]; then
            type="snapshot"
            fields="name,refer,creation"
            shift
        elif [[ "$1" == "-r" ]]; then
            sort="-s refer"
            shift
        fi

        exec zfs list -o $fields -t $type $sort "$@"
      '';

      linkdups = with pkgs; stdenv.mkDerivation rec {
        name = "linkdups-${version}";
        version = "1.3";

        src = fetchFromGitHub {
          owner = "jwiegley";
          repo = "linkdups";
          rev = "57bb79332d3b79418692d0c974acba83a4fd3fc9";
          sha256 = "1d400vanbsrmfxf1w4na3r4k3nw18xnv05qcf4rkqajmnfrbzh3h";
          # date = 2025-05-13T11:29:24-07:00;
        };

        phases = [ "unpackPhase" "installPhase" ];

        installPhase = ''
          mkdir -p $out/bin
          cp -p linkdups $out/bin
        '';

        meta = {
          homepage = https://github.com/jwiegley/linkdups;
          description = "A tool for hard-linking duplicate files";
          license = lib.licenses.mit;
          maintainers = with lib.maintainers; [ jwiegley ];
        };
      };
    in {
    systemPackages = with pkgs; [
      mailutils
      zfs-prune-snapshots
      httm
      b3sum
      haskellPackages.sizes
      linkdups
      dh
    ];
  };

  programs = {
    git.enable = true;
    htop.enable = true;
    tmux.enable = true;
    vim.enable = true;

    nix-ld = {
      enable = true;
      libraries = with pkgs; [
        nodejs
      ];
    };
  };

  systemd = {
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
  };

  services = rec {
    hardware.bolt.enable = true;

    ntopng = {
      enable = true;
      httpPort = 3030;
      configText = ''
        --interface=any
        --http-port=3030
        --disable-login
        --local-networks=192.168.50.0/24
        --redis=127.0.0.1:8085
        --http-prefix=/ntopng
      '';
    };

    redis.servers."litellm" = {
      enable = true;
      port = 8085;
      settings = {
        "aclfile" = "/etc/redis/users.acl";
      };
    };

    fail2ban = {
      enable = true;

      jails.sshd.settings = {
        enabled = true;
        maxretry = 10;        # Allow up to 10 failed attempts
        findtime = 3600;      # Count failures within an hour (3600 seconds)
        bantime = "24h";      # Ban for one day
        backend = "systemd";  # Use systemd journal (works best on NixOS)
      };
    };


    pihole-ftl = {
      enable = true;
      openFirewallDHCP = true;
      queryLogDeleter.enable = true;
      lists = [
        { url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
          description = "Steven Black's unified adlist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt";
          description = "DNS Blocklists Threat Intelligence Feeds"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/spam-tlds-adblock.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt";
          description = "DNS Blocklist Multi PRO"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/popupads.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/hoster.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/gambling.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh-vpn-proxy-bypass.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/anti.piracy.txt";
          description = "DNS Blocklist"; }
        { url = "https://raw.githubusercontent.com/froggeric/DNS-blocklists/refs/heads/main/NoAppleAds";
          description = "Block Apple ads"; }
        { url = "https://big.oisd.nl/";
          description = "oisd big"; }
      ];
      settings = {
        dns = {
          port = 53;
          domainNeeded = true;
          expandHosts = true;
          interface = "enp4s0";
          listeningMode = "BIND";
          upstreams = [
            "192.168.50.1#53"
            "8.8.8.8"
            "8.8.4.4"
          ];
        };
        dhcp = {
          active = false;
          router = "192.168.50.1";
          start = "192.168.50.2";
          end = "192.168.50.254";
          leastTime = "1d";
          ipv6 = false;
          multiDNS = true;
          hosts = [
            # Static address for the current host
            "cc:2d:b7:01:f8:7f,192.168.50.182,${config.networking.hostName},infinite"

            "1c:1d:d3:e0:d8:2d,192.168.50.5,hera,infinite"
            "16:f9:5b:42:10:69,hera-wifi"
            "9c:76:0e:31:5c:6d,192.168.50.235,athena,infinite"
            "da:b3:f0:75:78:83,athena-wifi"
            "7a:d4:a8:c5:f7:97,clio"
            "74:56:3c:b7:24:ac,bazigush"

            # Network hosts

            "6a:9a:43:fb:7e:af,Johns-iPhone"
            "b2:23:15:55:56:d4,Johns-iPad"
            "94:21:57:3e:ce:9e,Johns-Watch"

            "62:97:48:33:6f:32,Nasims-iPhone"

            "00:1d:63:67:81:16,Miele-Dishwasher"
            "08:04:b4:bb:ee:21,Pentair-IntelliCenter-Radio"
            "08:60:6e:21:14:e0,Asus-RT-N66U"
            "08:b6:1f:66:71:14,Hubspace-Porch-Light"
            "0c:83:cc:13:70:e8,MyQ-Garage-Door"
            "1c:f2:9a:11:b6:0d,Google-Home-Nest-Hub"
            "44:67:55:03:b3:cc,B-hyve-Sprinkler-Control"
            "44:bb:3b:4a:99:af,Google-Nest-Downstairs"
            "44:bb:3b:4b:80:4c,Google-Nest-Upstairs"
            "44:bb:3b:4c:24:0d,Google-Nest-Family-Room"
            "54:49:df:3a:0e:7a,Peloton"
            "54:e0:19:1e:5d:ff,Ring-Video-Doorbell"
            "5c:fc:e1:47:4e:48,ADT-Home-Security"
            "60:8a:10:dd:b2:40,Traeger-Ironwood-Grill"
            "70:c9:32:2b:83:9d,Dreamebot-Robot-Vacuum"
            "78:2b:64:b4:5d:25,Bose-Portable-Home-Speaker"
            "78:9c:85:33:54:5d,August-Home-Garage"
            "78:9c:85:34:a5:0d,August-Home-Side-Door"
            "78:9c:85:34:a5:33,August-Home-Front-Door"
            "90:48:46:8d:6b:10,Enphase-Solar-Inverter"
            "98:ed:5c:8e:56:91,Tesla-Wall-Connector"
            "b4:8a:0a:f6:13:b8,Flume-Water-Meter"
            "e8:9f:6d:4a:f9:e8,Pentair-IntelliFlo-3"
            "fc:12:63:cd:e1:01,192.168.50.121,4G-LTE-Network-Extender,infinite"
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

    pihole-web = {
      enable = true;
      ports = [ 8082 ];
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
          # forceSSL = true;      # Optional, for HTTPS
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

          locations."/pi-hole/" = {
            proxyPass = "http://127.0.0.1:8082/";
            proxyWebsockets = true;
            extraConfig = ''
              # Hide X-Frame-Options to allow API token display to work
              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Frame-Options "SAMEORIGIN";

              # Fix any hardcoded URLs in the Pi-hole interface
              sub_filter '="/' '="/pi-hole/';
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;

              # Pass the Host header
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Cookie handling
              proxy_cookie_path / /pi-hole/;
            '';
          };
          # It would be preferable if this were not here; it may conflict with
          # some service in the future.
          locations."/api/" = {
            proxyPass = "http://127.0.0.1:8082/api/";
          };
          locations."/pi-hole" = {
            return = "301 /pi-hole/";
          };

          locations."/glance/" = {
            proxyPass = "http://127.0.0.1:5678/";
          };

          locations."/litellm/" = {
            proxyPass = "http://127.0.0.1:4000/litellm/";
            proxyWebsockets = true;
            extraConfig = ''
              # (Optional) Disable proxy buffering for better streaming
              # response from models
              proxy_buffering off;

              # (Optional) Increase max request size for large attachments
              # and long audio messages
              client_max_body_size 20M;
              proxy_read_timeout 2h;
            '';
          };

          locations."/ntopng/" = {
            proxyPass = "http://127.0.0.1:3030/ntopng/";
            proxyWebsockets = true;
          };
          locations."/ntopng" = {
            return = "301 /ntopng/";
          };

          locations."/open-webui/" = {
            proxyPass = "http://127.0.0.1:8084/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Frame-Options "SAMEORIGIN";

              proxy_set_header Accept-Encoding ""; # no compression allowed or next won't work

              sub_filter '"/' '"/open-webui/';
              sub_filter "'/" "'/open-webui/";
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;

              # (Optional) Disable proxy buffering for better streaming response from models
              proxy_buffering off;

              # (Optional) Increase max request size for large attachments and long audio messages
              client_max_body_size 20M;
              proxy_read_timeout 10m;

              # Pass the Host header
              # proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Cookie handling
              proxy_cookie_path / /open-webui/;
            '';
          };
          locations."/open-webui" = {
            return = "301 /open-webui/";
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

    postgresql = {
      enable = true;
      ensureDatabases = [ "db" "litellm" ];
      ensureUsers = [
        { name = "postgres"; }
      ];
      enableTCPIP = true;
      settings.port = 5432;
      # dataDir = "/var/lib/postgresql/16";

      # Create a default user and set authentication
      authentication = pkgs.lib.mkOverride 10 ''
        local all all trust
        host all all 127.0.0.1/32 trust
        host all all 192.168.50.0/24 md5
        host all all 10.88.0.0/16 trust
        host all all ::1/128 trust
      '';
      initialScript = pkgs.writeText "init.sql" ''
        CREATE ROLE johnw WITH LOGIN PASSWORD 'password' CREATEDB;

        CREATE DATABASE db;
        GRANT ALL PRIVILEGES ON DATABASE db TO johnw;

        CREATE ROLE litellm WITH LOGIN PASSWORD 'sk-1234' CREATEDB;

        CREATE DATABASE litellm;
        GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
        \c litellm
        GRANT ALL ON SCHEMA public TO litellm;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO litellm;
      '';
    };

    open-webui = {
      enable = true;
      port = 8084;
      host = "0.0.0.0";
      environment = {
        ANONYMIZED_TELEMETRY = "False";
        DO_NOT_TRACK = "True";
        SCARF_NO_ANALYTICS = "True";
        ROOT_PATH = "open-webui";
      };
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
                ];
              }
            ];
          }
        ];
      };
    };
  };

  virtualisation.oci-containers = {
    containers = {
      litellm = {
        autoStart = true;
        image = "ghcr.io/berriai/litellm-database:main-stable";
        ports = [
          "4000:4000/tcp"
        ];
        environment = {
          SERVER_ROOT_PATH = "/litellm";
          LITELLM_MASTER_KEY = "sk-1234";
          DATABASE_URL =
            "postgresql://litellm:sk-1234@host.containers.internal:5432/litellm";
          # REDIS_HOST = "localhost";
          # REDIS_PORT = "8085" ;
          # REDIS_PASSWORD = "sk-1234";
        };
        volumes = [
          "/etc/litellm/config.yaml:/app/config.yaml:ro"
        ];
        cmd = [
          "--config" "/app/config.yaml"
          # "--detailed_debug"
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
        extraOptions = [];
      };
    };
  };


  # system.activationScripts.consoleBlank = ''
  #   echo "Setting up console blanking..."
  #   ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 > /dev/tty1
  # '';
}
