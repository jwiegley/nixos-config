# Hourly pull of andoria-08's home directory into /tank/work/positron.
#
# Replaces the mirror that used to live on hera. hera is still in the path, but
# only as an SSH JUMP HOST -- it no longer stores a copy.
#
# WHY THE JUMP EXISTS: andoria-08 is on a Tailscale tailnet
# (andoria-08.porgy-gecko.ts.net -> 100.85.190.60) that hera has joined and
# vulcan has not. vulcan cannot resolve or reach it directly; measured
# 2026-08-10, `host andoria-08` fails here and succeeds on hera. Joining vulcan
# to the tailnet would remove hera from the path entirely, and is the obvious
# future simplification -- but it is a separate decision with its own security
# surface, so this routes through hera instead.
#
# THE JUMP GRANT ON HERA, for reference (hera is macOS/nix-darwin; the file is
# /etc/ssh/nix_authorized_keys.d/johnw):
#
#   from="192.168.1.2",restrict,port-forwarding,\
#   permitopen="andoria-08:22",command="/usr/bin/false" ssh-ed25519 AAAA... johnw@vulcan
#
# Each clause earns its place, and the combination was verified live:
#   * `restrict` disables pty, agent, X11 and user-rc -- but NOT command
#     execution, which is why `command="/usr/bin/false"` is also needed. Without
#     it the key yields a full shell on hera (confirmed: it did).
#   * `command=` does NOT block the jump, because ProxyJump uses a direct-tcpip
#     channel rather than an exec channel. Verified: shell blocked, jump works.
#   * `port-forwarding` re-enables the one capability `restrict` removed that a
#     jump actually needs. ORDER MATTERS -- it must follow `restrict`, which is
#     applied left to right.
#   * `permitopen` pins forwarding to exactly andoria-08:22. Verified tight:
#     the Tailscale FQDN and the raw 100.85.190.60 are both refused.
#   * `from=` is vulcan's source address on the route to hera.
#
# ONLY rsync IS EXECUTED ON andoria-08. Nothing here runs a remote shell
# command; pushme drives rsync and nothing else. If you want that enforced
# rather than merely intended, the andoria side is the place: give this key its
# own authorized_keys entry there with a forced `rrsync`-style command scoped to
# $HOME. That is andoria's config, not ours.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  user = "johnw";
  keyPath = config.sops.secrets."pushme/positron-ssh-private-key".path;

  # The jump identity. NOT in SOPS: it is johnw's own key, already present in
  # his home and already used interactively. Only the positron key -- which
  # this unit needs while running unattended as a service -- was moved into
  # SOPS.
  jumpKey = "/home/${user}/.ssh/id_vulcan";

  configDir = "/home/${user}/.config/pushme";

  # rsync's --rsh must be ONE argv element. pushme passes each `Options` entry
  # through as a separate argument, so an inline `ssh -F ...` would either be
  # re-split or arrive quoted wrongly depending on its splitting rules. A
  # wrapper sidesteps the question entirely.
  rshWrapper = pkgs.writeShellScript "pushme-positron-rsh" ''
    exec ${pkgs.openssh}/bin/ssh -F ${configDir}/ssh_config "$@"
  '';
in
{
  # 0400 johnw:johnw. The unit runs as johnw, so it reads the key directly
  # rather than via LoadCredential -- pushme spawns rsync which spawns ssh, and
  # ssh needs a real path to hand to IdentityFile, not a credential fd.
  sops.secrets."pushme/positron-ssh-private-key" = {
    owner = user;
    mode = "0400";
    restartUnits = [ "pushme-positron.service" ];
  };

  home-manager.users.${user} = {
    # ---- pushme's own config ----
    #
    # Written here rather than copied from hera so the two cannot drift
    # silently. If hera's copy changes, this one must be updated deliberately.
    xdg.configFile."pushme/config.yaml".text = ''
      SIUnits: true

      Aliases:
        andoria:
          Host: andoria-08
          # 1, not the 10 hera uses. Every job lands on /tank, which lives on
          # the OWC USB enclosure whose bridge has hung under concurrent load
          # before (see modules/storage/zfs.nix). Serial is the safe default
          # here; raise it only with evidence.
          MaxJobs: 1
          Variables:
            home: /home/jwiegley
          Options:
            # andoria's rsync is a Nix profile binary and is NOT on the PATH of
            # the non-login shell rsync-over-ssh gets. Measured on the host:
            # `command -v rsync` -> /home/jwiegley/.nix-profile/bin/rsync.
            # Without this the transfer dies with "rsync: command not found".
            - "--rsync-path=/home/jwiegley/.nix-profile/bin/rsync"
            # Routes every ssh through the jump config below.
            - "--rsh=${rshWrapper}"

        tank:
          Host: vulcan
          MaxJobs: 1
          Variables:
            tank: /tank
    '';

    # ---- the fileset ----
    #
    # THE `andoria` ENTRY IN tank's ReceiveFrom IS THE WHOLE POINT. Upstream's
    # shipped example has `ReceiveFrom: [hera, clio]` for the tank store, which
    # is why the data has only ever reached /tank indirectly, andoria -> hera ->
    # tank. Main.hs:425 gates every transfer on this list ("does local store
    # allow receiving from remote?"), so without andoria here the sync is
    # REFUSED -- silently, as far as the timer is concerned. Removing hera's
    # mirror without this line would have broken the chain outright.
    xdg.configFile."pushme/filesets/work_positron.yaml".text = ''
      Name:     'work/positron'
      Priority: 50
      Classes:
        - 'small'

      Stores:
        tank:
          Path: $tank/work/positron
          PreserveXattrs: false
          ReceiveFrom:
            - hera
            - clio
            - andoria

        andoria:
          Path: $home
          PreserveXattrs: false
          ReceiveFrom: []

      Common:
        PreserveAttrs: true
    '';

    # ---- ssh config used ONLY by this job ----
    #
    # Deliberately separate from johnw's main ~/.ssh/config, which is generated
    # from the SHARED Darwin nix-config repo and is therefore the wrong place
    # to encode a vulcan-only jump. Keeping it here also means the SOPS key path
    # is the only identity this job can present.
    xdg.configFile."pushme/ssh_config".text = ''
      Host andoria-08
        User jwiegley
        IdentityFile ${keyPath}
        IdentitiesOnly yes
        ProxyJump pushme-jump
        # Pinned on first contact and stable thereafter. A CHANGED key will fail
        # the transfer rather than prompt, which is what an unattended job wants.
        StrictHostKeyChecking accept-new
        UserKnownHostsFile ${configDir}/known_hosts
        BatchMode yes

      Host pushme-jump
        HostName hera.lan
        User ${user}
        IdentityFile ${jumpKey}
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
        UserKnownHostsFile ${configDir}/known_hosts
        BatchMode yes
    '';
  };

  systemd.services.pushme-positron = {
    description = "Pull andoria-08 home into /tank/work/positron (pushme)";
    # Both matter: nss-lookup because the jump resolves hera.lan and a boot-time
    # start can otherwise race DNS (the same failure drafts-mcp hit on
    # 2026-07-03), and the sops target because the identity is a secret.
    after = [
      "network-online.target"
      "nss-lookup.target"
      "sops-nix.service"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      # pushme reads ~/.config/pushme by default; setting HOME explicitly means
      # the unit and an interactive `pushme` run use the SAME files.
      Environment = [ "HOME=/home/${user}" ];
      # rsync and ssh must both be resolvable; openssh is also what the rsh
      # wrapper execs.
      Path = [
        pkgs.rsync
        pkgs.openssh
      ];
      # A full pass over a home directory across a Tailscale relay can be slow.
      # This is a ceiling against a wedged transfer, not a target -- the timer's
      # own overlap guard (systemd will not start a second instance while one
      # runs) handles the ordinary long-run case.
      TimeoutStartSec = "50m";
      Nice = 10;
      IOSchedulingClass = "idle";
    };

    script = ''
      exec ${inputs.pushme.packages.${system}.default}/bin/pushme \
        --filesets work/positron \
        andoria tank
    '';
  };

  systemd.timers.pushme-positron = {
    description = "Hourly andoria-08 -> /tank/work/positron sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      # Catch up after downtime rather than silently skipping an hour.
      Persistent = true;
      # Spread it off the top of the hour, which is already crowded with the
      # autosnap sweep and the textfile exporters.
      RandomizedDelaySec = "5m";
      Unit = "pushme-positron.service";
    };
  };
}
