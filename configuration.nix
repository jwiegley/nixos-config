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
  system.stateVersion = "25.05"; # Did you read the comment?

  imports =
    [ ./hardware-configuration.nix
    ];

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
      allowedTCPPorts = [ 53 80 443 ] ++ [ 8384 22000 ]; # syncthing
      allowedUDPPorts = [ 53 67 ] ++ [ 22000 21027 ];    # syncthing
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
        };
      };
  };

  environment = {
    systemPackages = with pkgs; [
      mailutils
      zfs-prune-snapshots
      httm
      jq
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
  };

  services = rec {
    hardware.bolt.enable = true;

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
            '';
          };
          locations."/syncthing" = {
            return = "301 /syncthing/";
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
                          -H -o name -t filesystem -r tank); do \
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
        "tank" = {
          use_template = [ "archival" ];
          recursive = true;
          process_children_only = true;
        };

        "tank/ChainState/kadena" = {
          use_template = [ "production" ];
          recursive = true;
          process_children_only = true;
        };
      };

      templates = {
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
        bucket ? path,
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
          name = "Backups";
          path = "Backups";
          bucket = "Backups-Misc";
          exclude = [
            "Git"
            "Images"
            "chainweb"
          ];
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
          hera = { id = "DEVICE-ID-OF-LAPTOP"; };
          surface = { id = "DEVICE-ID-OF-LAPTOP"; };
        };
        folders = {
          "Nasim" = {
            path = "/tank/Nasim";
            devices = [ "vulcan" "surface" ];
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
  };

  # system.activationScripts.consoleBlank = ''
  #   echo "Setting up console blanking..."
  #   ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 > /dev/tty1
  # '';
}
