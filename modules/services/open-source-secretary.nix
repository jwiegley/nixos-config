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
    # hermes/env is declared (and its content managed) by hermes-mcp.nix;
    # we only read its decrypted path via LoadCredential below — never
    # redeclare the secret content here.

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
        DynamicUser = true;
        StateDirectory = "open-source-secretary";
        StateDirectoryMode = "0700";
        ExecStart = "${pkg}/bin/oss-secretary";
        LoadCredential = [
          "github-token:${config.sops.secrets."open-source-secretary/github-token".path}"
          "gitea-token:${config.sops.secrets."open-source-secretary/gitea-token".path}"
          "hermes-env:${config.sops.secrets."hermes/env".path}"
        ];

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
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
