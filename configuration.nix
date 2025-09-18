{ config, lib, pkgs, ... }:

let
  attrNameList = attrs:
    builtins.concatStringsSep " " (builtins.attrNames attrs);

  restic-operations = backups: pkgs.writeShellApplication {
    name = "restic-operations";
    text = ''
      operation="''${1:-check}"
      shift || true

      for fileset in ${attrNameList backups} ; do
        echo "=== $fileset ==="
        case "$operation" in
          check)
            /run/current-system/sw/bin/restic-$fileset \
              --retry-lock=1h check
            /run/current-system/sw/bin/restic-$fileset \
              --retry-lock=1h prune
            /run/current-system/sw/bin/restic-$fileset \
              --retry-lock=1h repair snapshots
            ;;
          snapshots)
            /run/current-system/sw/bin/restic-$fileset snapshots --json | \
              ${pkgs.jq}/bin/jq -r \
                'sort_by(.time) | reverse | .[:4][] | .time'
            ;;
          *)
            echo "Unknown operation: $operation"
            exit 1
            ;;
        esac
      done
    '';
  };

in rec {
  system.stateVersion = "25.05";

  imports =
    [ ./hardware-configuration.nix
    ];

  nixpkgs.config = {
    allowUnfree = true;
  };

  boot = {
    loader = {
      systemd-boot.enable = false;
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
      };
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
    domain = "lan";

    hosts = {
      "127.0.0.2" = lib.mkForce [];
      "192.168.1.2" = [ "vulcan.lan" "vulcan" ];
    };

    interfaces.enp4s0 = {
      useDHCP = true;
    };

    firewall = {
      enable = true;
      allowedTCPPorts =
           [ 25 ]               # postfix
        ++ [ 80 ]               # nginx
        ++ [ 2022 ]             # eternal-terminal
        ++ [ 5432 ]             # postgres
        # ++ [ 5201 ]             # iperf
        ;
      allowedUDPPorts = [];
      interfaces.podman0.allowedUDPPorts = [];
    };
  };

  users = rec {
    groups = {
      johnw = {
        gid = 990;
      };
      container-data = {
        gid = 1010;
      };
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

        container-data = {
          isSystemUser = true;
          uid = 1010;
          group = "container-data";
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
      dh = pkgs.stdenv.mkDerivation rec {
        name = "dh-${version}";
        version = "1.0";

        src = pkgs.writeTextFile {
          name = "dh.sh";
          text = ''
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
        };

        dontUnpack = true;
        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/dh
          chmod +x $out/bin/dh
        '';

        meta = with lib; {
          description = "ZFS dataset helper - simplified zfs list command";
          license = licenses.mit;
          maintainers = with maintainers; [ jwiegley ];
        };
      };

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
      b3sum
      btop
      dh
      dig
      ethtool
      gitAndTools.git-lfs
      haskellPackages.sizes
      httm
      iperf3
      linkdups
      mailutils
      nettools
      python3
      socat
      traceroute
      zfs-prune-snapshots
    ];
  };

  programs = {
    git.enable = true;
    htop.enable = true;
    tmux.enable = true;
    vim.enable = true;

    # nix-ld = {
    #   enable = true;
    #   libraries = with pkgs; [
    #     nodejs
    #   ];
    # };
  };

  systemd = {
    tmpfiles.rules = [
      # Wallabag
      "d /var/lib/wallabag 0755 container-data container-data -"
      "d /var/lib/wallabag/data 0755 container-data container-data -"
      "d /var/lib/wallabag/images 0755 container-data container-data -"

      # SillyTavern
      "d /var/lib/silly-tavern 0755 container-data container-data -"
      "d /var/lib/silly-tavern/config 0755 container-data container-data -"
      "d /var/lib/silly-tavern/data 0755 container-data container-data -"
      "d /var/lib/silly-tavern/plugins 0755 container-data container-data -"
      "d /var/lib/silly-tavern/extensions 0755 container-data container-data -"

      # Organizr
      "d /var/lib/organizr 0755 container-data container-data -"
    ];

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

    services.backup-chainweb = {
      description = "Backup Chainweb databases";
      path = with pkgs; [
        rsync
        openssh
      ];
      serviceConfig = {
        User = "root";
        Group = "root";
        ExecStart = "/home/johnw/bin/backup-chainweb";
      };
    };

    timers.backup-chainweb = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Unit = "backup-chainweb.service";
      };
    };

    services.restic-check = {
      description = "Run restic check on backup repository";
      serviceConfig = {
        ExecStart = "${lib.getExe (restic-operations services.restic.backups)} check";
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

    services.update-containers = {
      description = "Update and restart Podman containers";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          updateScript = pkgs.writeShellScript "update-containers" ''
            set -euo pipefail

            export PATH=${pkgs.iptables}/bin:$PATH

            # Function to log with timestamp
            log() {
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
            }

            log "Starting container update process"

            # Get unique images from all containers
            images=$(${pkgs.podman}/bin/podman ps -a --format='{{.Image}}' | sort -u)

            if [ -z "$images" ]; then
              log "No containers found"
              exit 0
            fi

            # Track which images were updated
            updated_images=""

            # Pull each image and track updates
            while IFS= read -r image; do
              [ -z "$image" ] && continue

              log "Checking image: $image"

              # Capture the pull output to detect if image was updated
              if output=$(${pkgs.podman}/bin/podman pull "$image" 2>&1); then
                if echo "$output" | grep -q "Downloading\|Copying\|Getting image"; then
                  log "Updated: $image"
                  updated_images="$updated_images $image"
                else
                  log "Already up-to-date: $image"
                fi
              else
                log "ERROR: Failed to pull $image"
                # Continue with other images even if one fails
              fi
            done <<< "$images"

            # Only restart containers with updated images
            if [ -n "$updated_images" ]; then
              log "Restarting containers with updated images..."

              for image in $updated_images; do
                # Find containers using this image
                containers=$(${pkgs.podman}/bin/podman ps -a --filter "ancestor=$image" --format='{{.ID}}')

                if [ -n "$containers" ]; then
                  while IFS= read -r container; do
                    [ -z "$container" ] && continue

                    # Get container name for logging
                    name=$(${pkgs.podman}/bin/podman ps -a --filter "id=$container" --format='{{.Names}}')

                    if ${pkgs.podman}/bin/podman restart "$container" >/dev/null 2>&1; then
                      log "Restarted container: $name ($container)"
                    else
                      log "ERROR: Failed to restart container: $name ($container)"
                    fi
                  done <<< "$containers"
                fi
              done
            else
              log "No updates found, skipping container restarts"
            fi

            log "Container update process completed"
          '';
        in "${updateScript}";

        # Run as root or specify a user if needed
        User = "root";

        # Ensure proper cleanup on failure
        RemainAfterExit = false;

        # Resource limits
        TimeoutStartSec = "10m";

        # Logging
        StandardOutput = "journal";
        StandardError = "journal";
      };

      # Dependencies
      after = [ "network-online.target" "podman.service" ];
      wants = [ "network-online.target" ];
    };

    # Optional: Create a timer for automatic updates
    timers.update-containers = {
      description = "Timer for updating Podman containers";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run daily at 3 AM
        OnCalendar = "daily";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
    };
  };

  services = rec {
    hardware.bolt.enable = true;

    eternal-terminal.enable = true;

    redis.servers."litellm" = {
      enable = true;
      port = 8085;
      settings = {
        "aclfile" = "/etc/redis/users.acl";
      };
    };

    fail2ban = {
      enable = false;

      jails.sshd.settings = {
        enabled = true;
        maxretry = 10;        # Allow up to 10 failed attempts
        findtime = 3600;      # Count failures within an hour (3600 seconds)
        bantime = "24h";      # Ban for one day
        backend = "systemd";  # Use systemd journal (works best on NixOS)
      };
    };

    postfix = {
      enable = true;
      settings = {
        main = {
          mynetworks = [
            "192.168.1.0/24"
            "10.6.0.0/24"
            "127.0.0.0/8"
          ];
          relayhost = [ "[smtp.fastmail.com]:587" ];
          smtp_use_tls = "yes";
          smtp_sasl_auth_enable = "yes";
          smtp_sasl_security_options = "";
          smtp_sasl_password_maps = "texthash:/secrets/postfix_sasl";
        };
      };
    };

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "yes";
      };
    };

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
          { addr = "127.0.0.1"; port = 8081; }
        ];

        "vulcan" = {
          serverAliases = [ "vulcan.lan" ];

          # forceSSL = true;      # Optional, for HTTPS
          # sslCertificate = "/etc/ssl/certs/vulcan.local.crt";
          # sslCertificateKey = "/etc/ssl/private/vulcan.local.key";

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

          locations."/wallabag/" = {
            proxyPass = "http://127.0.0.1:9090/";
          };
          locations."/wallabag" = {
            return = "301 /wallabag/";
          };

          locations."/jellyfin/" = {
            proxyPass = "http://127.0.0.1:8096/jellyfin/";
            proxyWebsockets = true;
          };
          locations."/jellyfin" = {
            return = "301 /jellyfin/";
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

              sub_filter '="/litellm/litellm' '="/litellm';
              sub_filter_once off;
              sub_filter_types text/css text/javascript application/javascript;
            '';
          };
          locations."/litellm/litellm/ui/" = {
            return = "301 /litellm/ui/";
          };

          locations."/" = {
            proxyPass = "http://127.0.0.1:8080/";
          };
        };
      };
    };

    logwatch =
      let
        restic-snapshots = pkgs.writeShellApplication {
          name = "restic-snapshots";
          text = ''
            ${lib.getExe (restic-operations services.restic.backups)} snapshots
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
            script = "${lib.getExe restic-snapshots}"; }
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
          hourly = 24;
          daily = 30;
          weekly = 8;
          monthly = 12;
          yearly = 5;
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
            ".cabal"
            ".cache"
            ".cargo"
            ".coq-native"
            ".ghc"
            ".ghc.*"
            ".lia.cache"
            ".local/share/vagrant"
            ".lra.cache"
            ".nia.cache"
            ".nra.cache"
            ".slocdata"
            ".vagrant"
            ".venv"
            "MAlonzo"
            "dist"
            "dist-newstyle"
            "node_modules"
            "result"
            "result-*"
            "target"
          ];
        } //
        backup {
          path = "Home";
          exclude = [
            ".cache"
            "Library/Application Support/Bookmap/Cache"
            "Library/Application Support/CloudDocs"
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
        host all all 10.88.0.0/16 trust
        host all all 192.168.1.0/24 md5
        host all all 10.6.0.0/16 md5
        host all all ::1/128 md5
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
  };

  virtualisation = {
    podman = {
      enable = true;
      autoPrune = {
        enable = true;
        flags = [ "--all" ];
      };
    };

    oci-containers = {
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

        organizr = {
          autoStart = true;
          image = "ghcr.io/organizr/organizr:latest";
          ports = [
            "8080:80/tcp"
          ];
          environment = {
            PUID = "1010";
            PGID = "1010";
          };
          volumes = [
            "/var/lib/organizr:/config"
          ];
          extraOptions = [];
        };

        wallabag = {
          autoStart = true;
          image = "wallabag/wallabag:latest";
          ports = [
            "9090:80/tcp"
          ];
          environment = {
            PUID = "1010";
            PGID = "1010";
            SYMFONY__ENV__DOMAIN_NAME = "http://vulcan.lan/wallabag";
          };
          volumes = [
            "/var/lib/wallabag/data:/var/www/wallabag/data"
            "/var/lib/wallabag/images:/var/www/wallabag/web/assets/images"
          ];
          extraOptions = [];
        };
      };
    };
  };

  # system.activationScripts.consoleBlank = ''
  #   echo "Setting up console blanking..."
  #   ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 > /dev/tty1
  # '';
}
