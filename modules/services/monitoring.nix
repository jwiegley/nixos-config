{ config, lib, pkgs, ... }:

let
  attrNameList = attrs:
    builtins.concatStringsSep " " (builtins.attrNames attrs);

  resticOperations = backups: pkgs.writeShellApplication {
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

  resticSnapshots = pkgs.writeShellApplication {
    name = "restic-snapshots";
    text = ''
      ${lib.getExe (resticOperations config.services.restic.backups)} snapshots
    '';
  };

  zfsSnapshotScript = pkgs.writeShellApplication {
    name = "logwatch-zfs-snapshot";
    text = ''
      for fs in $(${pkgs.zfs}/bin/zfs list -H -o name -t filesystem -r); do
        ${pkgs.zfs}/bin/zfs list -H -o name -t snapshot -S creation -d 1 "$fs" | ${pkgs.coreutils}/bin/head -1
      done
    '';
  };

  zpoolScript = pkgs.writeShellApplication {
    name = "logwatch-zpool";
    text = "${pkgs.zfs}/bin/zpool status";
  };

  systemctlFailedScript = pkgs.writeShellApplication {
    name = "logwatch-systemctl-failed";
    text = "${pkgs.systemd}/bin/systemctl --failed";
  };

  certificateValidationScript = pkgs.writeShellApplication {
    name = "logwatch-certificate-validation";
    runtimeInputs = with pkgs; [ bash openssl coreutils gawk gnugrep ];
    text = ''
      /etc/nixos/certs/validate-certificates-concise.sh || true
    '';
  };
in
{
  services = {
    logwatch = {
      enable = true;
      range = "since 24 hours ago for those hours";
      mailto = "johnw@newartisans.com";
      mailfrom = "johnw@newartisans.com";
      customServices = [
        {
          name = "systemctl-failed";
          title = "Failed systemctl services";
          script = lib.getExe systemctlFailedScript;
        }
        { name = "sshd"; }
        { name = "sudo"; }
        # { name = "fail2ban"; }
        { name = "kernel"; }
        { name = "audit"; }
        {
          name = "zpool";
          title = "ZFS Pool Status";
          script = lib.getExe zpoolScript;
        }
        {
          name = "restic";
          title = "Restic Snapshots";
          script = lib.getExe resticSnapshots;
        }
        {
          name = "zfs-snapshot";
          title = "ZFS Snapshots";
          script = lib.getExe zfsSnapshotScript;
        }
        {
          name = "certificate-validation";
          title = "Certificate Validation Report";
          script = lib.getExe certificateValidationScript;
        }
      ];
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
  };

  services.nginx.virtualHosts = {
    smokeping = {
      listen = [
        { addr = "127.0.0.1"; port = 8081; }
      ];
    };

    "smokeping.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/smokeping.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/smokeping.vulcan.lan.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8081/";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts =
    lib.mkIf config.services.smokeping.enable [ 8081 ];
}
