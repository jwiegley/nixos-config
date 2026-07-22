{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-source-secretary;
  pkg = pkgs.callPackage ../../pkgs/open-source-secretary { };
in
{
  options.services.open-source-secretary = {
    enable = lib.mkEnableOption "daily GitHub/Gitea issue+PR triage report";
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 07:00:00";
      description = "systemd OnCalendar expression for the daily run.";
    };
    recipient = lib.mkOption {
      type = lib.types.str;
      default = "johnw@vulcan.lan";
      description = "Email address the report is sent to.";
    };
    includePrivate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include private repositories in the scan.";
    };
    llmTokenBudget = lib.mkOption {
      type = lib.types.int;
      default = 12000;
      description = "Approximate token budget for the Hermes triage prompt.";
    };
    staleDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Age in days after which an open thread is flagged stale.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."open-source-secretary/github-token" = {
      mode = "0400";
      owner = "root";
      group = "root";
    };
    sops.secrets."open-source-secretary/gitea-token" = {
      mode = "0400";
      owner = "root";
      group = "root";
    };
    # hermes/env is declared (and its content managed) by hermes-microvm.nix
    # (hermes-mcp.nix only appends restartUnits to it); we read its decrypted
    # path via LoadCredential below and parse API_SERVER_KEY out of it — never
    # redeclare the secret content here. vulcan always imports hermes-microvm.nix.

    # Dedicated static system user. NOT DynamicUser: sending mail requires the
    # setgid-postdrop sendmail wrapper to take effect (see serviceConfig), and
    # DynamicUser forces RestrictSUIDSGID=yes which neutralizes the setgid bit.
    users.users.oss-secretary = {
      isSystemUser = true;
      group = "oss-secretary";
      description = "open-source-secretary daily report";
    };
    users.groups.oss-secretary = { };

    systemd.services.open-source-secretary = {
      description = "Daily GitHub/Gitea issue+PR triage report (Hermes-assisted)";
      after = [
        "network-online.target"
        "postfix.service"
      ];
      wants = [ "network-online.target" ];

      path = with pkgs; [ coreutils ];

      environment = {
        OSS_SECRETARY_TO = cfg.recipient;
        OSS_SECRETARY_FROM = "oss-secretary@vulcan.lan";
        OSS_SECRETARY_SENDMAIL = "/run/wrappers/bin/sendmail";
        OSS_SECRETARY_STATE_DB = "/var/lib/open-source-secretary/state.db";
        OSS_SECRETARY_GITHUB_TOKEN_FILE = "%d/github-token";
        OSS_SECRETARY_GITEA_TOKEN_FILE = "%d/gitea-token";
        OSS_SECRETARY_HERMES_ENV_FILE = "%d/hermes-env";
        OSS_SECRETARY_INCLUDE_PRIVATE = lib.optionalString cfg.includePrivate "1";
        OSS_SECRETARY_LLM_TOKEN_BUDGET = toString cfg.llmTokenBudget;
        OSS_SECRETARY_STALE_DAYS = toString cfg.staleDays;
        REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "oss-secretary";
        Group = "oss-secretary";
        StateDirectory = "open-source-secretary";
        StateDirectoryMode = "0700";
        ExecStart = "${pkg}/bin/oss-secretary";
        # LoadCredential copies each root:0400 secret into $CREDENTIALS_DIRECTORY
        # readable by the (non-root) service user — the correct way to hand a
        # root-owned secret to an unprivileged unit.
        LoadCredential = [
          "github-token:${config.sops.secrets."open-source-secretary/github-token".path}"
          "gitea-token:${config.sops.secrets."open-source-secretary/gitea-token".path}"
          "hermes-env:${config.sops.secrets."hermes/env".path}"
        ];

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        # NoNewPrivileges MUST stay false and RestrictSUIDSGID false: the report
        # shells out to /run/wrappers/bin/sendmail, which is setgid `postdrop`,
        # and postdrop needs that setgid to write postfix's 0730 maildrop queue.
        # With NNP=true (or RestrictSUIDSGID=true, which DynamicUser forces) the
        # kernel ignores the setgid bit → EACCES → the sendmail chain HANGS until
        # TimeoutStartSec. This mirrors flume-data.nix (the repo's proven
        # unprivileged mail-sender); hermes-nightly-report keeps NNP=true only
        # because it runs as root.
        NoNewPrivileges = false;
        RestrictSUIDSGID = false;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        MemoryDenyWriteExecute = false; # CPython needs W^X off
        # AF_NETLINK is load-bearing: postfix sendmail calls getifaddrs().
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_PACKET"
        ];
        # Sendmail (setgid postdrop wrapper) writes into postfix's maildrop
        # queue.
        ReadWritePaths = [ "/var/lib/postfix/queue" ];
        # SystemCallFilter intentionally omitted: not in the spec's hardening
        # set, and an untested filter risks breaking the setgid sendmail path,
        # which can't be verified until secrets are provisioned + switched.

        TimeoutStartSec = "20min";
      };
    };

    systemd.timers.open-source-secretary = {
      description = "Run the open-source secretary daily";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "10min";
        AccuracySec = "1min";
        Unit = "open-source-secretary.service";
      };
    };
  };
}
