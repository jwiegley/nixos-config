{ config, lib, pkgs, ... }:
let
  chain-restic-backups-service = before: after: {
    systemd.services."restic-backups-${after}" = {
      after = [ "restic-backups-${before}.service" ];
      requires = [ "restic-backups-${before}.service" ];
    };
  };

  pairs = list:
    if builtins.length list < 2
    then []
    else [ [ list.${toString 0} list.${toString 1} ] ]
           ++ pairs (builtins.tail list);

  chain-restic-backups = list:
    lib.attrsets.mergeAttrsList (map chain-restic-backups-service (pairs list));

  portal = pkgs.stdenv.mkDerivation {
    name = "nginx-portal";
    src = ./nginx-portal;
    installPhase = ''
      mkdir -p $out
      cp -r $src/* $out/
    '';
  };
in
{
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
      echo 1 > /sys/bus/pci/rescan
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
      allowedTCPPorts = [ 53 80 443 ];
      allowedUDPPorts = [ 53 67 ];
    };
    # networkmanager.enable = true;
  };

  users = {
    groups = {
      johnw = {};
    };
    users = {
      johnw = {
        uid = 1000;
        isNormalUser = true;
        description = "John Wiegley";
        group = "johnw";
        extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
        packages = with pkgs; [
        ];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAj2IzkXyXEl+ReCg9H+t55oa6GIiumPWeufcYCWy3F yubikey-gnupg"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAING2r8bns7h9vZIfZSGsX+YmTSe2Tv1X8f/Qlqo+RGBb yubikey-14476831-gnupg"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJD0sIKWWVF+zIWcNm/BfsbCQxuUBHD8nRNSpZV+mCf+ ShellFish@iPhone-28062024"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIZQeQ/gKkOwuwktwD4z0ZZ8tpxNej3qcHS5ZghRcdAd ShellFish@iPad-22062024"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPvP6nhCLyJLa2LsXLVYN1lbGHfv/ZL+Rt/y3Ao/hfGz Clio"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMeIfb6iRmTROLKVslU2R0U//dP9qze1fkJMhE9wWrSJ Athena"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO5RcpNe3ARxlVdeeAmoipizC03EM6HfZsfQ+sWjoPf5 Vulcan"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJmBoRIHfrT5RfCh1qyJP+aRwH6zpKJKv8KSk+1Rj8N0 Hera"
        ];
      };
    };
  };

  environment = {
    systemPackages = with pkgs; [
      git
      htop
      restic
      rsync
      tmux
      vim
      wget
    ];

    etc = {
      "sanoid/sanoid.conf".text = ''
        [tank]

        use_template = archival
        recursive = yes
        process_children_only = yes

        [template_archival]

        frequently = 0
        hourly = 96
        daily = 90
        weekly = 26
        monthly = 12
        yearly = 30

        autoprune = yes

        [tank/ChainState/kadena]

        use_template = production
        recursive = yes
        process_children_only = yes

        [template_production]

        frequently = 0
        hourly = 24
        daily = 14
        weekly = 4
        monthly = 3
        yearly = 0

        autoprune = yes
      '';
    };
  };

  programs = {
    mtr.enable = true;
  };

  services = {
    hardware.bolt.enable = true;

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    nginx = {
      enable = true;

      recommendedGzipSettings = true;
      recommendedProxySettings = true;

      virtualHosts = {
        smokeping.listen = [
          { addr = "0.0.0.0"; port = 8081; }
        ];

        "vulcan.local" = {
          forceSSL = false; # Optional, for HTTPS
          enableACME = false; # Optional, for automatic Let's Encrypt

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
              sub_filter_types text/html text/css text/javascript application/javascript;

              # Pass the Host header
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # Cookie handling
              proxy_cookie_path /admin/ /pi-hole/admin/;
            '';
          };
          locations."/api/" = {
            proxyPass = "http://127.0.0.1:8082/api/";
          };
          locations."/pi-hole" = {
            return = "301 /pi-hole/admin/";
          };
          locations."/pi-hole/" = {
            return = "301 /pi-hole/admin/";
          };

          locations."^~ /silly-tavern/" = {
            proxyPass = "http://127.0.0.1:8083/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_set_header Host $host;
              # proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_redirect off;
            '';
          };
          locations."= /silly-tavern" = {
            return = "301 /silly-tavern/";
          };
        };
      };
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
          path = "Backups/Misc";
          bucket = "Backups-Misc";
        }
        ;

    jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      user = "johnw";
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
