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
    html = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Send the report as multipart/alternative with an HTML part in which every
        referenced item links to its thread. The plain-text part is always sent
        and is unaffected.
      '';
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
        # NOT `toString cfg.html`, which emits the string "false" — truthy
        # under the codebase's bool(getenv) idiom. The explicit conditional is
        # unambiguous under either parser.
        OSS_SECRETARY_HTML = if cfg.html then "1" else "0";
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

        # Publish a read-only snapshot of the triage DB into the Hermes state share,
        # so the agent can answer ad-hoc questions ("what is awaiting my reply on
        # ledger?") without a forge token in the VM and without the GitHub/Gitea MCP
        # servers whose context cost got them deleted in 3af2dabfb.
        #
        # SNAPSHOT RATHER THAN SHARING THE LIVE FILE, deliberately. /var/lib/hermes is
        # already a read-write virtiofs share into the guest, so a snapshot placed here
        # needs no new microvm.shares entry -- worth avoiding, given how much of
        # hermes-vm.nix documents shares behaving unexpectedly. More importantly, a
        # reader inside the guest hitting the live file across virtiofs while this unit
        # writes it can see a torn read; `.backup` is SQLite's own online-backup API and
        # is safe against a database being written concurrently. (The DB is
        # journal_mode=delete, not WAL, so WAL-over-network is not the specific hazard
        # here -- but a snapshot removes the question entirely.)
        #
        # PREFIXES, both load-bearing. `+` runs this as root rather than oss-secretary
        # (the service user cannot write into hermes:hermes 0750, and widening either
        # directory to let it would be the wrong trade for a copy) and lifts the
        # sandboxing that would otherwise make /var/lib/hermes unwritable under
        # ProtectSystem=strict. `-` makes a non-zero exit non-fatal, so a snapshot
        # failure never fails the email run -- the report is the product, this is a
        # convenience view of it.
        #
        # NOT `|| true`: systemd Exec lines are not a shell, so that would be passed to
        # the script as two literal argv entries rather than acting as a fallback. The
        # script also ends in `exit 0` so the `-` is belt and braces.
        ExecStartPost = "-+${pkgs.writeShellScript "oss-secretary-snapshot" ''
          set -u
          dest=/var/lib/hermes/oss-secretary
          src=/var/lib/open-source-secretary/state.db
          [ -r "$src" ] || exit 0
          ${pkgs.coreutils}/bin/mkdir -p "$dest"
          if ${pkgs.sqlite}/bin/sqlite3 "$src" ".backup '$dest/state.db.tmp'"; then
            ${pkgs.coreutils}/bin/mv -f "$dest/state.db.tmp" "$dest/state.db"
            ${pkgs.coreutils}/bin/chown -R hermes:hermes "$dest"
            ${pkgs.coreutils}/bin/chmod 0640 "$dest/state.db"
          else
            echo "oss-secretary: snapshot failed; leaving previous snapshot in place" >&2
            ${pkgs.coreutils}/bin/rm -f "$dest/state.db.tmp"
          fi
          exit 0
        ''}";
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
