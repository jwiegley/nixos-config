{
  config,
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  mcporterPkg = inputs.llm-agents.packages.${system}.mcporter;

  reportScript = pkgs.writers.writePython3Bin "openclaw-nightly-report" {
    flakeIgnore = [
      "E501" # ASCII tables push some lines past 79 chars
      "W503"
      "E265" # shebang flagged as non-conforming block comment
      "E203" # whitespace before ':' (Black-style slicing)
    ];
  } (builtins.readFile ../../scripts/openclaw-nightly-report.py);

  recipient = "johnw@vulcan.lan";
  sender = "openclaw-health@vulcan.lan";

  # 06:00 local time daily. Persistent so a reboot doesn't drop the run
  # for the day; RandomizedDelaySec adds a small jitter.
  schedule = "*-*-* 06:00:00";
in
{
  sops.secrets."openclaw/probe-ssh-private-key" = {
    mode = "0400";
    owner = "root";
    group = "root";
  };

  systemd.services.openclaw-nightly-report = {
    description = "Aggregate OpenClaw health and email a nightly report";
    after = [
      "openclaw-mcporter-check.service"
      "postfix.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      systemd # systemctl show
      coreutils
      mcporterPkg # so shutil.which("mcporter") in PATH resolves cleanly
      openssh # for the in-VM mcporter probe over SSH
    ];

    environment = {
      OPENCLAW_REPORT_TO = recipient;
      OPENCLAW_REPORT_FROM = sender;
      OPENCLAW_REPORT_SENDMAIL = "/run/wrappers/bin/sendmail";
      # Pin mcporter explicitly so we never depend on PATH lookup or
      # /nix/store globbing — the latter has bitten us when the readable
      # set under sandbox didn't include the expected store paths.
      OPENCLAW_REPORT_MCPORTER = "${mcporterPkg}/bin/mcporter";
      # In-VM probe for HOST_BLIND_SERVERS (drafts, google-calendar-*,
      # home-assistant). SSH key is delivered via LoadCredential below;
      # %d expands to $CREDENTIALS_DIRECTORY at runtime.
      OPENCLAW_REPORT_SSH_KEY = "%d/probe-ssh-key";
      OPENCLAW_REPORT_SSH_TARGET = "openclaw@10.99.0.2";
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${reportScript}/bin/openclaw-nightly-report";

      # Sandbox tightly — the script only reads metric files and runs
      # mcporter list / systemctl show; it must also pipe to sendmail.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        # Postfix sendmail calls getifaddrs() at startup, which on Linux
        # uses AF_NETLINK; without it the wrapper exits 75/TEMPFAIL.
        "AF_NETLINK"
        "AF_PACKET"
      ];
      # Sendmail (setgid postdrop wrapper) writes into postfix's maildrop
      # queue. NixOS puts the queue under /var/lib/postfix/queue, not
      # /var/spool/postfix; whitelisting the parent is enough so the
      # wrapper can resolve and chdir into the maildrop subdir.
      ReadWritePaths = [
        "/var/lib/postfix/queue"
      ];
      ReadOnlyPaths = [
        "/var/lib/openclaw"
        "/var/lib/prometheus-node-exporter-textfiles"
        "/etc/nixos/certs"
        "/etc/ssl"
      ];
      LoadCredential = [
        "probe-ssh-key:${config.sops.secrets."openclaw/probe-ssh-private-key".path}"
      ];

      TimeoutStartSec = "5min";
    };
  };

  systemd.timers.openclaw-nightly-report = {
    description = "Run OpenClaw nightly health report at 06:00";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = schedule;
      Persistent = true;
      RandomizedDelaySec = "5min";
      AccuracySec = "1min";
      Unit = "openclaw-nightly-report.service";
    };
  };
}
