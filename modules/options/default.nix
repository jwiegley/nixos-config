{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.vulcan;
in
{
  options.vulcan = {
    # Global enable flag
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable vulcan-specific configuration modules";
    };

    # Monitoring configuration
    monitoring = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable monitoring stack (Prometheus, exporters, alerts)";
      };

      alerting = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable Prometheus alerting rules";
        };

        customRulesFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to custom alert rules YAML file";
        };

        emailNotifications = mkOption {
          type = types.bool;
          default = false;
          description = "Enable email notifications for alerts";
        };
      };

      retention = mkOption {
        type = types.str;
        default = "100y";
        description = "How long to retain metrics data";
      };

      scrapeInterval = mkOption {
        type = types.str;
        default = "15s";
        description = "Default scrape interval for Prometheus";
      };
    };

    # Mail synchronization configuration
    mail = {
      mbsync = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable mbsync mail synchronization";
        };

        users = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Enable mbsync for this user";
                };

                interval = mkOption {
                  type = types.str;
                  default = "15min";
                  description = "Sync interval";
                };

                remoteHost = mkOption {
                  type = types.str;
                  description = "Remote IMAP server hostname";
                };

                remoteUser = mkOption {
                  type = types.str;
                  description = "Remote IMAP username";
                };

                secretName = mkOption {
                  type = types.str;
                  description = "Name of SOPS secret containing password";
                };

                patterns = mkOption {
                  type = types.listOf types.str;
                  default = [ "*" ];
                  description = "Folder patterns to sync";
                };
              };
            }
          );
          default = { };
          description = "mbsync user configurations";
        };
      };

      dovecot = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable Dovecot IMAP server";
        };

        mailLocation = mkOption {
          type = types.str;
          default = "maildir:/var/mail/%u";
          description = "Mail storage location";
        };
      };
    };

    # Backup configuration
    backups = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Restic backup system";
      };

      repository = mkOption {
        type = types.str;
        default = "s3:s3.us-west-001.backblazeb2.com";
        description = "Base repository URL for backups";
      };

      schedule = mkOption {
        type = types.str;
        default = "*-*-* 02:00:00";
        description = "Default backup schedule (systemd calendar format)";
      };

      retention = {
        daily = mkOption {
          type = types.int;
          default = 7;
          description = "Number of daily backups to keep";
        };

        weekly = mkOption {
          type = types.int;
          default = 5;
          description = "Number of weekly backups to keep";
        };

        yearly = mkOption {
          type = types.int;
          default = 3;
          description = "Number of yearly backups to keep";
        };
      };

      datasets = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of ZFS datasets to backup";
      };
    };

    # Certificate management
    certificates = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable certificate management";
      };

      provider = mkOption {
        type = types.enum [
          "step-ca"
          "letsencrypt"
          "self-signed"
        ];
        default = "step-ca";
        description = "Certificate provider to use";
      };

      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of domains to manage certificates for";
      };

      renewalInterval = mkOption {
        type = types.str;
        default = "daily";
        description = "Certificate renewal check interval";
      };
    };

    # Container configuration
    containers = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable container support";
      };

      runtime = mkOption {
        type = types.enum [
          "podman"
          "docker"
        ];
        default = "podman";
        description = "Container runtime to use";
      };

      networkBridge = mkOption {
        type = types.str;
        default = "podman0";
        description = "Network bridge for containers";
      };

      autoUpdate = mkOption {
        type = types.bool;
        default = false;
        description = "Enable automatic container image updates";
      };
    };

    # Storage configuration
    storage = {
      zfs = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable ZFS storage management";
        };

        autoSnapshot = mkOption {
          type = types.bool;
          default = true;
          description = "Enable automatic ZFS snapshots";
        };

        snapshotSchedule = {
          frequent = mkOption {
            type = types.int;
            default = 4;
            description = "Number of frequent snapshots to keep (15min interval)";
          };

          hourly = mkOption {
            type = types.int;
            default = 24;
            description = "Number of hourly snapshots to keep";
          };

          daily = mkOption {
            type = types.int;
            default = 7;
            description = "Number of daily snapshots to keep";
          };

          weekly = mkOption {
            type = types.int;
            default = 4;
            description = "Number of weekly snapshots to keep";
          };
        };

        scrubSchedule = mkOption {
          type = types.str;
          default = "Sun *-*-1..7 02:00:00";
          description = "ZFS scrub schedule (first Sunday of month at 2am)";
        };
      };
    };

    # Service reliability features
    reliability = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable service reliability features";
      };

      autoRestart = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically restart failed services";
      };

      healthChecks = mkOption {
        type = types.bool;
        default = true;
        description = "Enable service health checks";
      };

      healthCheckInterval = mkOption {
        type = types.str;
        default = "30min";
        description = "Default health check interval";
      };
    };
  };

  config = mkIf cfg.enable {
    # Apply configuration based on options
    assertions = [
      {
        assertion = cfg.mail.mbsync.enable -> cfg.mail.dovecot.enable;
        message = "mbsync requires dovecot to be enabled";
      }
      {
        assertion = cfg.monitoring.alerting.enable -> cfg.monitoring.enable;
        message = "Alerting requires monitoring to be enabled";
      }
    ];

    # Set up monitoring if enabled
    services.prometheus = mkIf cfg.monitoring.enable {
      enable = true;
      retentionTime = cfg.monitoring.retention;
      globalConfig.scrape_interval = cfg.monitoring.scrapeInterval;
    };

    # Configure backups if enabled
    services.restic.backups = mkIf cfg.backups.enable (
      lib.listToAttrs (
        map (dataset: {
          name = "zfs-${lib.replaceStrings [ "/" ] [ "-" ] dataset}";
          value = {
            paths = [ "/tank/${dataset}" ];
            repository = "${cfg.backups.repository}/jwiegley-${dataset}";
            timerConfig.OnCalendar = cfg.backups.schedule;
            pruneOpts = [
              "--keep-daily ${toString cfg.backups.retention.daily}"
              "--keep-weekly ${toString cfg.backups.retention.weekly}"
              "--keep-yearly ${toString cfg.backups.retention.yearly}"
            ];
          };
        }) cfg.backups.datasets
      )
    );

    # Container runtime setup
    virtualisation = mkIf cfg.containers.enable (
      if cfg.containers.runtime == "podman" then
        {
          podman.enable = true;
          podman.dockerCompat = true;
        }
      else
        {
          docker.enable = true;
        }
    );
  };
}
