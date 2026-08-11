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
# !! THIS MODULE IS NOT YET FUNCTIONAL -- the timer is deliberately left stopped.
#
# TWO UPSTREAM FACTS ABOUT pushme 3.0.0 BREAK THE DESIGN BELOW, both verified
# against the source at /tank/src/pushme (commit f8ea0cc):
#
# 1. rsync IS NOT THE ONLY COMMAND RUN ON andoria-08. Before every transfer,
#    checkDirectory (Main.hs:490-495) runs `test -d <path>` on the remote to
#    decide whether the sync can proceed. So a forced `rrsync`-style command in
#    andoria's authorized_keys -- which an earlier version of this comment
#    recommended -- would NOT harden this job, it would BREAK it: the test would
#    fail and syncStores would abandon the transfer, logging "Either local
#    directory missing / OR remote directory missing" and returning
#    TransferError. Note that is loud in the LOG but silent in the EXIT CODE:
#    stock pushme 3.0.0 returns 0 regardless, which is why the unit below
#    inspects the log rather than trusting the status.
#
# 2. pushme's OWN ssh CALLS IGNORE EVERYTHING CONFIGURED HERE. `remote`
#    (Main.hs:777-781) builds the argv as literally
#      ("ssh", hostName : cmd : args)
#    -- a bare `ssh` off PATH with no -F and no options, so it uses johnw's
#    DEFAULT ~/.ssh/config, which has no jump for andoria-08. The `--rsh`
#    wrapper below covers ONLY rsync's own transport, not this. There is no
#    config key to inject ssh options into that path.
#
# HOW THIS HID ITSELF: the first run appeared to work and moved ~8 GB. It only
# succeeded because a ControlMaster mux socket left over from interactive
# testing was still alive, which made bare `ssh andoria-08` resolve. Once it
# expired, every run failed with
#   Command failed: test ["-d","/home/jwiegley/"]: ssh: Could not resolve
#   hostname andoria-08: Name or service not known
# A passing test that depends on a leftover mux socket is not a passing test.
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
    # `restartUnits = [ "pushme-positron.service" ]` BELONGS HERE and must be
    # restored at the same time as the timer's `wantedBy` -- the two are a pair,
    # and re-enabling one without the other is the mistake this note exists to
    # prevent.
    #
    # It is omitted while the job is disarmed because it is not inert: sops-nix
    # restarts the listed unit whenever the secret is (re)deployed, which starts
    # the service even though no timer is armed. That is not hypothetical --
    # it happened at 2026-08-10 23:03:39, when the secret first deployed and
    # the known-broken job ran and failed. Left in place, the next key rotation
    # would fire the exact critical SystemdServiceFailed alert that disarming
    # the timer was meant to avoid.
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
        # PreserveAttrs is a BLANKET: it is read once at Options.hs:49 and then
        # fed as the default for ACLs, xattrs, atimes, crtimes, hardlinks and
        # executability across Options.hs:55-60. That
        # turns on rsync's -N, and vulcan's rsync 3.4.1 is built WITHOUT crtimes
        # ("stop-at, no crtimes" in --version), so every run died with
        # "This rsync does not support --crtimes (-N)". hera's macOS rsync does
        # support it, which is why the same fileset works there and not here.
        #
        # An explicit key beats the blanket in the same object. The parser at
        # Options.hs:58 is `((<|> preserveAll) <$> v .:? "PreserveCrtimes")` --
        # the alternative is applied INSIDE the parser's functor, not to its
        # result, so an explicit `Just False` is kept rather than falling back
        # to preserveAll. The destination is ZFS on Linux, which has no
        # creation-time attribute to preserve anyway, so nothing is lost.
        PreserveCrtimes: false
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
    # nss-lookup because the jump resolves hera.lan and a boot-time start can
    # otherwise race DNS (the same failure drafts-mcp hit on 2026-07-03); and
    # home-manager because it is what materialises the three config files this
    # unit reads. That second one is not theoretical -- the very first
    # activation started this service at 23:03:39 and home-manager-johnw
    # finished at 23:03:40, so pushme died on "Yaml file not found". Ordering
    # only, no `wants`: a sync must never trigger a home-manager activation.
    #
    # There is deliberately NO `sops-nix.service` entry: no such unit exists on
    # this host (`systemctl cat sops-nix.service` fails), because sops-nix
    # installs secrets from an activation script rather than a service. An
    # earlier revision ordered against it, which was simply a no-op.
    after = [
      "network-online.target"
      "nss-lookup.target"
      "home-manager-${user}.service"
    ];
    wants = [ "network-online.target" ];

    # NOTE: this is `path`, the NixOS option, NOT `serviceConfig.Path`. There is
    # no `Path=` directive in a systemd [Service] section, and serviceConfig is
    # freeform -- so writing it there renders `Path=` lines that systemd
    # discards with "Unknown key 'Path' in section [Service], ignoring", the
    # build stays green, and the unit fails at runtime exactly as if nothing had
    # been set. That is precisely what happened here.
    #
    # pushme execs FOUR external programs: `hostname`, `rsync`, `find` and
    # `ssh`. (An earlier version of this comment claimed three "and nothing
    # else", which was wrong in the one way that mattered -- `ssh` is execed
    # from `remote` at Main.hs:779 and is exactly the call that breaks the jump,
    # per the header above.)
    #
    # `find` already arrives on the default unit PATH via findutils. The others
    # do not: the first manual run died on
    # `hostname: posix_spawnp: does not exist`. openssh covers both pushme's own
    # ssh calls and the rsh wrapper's.
    path = [
      pkgs.rsync
      pkgs.openssh
      pkgs.nettools # hostname
    ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      # pushme reads ~/.config/pushme by default; setting HOME explicitly means
      # the unit and an interactive `pushme` run use the SAME files.
      Environment = [ "HOME=/home/${user}" ];
      # A full pass over a home directory across a Tailscale relay can be slow.
      # This is a ceiling against a wedged transfer, not a target -- the timer's
      # own overlap guard (systemd will not start a second instance while one
      # runs) handles the ordinary long-run case.
      TimeoutStartSec = "50m";
      Nice = 10;
      IOSchedulingClass = "idle";
    };

    # WHY THIS IS NOT JUST `exec pushme ...`:
    #
    # pushme ALWAYS EXITS 0. Main.hs:266 ends at `runReaderT processBindings
    # opts` with no exitWith anywhere in the program; the per-host result is
    # computed at Main.hs:327 and then only *printed* as "done", "done (with
    # warnings)" or "done (with errors)". So a transfer that failed outright --
    # the unsupported-flag abort above, a refused ReceiveFrom, a dead jump host
    # -- is indistinguishable from success to systemd, and this unit would sit
    # there reporting a clean run every hour while copying nothing. That is the
    # worst failure mode an unattended backup job can have, so the log string
    # is the only signal available and we act on it.
    #
    # "(with warnings)" is deliberately NOT a failure: Main.hs:598-599 maps it
    # to rsync exit 23/24, partial transfer and vanished source files, which are
    # both routine when mirroring a home directory somebody is actively using.
    #
    # --no-color keeps the marker free of the ANSI escapes Main.hs:333 would
    # otherwise wrap it in, so the grep matches plain text.
    script = ''
      set -o pipefail
      out=$(mktemp)
      trap 'rm -f "$out"' EXIT

      # `|| rc=$?` rather than a bare pipeline: NixOS runs this script under
      # `bash -e`, so an abort would exit before the log inspection below ever
      # ran. Putting the pipeline in a condition context suspends errexit.
      #
      # pipefail yields the RIGHTMOST non-zero status, not the leftmost (an
      # earlier version of this comment had it backwards): `(exit 3) | (exit 7)`
      # gives 7. That does not change the outcome here, because `tee` exits 0
      # whenever it can write, so `(exit N) | (exit 0)` yields N and rc is
      # pushme's status -- but do not rely on the wrong rule if a stage is ever
      # added to this pipeline.
      rc=0
      ${inputs.pushme.packages.${system}.default}/bin/pushme \
        --no-color \
        --filesets work/positron \
        andoria tank 2>&1 | tee "$out" || rc=$?

      if [ "$rc" -ne 0 ]; then
        echo "pushme exited $rc"
        exit "$rc"
      fi

      if grep -qF 'done (with errors)' "$out"; then
        echo "pushme reported a transfer error (it still exits 0; see above)"
        exit 1
      fi

      if ! grep -qF 'done' "$out"; then
        echo "pushme printed no completion line -- treating as a failed run"
        exit 1
      fi
    '';
  };

  systemd.timers.pushme-positron = {
    description = "Hourly andoria-08 -> /tank/work/positron sync";
    # DISARMED ON PURPOSE -- see the two upstream blockers at the top of this
    # file. `wantedBy = [ "timers.target" ]` belongs here and must be restored
    # the moment those are resolved; it is omitted only because an hourly job
    # that cannot succeed would fire SystemdServiceFailed (critical) every hour.
    # The unit is still fully defined, so `systemctl start pushme-positron` runs
    # it on demand for testing.
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
