{
  config,
  lib,
  pkgs,
  ...
}:

# Email testing script for manual execution
# Does NOT include automated monitoring (timer, Prometheus, Nagios)
# to avoid over-training rspamd on test messages

{
  # SOPS secret for IMAP authentication
  sops.secrets."email-tester-imap-password" = {
    owner = "root";
    mode = "0400";
  };

  # Install script in system PATH for manual use
  environment.systemPackages = [
    (pkgs.writeScriptBin "email-tester" ''
      #!${pkgs.bash}/bin/bash
      exec ${pkgs.python3}/bin/python3 /etc/nixos/scripts/email-tester.py "$@"
    '')
  ];
}
