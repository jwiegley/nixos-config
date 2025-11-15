{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "mailarchiver";
      image = "docker.io/s1t5/mailarchiver:latest";
      port = 9097;
      requiresPostgres = true;
      containerUser = "mailarchiver";  # Run rootless as dedicated mailarchiver user

      # Disabled - Podman healthchecks cause cgroup permission errors with rootless containers
      # External monitoring via Prometheus/blackbox exporter is used instead
      healthCheck = {
        enable = false;
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      secrets = {
        mailarchiver-env = "mailarchiver-env";
      };

      environments = {
        # Application configuration
        APP_URL = "https://mailarchiver.vulcan.lan";

        # Timezone configuration (IANA timezone identifier)
        TimeZone__DisplayTimeZoneId = "America/Los_Angeles";

        # Mail configuration (using local Postfix)
        MAIL_HOST = "10.88.0.1";
        MAIL_PORT = "25";
        MAIL_FROM_ADDRESS = "mailarchiver@vulcan.lan";

        # Accept Step-CA self-signed certificates for IMAP connections
        MailSync__IgnoreSelfSignedCert = "true";

        # Logging level
        Logging__LogLevel__Default = "Information";
        Logging__LogLevel__Microsoft_AspNetCore = "Warning";

        # Database connection string (without password - password comes from secret file)
        # Note: The complete connection string with password is in the secret file
      };

      publishPorts = [ "127.0.0.1:9097:5000/tcp" ];

      volumes = [
        "/var/lib/mailarchiver/storage:/app/DataProtection-Keys:rw"
        "/var/lib/mailarchiver/logs:/app/logs:rw"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:9097/";
        extraConfig = ''
          # Mail archiver can handle large email attachments
          proxy_buffering off;
          client_max_body_size 500M;
          proxy_read_timeout 10m;
          proxy_connect_timeout 2m;
          proxy_send_timeout 10m;

          # Standard proxy headers
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Real-IP $remote_addr;
        '';
      };

      tmpfilesRules = [
        "d /var/lib/mailarchiver 0755 mailarchiver mailarchiver -"
        "d /var/lib/mailarchiver/.config 0700 mailarchiver mailarchiver -"
        "d /var/lib/mailarchiver/.local 0755 mailarchiver mailarchiver -"
        "d /var/lib/mailarchiver/storage 0755 mailarchiver mailarchiver -"
        "d /var/lib/mailarchiver/logs 0755 mailarchiver mailarchiver -"
      ];
    })
  ];

  # Create dedicated user for rootless container
  users.users.mailarchiver = {
    isSystemUser = true;
    group = "mailarchiver";
    description = "Mail Archiver service user";
    home = "/var/lib/mailarchiver";
    createHome = true;
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };

  users.groups.mailarchiver = {};

  # Note: SOPS secrets are automatically configured by mkQuadletService
  # The mailarchiver-env file should contain (in KEY=VALUE format):
  #   ConnectionStrings__DefaultConnection=Host=10.88.0.1;Port=5432;Database=mailarchiver;Username=mailarchiver;Password=<db-password>
  #   Authentication__Username=<admin-username>
  #   Authentication__Password=<admin-password>

  # Additional SOPS secret for PostgreSQL user setup
  sops.secrets."mailarchiver-db-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    9097  # mailarchiver
  ];

  # Mail Archiver - Email Archiving and Search Platform
  # ====================================================
  # Mail-archiver is an open-source web application for archiving, searching,
  # and exporting emails from multiple accounts.
  #
  # Features:
  # - Automatic email archiving with scheduled synchronization
  # - Advanced search with filtering capabilities
  # - Export emails as mbox files or zipped EML archives
  # - Import emails from other sources
  # - Retention policy management
  # - Support for IMAP and Microsoft Graph API (M365)
  #
  # Access: https://mailarchiver.vulcan.lan
}
