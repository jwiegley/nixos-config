{ config, lib, pkgs, ... }:

let
  mkMbsyncLib = import ../lib/mkMbsyncModule.nix { inherit config lib pkgs; };
  inherit (mkMbsyncLib) mkMbsyncService;
in
{
  imports = [
    # Johnw configuration
    (mkMbsyncService {
      name = "johnw";
      user = "johnw";
      group = "users";
      secretName = "johnw-fastmail-password";

      remoteConfig = ''
        Host imap.fastmail.com
        User johnw@newartisans.com
        PassCmd "cat /run/secrets/johnw-fastmail-password"
        TLSType IMAPS
        CertificateFile /etc/ssl/certs/ca-certificates.crt
        Port 993
        PipelineDepth 1
      '';

      channels = ''
        # Sync all folders from Fastmail (pull only)
        Channel fastmail-all
        Far :johnw-remote:
        Near :dovecot-local:
        Patterns Good Spam TrainGood TrainSpam IsGood IsSpam NeedsRule INBOX Sent Trash mail/* list/*
        Create Both
        Remove None
        Expunge Both
        Sync Full
        SyncState /var/lib/mbsync-johnw/
        CopyArrivalDate yes
      '';

      timerInterval = "15min";

      # Don't use RemainAfterExit with OnUnitActiveSec timer
      # The service needs to become inactive for the timer to schedule the next run
      extraServiceConfig = {};
    })

    # Assembly configuration
    (mkMbsyncService {
      name = "assembly";
      user = "assembly";
      group = "assembly";
      secretName = "carmichael-imap-gmail-com";
      trash = "[Gmail]/Trash";

      remoteConfig = ''
        Host imap.gmail.com
        User carmichaellsa@gmail.com
        PassCmd "cat /run/secrets/carmichael-imap-gmail-com"
        Port 993
        TLSType IMAPS
        CertificateFile /etc/ssl/certs/ca-certificates.crt
      '';

      channels = ''
        # Gmail to Dovecot channel
        Channel gmail-all
        Far :assembly-remote:
        Near :dovecot-local:
        Patterns * !"[Gmail]/All Mail" !"[Gmail]/Important" !"[Gmail]/Starred" !"[Gmail]/Trash"
        Create Near
        Remove Near
        Expunge Near
        Sync Pull
        SyncState /var/lib/mbsync-assembly/
      '';

      timerInterval = "1day";

      # Don't use RemainAfterExit with OnUnitActiveSec timer
      # The service needs to become inactive for the timer to schedule the next run
      extraServiceConfig = {};
    })
  ];

  # Install isync package to make mbsync available
  environment.systemPackages = [ pkgs.isync ];
}
