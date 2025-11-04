{ config, lib, pkgs, ... }:

let
  # Sieve script to process messages in Good folder
  processGoodScript = pkgs.writeText "process-good.sieve" ''
    require ["fileinto", "mailbox", "regex", "imap4flags", "variables"];

    # This script applies filtering rules when messages are moved to Good folder
    # Edit this to match your personal filtering preferences

    # Sort mailing lists by List-Id
    if header :contains "List-Id" "<" {
      if header :regex "List-Id" "<([^@]+)@" {
        set :lower "listname" "''${1}";
        fileinto :create "list/''${listname}";
        stop;
      }
    }

    # Sort by sender domain
    if address :domain :is "from" "github.com" {
      fileinto :create "mail/github";
      stop;
    }

    if address :domain :is "from" "gitlab.com" {
      fileinto :create "mail/gitlab";
      stop;
    }

    # Filter newsletters
    if header :contains "subject" "newsletter" {
      fileinto :create "mail/newsletters";
      stop;
    }

    # Filter by common automation headers
    if header :contains "precedence" "bulk" {
      fileinto :create "mail/bulk";
      stop;
    }

    # Add your custom rules here following the examples above

    # Default: keep in Good folder
    keep;
  '';
in
{
  # Deploy the processing script
  systemd.tmpfiles.rules = [
    "d /var/lib/dovecot/sieve 0755 dovecot2 dovecot2 -"
    "L+ /var/lib/dovecot/sieve/process-good.sieve - - - - ${processGoodScript}"
  ];
}
