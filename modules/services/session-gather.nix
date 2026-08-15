{
  config,
  lib,
  pkgs,
  ...
}:

# Nightly gathering of AI coding-agent session logs from every configured host
# into one tree on vulcan.
#
# The gatherer itself lives in /home/johnw/src/sessions (github.com/jwiegley/
# sessions) and is deliberately NOT updated by this unit: code changes stay
# explicit, reviewed operations.
#
# TRANSPORT. bin/gather-sessions invokes plain `rsync host:path`, with no -e, so
# it would otherwise use johnw's default ssh config -- which has no andoria
# entry and would offer the wrong identity everywhere. Rather than patch the
# gatherer, RSYNC_RSH points rsync at a config written just for this job. rsync
# honours RSYNC_RSH for every remote operand, verified before adopting it.
#
# SECURITY. The identity is ~/.ssh/id_rsync, a dedicated key whose authorized_keys
# entry on each source host is forced to `rrsync -ro <home>` -- read-only, confined
# to one subtree, no pty, no agent forwarding. A compromise of this key yields
# read access to the configured homes and nothing else. See docs/SESSION_GATHER.md.
let
  user = "johnw";
  home = "/home/${user}";
  checkout = "${home}/src/sessions";
  archive = "/tank/Backups/Sessions";
  configDir = "${home}/.config/sessions";
  identity = "${home}/.ssh/id_rsync";
in
{
  # ---- ssh config used ONLY by the session gatherer ----
  #
  # Separate from johnw's ~/.ssh/config, which is generated from the shared
  # Darwin nix-config repo and is the wrong place for vulcan-only automation.
  # Keeping it here also means id_rsync is the only identity this job can offer.
  home-manager.users.${user}.xdg.configFile."sessions/ssh_config".text = ''
    Host hera
      HostName hera.lan

    # Clio moves between the LAN (192.168.1.5) and the VPN (10.6.0.2). Automated
    # gathering is wanted ONLY on the LAN address, so the address is pinned here
    # rather than resolved: off-LAN, the connection simply fails instead of
    # pulling a large tree over the tunnel. Do not replace this with a name.
    Host clio
      HostName 192.168.1.5

    Host vps
      HostName vps-b30dd5a8.vps.ovh.ca

    # Andoria is not routable from vulcan; hera forwards to it. hera's
    # authorized_keys entry for id_rsync must carry port-forwarding and a
    # permitopen naming this exact host:port, or the channel is refused.
    #
    # andoria-08 rather than andoria-t2, at John's direction 2026-08-14. The two
    # are aliases for one NFS-shared home, so either works as transport, but
    # hera's existing permitopen already names andoria-08:22 -- using it means
    # nothing has to be widened there. Changing this name requires a matching
    # permitopen on hera, or the forward is refused with "administratively
    # prohibited".
    Host andoria-08
      User jwiegley
      ProxyJump hera

    # OpenSSH keeps the first value it obtains, so host-specific values above
    # must precede these shared defaults.
    Host *
      User ${user}
      IdentityFile ${identity}
      IdentitiesOnly yes
      BatchMode yes
      ConnectTimeout 15
      # Pinned on first contact, stable thereafter. A CHANGED host key fails the
      # transfer rather than prompting, which is what an unattended job wants.
      # This is TOFU, not disabled checking: StrictHostKeyChecking=no is never used.
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ${configDir}/known_hosts
  '';

  systemd.services.session-gather = {
    description = "Gather AI coding-agent session logs into ${archive}";

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # NEVER let a switch restart this unit. It is Type=oneshot, so
    # `systemctl start` blocks until the run completes and switch-to-configuration
    # would wait for the whole gather -- with a 12h ceiling that can stall every
    # rebuild on the host for half a day. This exact trap cost two blocked
    # switches on pushme-positron (see that module); do not remove it.
    restartIfChanged = false;

    path = [
      pkgs.bash
      pkgs.rsync
      pkgs.openssh
      pkgs.coreutils
    ];

    environment = {
      # See the TRANSPORT note above: this is what routes the gatherer's rsync
      # through the job-specific ssh config instead of johnw's default one.
      RSYNC_RSH = "${pkgs.openssh}/bin/ssh -F ${configDir}/ssh_config";
    };

    serviceConfig = {
      Type = "oneshot";
      User = user;
      WorkingDirectory = checkout;
      # Owner-only: the archive contains session transcripts.
      UMask = "0077";
      # Ample but finite. The first reconciliation pulls the whole tree; later
      # runs are incremental. A wedged run fails the unit rather than hanging.
      TimeoutStartSec = "12h";
      ExecStart = lib.concatStringsSep " " [
        "${checkout}/bin/gather-sessions"
        "${checkout}/config/sources.vulcan.tsv"
        archive
      ];
    };
  };

  systemd.timers.session-gather = {
    description = "Nightly AI session-log gathering";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      # A missed run (host down) executes once after the machine returns.
      Persistent = true;
    };
  };
}
