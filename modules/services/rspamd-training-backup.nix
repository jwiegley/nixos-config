{ config, lib, pkgs, ... }:

let
  # Helper script to train messages that didn't get auto-processed
  trainingBackupScript = pkgs.writeShellScript "rspamd-training-backup" ''
    set -euo pipefail

    # Configuration
    USERS=("johnw" "assembly")
    MAIL_ROOT="/var/mail"
    RSPAMC="${pkgs.rspamd}/bin/rspamc"

    # Counters
    SPAM_TRAINED=0
    HAM_TRAINED=0

    echo "Starting backup training check..."

    # Function to train spam messages in TrainSpam folder
    train_spam() {
      local user=$1
      local trainspam_dir="$MAIL_ROOT/$user/.TrainSpam/cur"

      if [ ! -d "$trainspam_dir" ]; then
        return
      fi

      local count=0
      for msg in "$trainspam_dir"/*; do
        if [ -f "$msg" ]; then
          # Train as spam
          if $RSPAMC learn_spam < "$msg" >/dev/null 2>&1; then
            # Move to IsSpam folder
            local isspam_dir="$MAIL_ROOT/$user/.IsSpam/cur"
            mkdir -p "$isspam_dir"
            mv "$msg" "$isspam_dir/"
            count=$((count + 1))
            SPAM_TRAINED=$((SPAM_TRAINED + 1))
          fi
        fi
      done

      if [ $count -gt 0 ]; then
        echo "  Trained $count spam messages for $user"
      fi
    }

    # Function to train ham messages in TrainGood folder
    train_ham() {
      local user=$1
      local traingood_dir="$MAIL_ROOT/$user/.TrainGood/cur"

      if [ ! -d "$traingood_dir" ]; then
        return
      fi

      local count=0
      for msg in "$traingood_dir"/*; do
        if [ -f "$msg" ]; then
          # Train as ham
          if $RSPAMC learn_ham < "$msg" >/dev/null 2>&1; then
            # Move to IsGood folder
            local isgood_dir="$MAIL_ROOT/$user/.IsGood/cur"
            mkdir -p "$isgood_dir"
            mv "$msg" "$isgood_dir/"
            count=$((count + 1))
            HAM_TRAINED=$((HAM_TRAINED + 1))
          fi
        fi
      done

      if [ $count -gt 0 ]; then
        echo "  Trained $count ham messages for $user"
      fi
    }

    # Process each user
    for user in "''${USERS[@]}"; do
      if [ -d "$MAIL_ROOT/$user" ]; then
        train_spam "$user"
        train_ham "$user"
      fi
    done

    # Summary
    if [ $SPAM_TRAINED -gt 0 ] || [ $HAM_TRAINED -gt 0 ]; then
      echo "Backup training complete: $SPAM_TRAINED spam, $HAM_TRAINED ham"
    else
      echo "No messages to train (all folders empty)"
    fi
  '';
in
{
  # Systemd service to train messages that weren't auto-processed
  systemd.services.rspamd-training-backup = {
    description = "Rspamd Backup Training Service";
    after = [ "rspamd.service" ];
    wants = [ "rspamd.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${trainingBackupScript}";
      User = "root";  # Need root to access /var/mail directories
      Group = "root";
    };
  };

  # Timer to run backup training every 15 minutes
  systemd.timers.rspamd-training-backup = {
    description = "Timer for Rspamd backup training";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Run every 15 minutes
      OnUnitActiveSec = "15min";
      OnBootSec = "10min";
      Persistent = true;
    };
  };
}
