{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Shared engine — built identically in openclaw-nightly-report.nix (same
  # name, source, and flakeIgnore → Nix dedupes to one derivation). Invoked
  # with `--agent hermes` below.
  reportScript = pkgs.writers.writePython3Bin "agent-health-report" {
    flakeIgnore = [
      "E501" # ASCII tables push some lines past 79 chars
      "W503"
      "E265" # shebang flagged as non-conforming block comment
      "E203" # whitespace before ':' (Black-style slicing)
      "E241" # multiple spaces after ':' (aligned dict/profile literals)
      "E226" # missing whitespace around arithmetic operator
    ];
  } (builtins.readFile ../../scripts/agent_health_report.py);

  recipient = "johnw@vulcan.lan";
  sender = "hermes-health@vulcan.lan";

  # 06:15 local time daily — 15 min after openclaw so the two emails
  # don't land in the same minute.
  schedule = "*-*-* 06:15:00";
in
{
  # SSH probe key for the optional in-VM corroboration step.
  # The same key is authorized on the Hermes VM under user `hermes`
  # as `claude-hermes-debug`. Mode 0400 owner root — LoadCredential
  # plumbs it into $CREDENTIALS_DIRECTORY for the unit.
  sops.secrets."hermes/probe-ssh-private-key" = {
    mode = "0400";
    owner = "root";
    group = "root";
  };

  systemd.services.hermes-nightly-report = {
    description = "Aggregate Hermes health and email a nightly report";
    after = [
      "hermes-health-check.service"
      "postfix.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      systemd
      coreutils
      openssh
    ];

    environment = {
      HERMES_REPORT_TO = recipient;
      HERMES_REPORT_FROM = sender;
      HERMES_REPORT_SENDMAIL = "/run/wrappers/bin/sendmail";
      HERMES_REPORT_SSH_KEY = "%d/probe-ssh-key";
      HERMES_REPORT_SSH_TARGET = "hermes@10.99.1.2";
      HERMES_REPORT_PROMETHEUS_URL = "http://127.0.0.1:9090";
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${reportScript}/bin/agent-health-report --agent hermes";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        # Postfix sendmail calls getifaddrs() at startup; AF_NETLINK
        # is required or sendmail returns 75/TEMPFAIL.
        "AF_NETLINK"
        "AF_PACKET"
      ];
      # Sendmail (setgid postdrop wrapper) writes into postfix's maildrop
      # queue.
      ReadWritePaths = [
        "/var/lib/postfix/queue"
      ];
      ReadOnlyPaths = [
        "/var/lib/hermes"
        "/var/lib/hermes-self-heal"
        "/var/lib/prometheus-node-exporter-textfiles"
        "/etc/nixos/certs"
        "/etc/ssl"
      ];
      LoadCredential = [
        "probe-ssh-key:${config.sops.secrets."hermes/probe-ssh-private-key".path}"
      ];

      TimeoutStartSec = "5min";
    };
  };

  systemd.timers.hermes-nightly-report = {
    description = "Run Hermes nightly health report at 06:15";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = schedule;
      Persistent = true;
      RandomizedDelaySec = "5min";
      AccuracySec = "1min";
      Unit = "hermes-nightly-report.service";
    };
  };
}
