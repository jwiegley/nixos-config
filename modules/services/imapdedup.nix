{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Copy the imapdedup.py Python script to the Nix store
  imapdedupPython = pkgs.runCommand "imapdedup-python" { } ''
    mkdir -p $out/bin
    cp ${../../scripts/imapdedup.py} $out/bin/imapdedup.py
    chmod +x $out/bin/imapdedup.py
  '';

  # Wrapper script that calls imapdedup with proper dovecot path
  imapdedupScript = pkgs.writeShellScript "imapdedup" ''
    set -euo pipefail

    # Function to deduplicate mailboxes
    function dedup_mailboxes() {
        ${pkgs.python3}/bin/python3 ${imapdedupPython}/bin/imapdedup.py \
                -P "${pkgs.dovecot}/libexec/dovecot/imap -c /etc/dovecot/dovecot.conf" \
                -u johnw                                \
                -c                                      \
                -m                                      \
                "$@"
    }

    # Default mailbox list if no arguments provided
    if [[ -n "''${1:-}" ]]; then
        dedup_mailboxes "$@"
    else
        dedup_mailboxes                   \
            list/ledger                   \
            list/haskell/infrastructure   \
            list/haskell/hackage-trustees \
            list/haskell/admin            \
            list/emacs/org-mode           \
            list/emacs/devel              \
            list/emacs/tangents           \
            list/bahai/tarjuman           \
            list/bahai/c2g                \
            list/bahai/assembly           \
            list/bahai/andf               \
            list/bahai                    \
            list/vulcan                   \
            list/notifications            \
            list/misc                     \
            list/github                   \
            mail/quantum                  \
            Archive                       \
            INBOX                         \
            Sent                          \
            Spam                          \
            Trash
    fi
  '';
in
{
  # Systemd service to run imapdedup
  systemd.services.imapdedup = {
    description = "IMAP mailbox deduplication for johnw";
    after = [ "dovecot2.service" ];
    requires = [ "dovecot2.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "johnw";
      Group = "users";

      # Run the wrapper script
      ExecStart = "${imapdedupScript}";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      NoNewPrivileges = true;

      # Need access to dovecot socket and mail directories
      ReadWritePaths = [
        "/var/mail/johnw"
      ];
      ReadOnlyPaths = [
        "/run/dovecot2"
        "/etc/dovecot"
      ];

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Systemd timer to run weekly
  systemd.timers.imapdedup = {
    description = "Weekly timer for IMAP deduplication";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
