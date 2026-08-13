# Hourly pull of andoria-08's home directory into
# /tank/Backups/Contracts/Positron/nfs.
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
# REQUIRES pushme >= 3.1.0. Two defects in 3.0.0 made this design impossible,
# and both were fixed upstream specifically for it:
#
# 1. pushme's OWN ssh CALLS IGNORED EVERYTHING CONFIGURED HERE. `remote` built
#    the argv as literally ("ssh", hostName : cmd : args) -- a bare `ssh` off
#    PATH with no -F -- so the `test -d` precheck in checkDirectory consulted
#    johnw's DEFAULT ~/.ssh/config, which has no jump for andoria-08, and died
#    with "Could not resolve hostname andoria-08". The `--rsh` wrapper below
#    covers ONLY rsync's transport, never that call. 3.1.0 adds the per-alias
#    `SshOptions`, applied at Main.hs `remote` as
#      ("ssh", map unpack (host ^. hostSshOptions) ++ (hostName : cmd : args))
#    which is why `SshOptions` appears on the andoria alias below and is
#    load-bearing, not decorative.
#
# 2. pushme ALWAYS EXITED 0, even on a failed transfer -- the per-host status
#    was computed and then only printed. An unattended hourly backup that
#    reports success while copying nothing is the worst available failure mode.
#    3.1.0 maps transfer error -> 1, usage -> 2, and success/warning -> 0, so
#    the unit below can simply `exec` and trust systemd.
#
# HOW THE 3.0.0 BREAKAGE HID ITSELF, worth remembering: the first run appeared
# to work and moved ~8 GB. It only succeeded because a ControlMaster mux socket
# left over from interactive testing was still alive, which made bare
# `ssh andoria-08` resolve. Once it expired every run failed. A passing test
# that depends on a leftover mux socket is not a passing test.
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
    # `restartUnits` is deliberately ABSENT. It was restored on 2026-08-12 and
    # removed again the same day, because it caused two distinct failures:
    #
    # 1. STALE CONFIG (obr nixos-djx). sops-nix restarts the listed unit in a
    #    SEPARATE systemd transaction, so this unit's
    #    `after = home-manager-johnw.service` does not constrain it. At
    #    00:21:26 the sync ran two seconds before the switch finished, using
    #    the OLD fileset -- old destination, and the `test -d` probe still on.
    #    It merely failed; with a valid-but-stale destination it would have
    #    written to the wrong place, and rsync here carries --delete.
    #
    # 2. BLOCKED SWITCHES. The unit is Type=oneshot, so `systemctl start`
    #    blocks until it completes, and switch-to-configuration therefore waits
    #    for the whole sync. With TimeoutStartSec now 12h, a switch could hang
    #    for half a day holding the /etc/nixos/.nixos-build lock and stalling
    #    every other rebuild. Observed live twice: a switch sat >8 minutes
    #    mid-sync until the sync was stopped by hand, and then again on
    #    2026-08-12 via `restartIfChanged` -- see that setting below, which
    #    closes the second, independent path into this same hang.
    #
    # The cost of omitting it is small: a rotated key is picked up at the next
    # hourly run rather than immediately. For an hourly backup that is nothing.
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
            # Routes RSYNC's transport through the jump config below. This does
            # NOT cover pushme's own ssh calls -- that is what SshOptions is for.
            - "--rsh=${rshWrapper}"
          # pushme >= 3.1.0. Arguments for pushme's OWN ssh invocations, placed
          # before the hostname. Not interchangeable with Options: that is rsync
          # flags, this is ssh flags, and rsync never sees these.
          #
          # BELT AND BRACES, not strictly required as configured. The only ssh
          # call pushme makes for itself is checkDirectory's `test -d`, and
          # CheckRemoteDirectory below disables it, so today nothing consumes
          # this. It stays because it is the correct value if that probe is ever
          # re-enabled, and because any future pushme code path that shells out
          # would otherwise silently fall back to johnw's default ~/.ssh/config
          # -- the exact failure that made 3.0.0 unusable here.
          SshOptions:
            - "-F"
            - "${configDir}/ssh_config"
          # Do not run `test -d` on andoria before transferring. The stated
          # constraint for this job is that rsync is the ONLY command it executes
          # there, and the probe was the sole violation of it. With the probe off
          # the destination is taken on trust; if it is genuinely missing, rsync
          # reports that itself and 3.1.0's exit code surfaces it.
          CheckRemoteDirectory: false

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
          # Destination changed 2026-08-12 from $tank/work/positron. The old
          # tree (tank/work/positron, 339G referenced) is left in place and is
          # no longer written to by this job.
          Path: $tank/Backups/Contracts/Positron/nfs
          PreserveXattrs: false
          # NOTE: `--delete-excluded` was set here TEMPORARILY on 2026-08-12 and
          # removed the same day, once it had done its one job.
          #
          # Filters PROTECT what they exclude: rsync --delete removes only files
          # absent from the source AND not excluded. So everything copied before
          # the Filters block existed -- .cache, .rustup, .cargo, .codex, .elan,
          # .npm, .bun, .cabal and the rest, ~150 GiB -- would have sat in the
          # destination forever. --delete-excluded additionally removes
          # destination paths the filters exclude, which cleared that backlog:
          # referenced went 424G -> 274G and every excluded tree verified gone,
          # with .ssh/, .config/, .local/ and real data preserved.
          #
          # It must NOT become permanent. Left in place, every future edit to the
          # Filters block turns into an immediate mass deletion rather than a
          # change that merely stops copying something. Re-add it deliberately,
          # for one run, if the filter list is ever widened again.
          ReceiveFrom:
            - hera
            - clio
            - andoria

        andoria:
          Path: $home
          PreserveXattrs: false
          ReceiveFrom: []

      Common:
        # Exclusions, carried over verbatim from the filter list hera used when
        # IT held this mirror. Reproduced as-is rather than reinvented: these
        # are known to produce a correct copy of this particular home
        # directory, and guessing at build/cache directories is how a backup
        # quietly loses something that mattered.
        #
        # WHY THIS EXISTS (obr nixos-kvr): without filters the job mirrored the
        # entire home including regenerable caches. Measured 2026-08-12:
        # .cache alone was 55 GB of the 432 GB destination, and a run was
        # observed pulling
        #   .cache/huggingface/hub/models--google--gemma-4-12B-it/blobs/...
        # i.e. re-downloadable LLM weights. Throughput fell from 7-8 MB/s to
        # ~950 KB/s while doing so, so the tail of every sync was dominated by
        # its least valuable bytes -- a large part of why TimeoutStartSec had
        # to be raised to 4h.
        #
        # SYNTAX: pushme hands this to rsync as --include-from (Main.hs
        # withFilters), and under --include-from a leading "- " marks a line as
        # an EXCLUDE. So these are exclusions despite the flag's name. Leading
        # "/" anchors to the transfer root; a trailing "/" matches directories
        # only.
        #
        # NOTE: excluding a path does NOT delete what is already in the
        # destination. rsync --delete only removes files absent from the source
        # AND not excluded, so the 55 GB already copied is now PROTECTED and
        # will persist until it is removed deliberately.
        Filters: |
          - .autoagent/
          - .claude/worktrees/
          - .git/ai/
          - .rustup/
          - .tmp/
          - .npm/
          - .bun/
          - .elan/
          - *-tmp/
          - .cache/
          - /.cargo/
          - /.codex/
          - /.git-ai/
          - /.ssh/sockets/
          - /.local/lib/
          - /.local/share/agent-deck-hosts/
          - /.local/share/cargo/
          - /.local/share/rustup/
          - /.local/share/uv/
          - /.local/state/
          - /.partner-*/
          - /ares-gemma-4-runs/
          - /ares-rust-rinzler-cpp/stats/rinzler/stats/
          - /go/
          - /nix-cache
          - gen/
          - gen-*/
          - logs-rinzler-side-by-side/

          - *.agdai
          - *.d
          - *.glob
          - *.hi
          - *.o
          - *.vio
          - *.viok
          - *.vios
          - *.vo
          - *.vok
          - *.vos
          - *~
          - .*.aux
          - .*.cache
          - .cabal*
          - .cargo-home/
          - .direnv/
          - .envrc
          - .ghc.*
          - .lake/
          - .tmp/
          - .vagrant/
          - .venv/
          - .venv-trace/
          - MAlonzo/
          - Makefile.coq
          - Makefile.coq.conf
          - bash_snapshots/
          - build-debug/
          - build/
          - cabal.project.local*
          - dist-newstyle/
          - dist/
          - node_modules/
          - result
          - result-*
          - target/
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
        # RESUMABILITY (obr nixos-9ue). The 2026-08-13 00:01 run -- the first
        # under the 12h ceiling -- did NOT time out. It died after 11 minutes
        # with rsync exit 12, "connection unexpectedly closed (690359921 bytes
        # received so far)". The transport to andoria-08 drops mid-stream.
        #
        # Without --partial, a drop discards the entire in-flight file. At the
        # ~1 MB/s this link sustains on small files, any file that takes longer
        # to transfer than the mean time between drops can NEVER complete: every
        # run restarts it from zero. That is a convergence failure no timeout
        # value can fix, which is why raising the ceiling alone did not help.
        #
        # --partial-dir (not bare --partial) is the safe form: partials are
        # stashed in a side directory instead of being written out under the
        # real filename, so the destination never contains a truncated file
        # masquerading as a complete one. Because the path is RELATIVE, rsync
        # appends its own perishable exclude (`-f '-p .rsync-partial/'`) after
        # our filters, which stops --delete from reaping the partials before
        # they can be used -- verified against rsync 3.4.1's man page. Our
        # filter list never mentions .rsync-partial, so nothing shadows that
        # auto-rule.
        #
        # --timeout=600 bounds a STALLED stream, which is the other failure
        # shape: a hung connection that never closes would otherwise sit until
        # the 12h ceiling and waste the whole window. rsync sends keepalives
        # during long file-list and delete phases, so this does not fire on a
        # legitimately busy-but-quiet run.
        Options:
          - --partial-dir=.rsync-partial
          - --timeout=600
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
    description = "Pull andoria-08 home into /tank/Backups/Contracts/Positron/nfs (pushme)";
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

    # NEVER let a switch restart this unit.
    #
    # It is Type=oneshot, so `systemctl start` BLOCKS until the run completes,
    # and switch-to-configuration therefore waits for the whole sync. With
    # TimeoutStartSec at 12h a single switch could hang for twelve hours holding
    # /etc/nixos/.nixos-build and stalling every other rebuild on the host.
    # Observed twice on 2026-08-12: first via sops-nix `restartUnits` (removed),
    # and then again via the DEFAULT `restartIfChanged = true`, which restarts
    # any active unit whose definition changed -- including the very change that
    # raised the timeout.
    #
    # A backup has no reason to be interrupted by an activation. Config changes
    # take effect at the next scheduled run, which for an hourly timer is soon
    # enough, and a run in flight is left alone.
    restartIfChanged = false;

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      # pushme reads ~/.config/pushme by default; setting HOME explicitly means
      # the unit and an interactive `pushme` run use the SAME files.
      Environment = [ "HOME=/home/${user}" ];
      # A ceiling against a WEDGED transfer, not a target. The timer's own
      # overlap guard (systemd will not start a second instance while one runs)
      # handles the ordinary long-run case.
      #
      # 50m -> 4h -> 12h, both raises on 2026-08-12 and both driven by
      # measurement rather than guesswork.
      #
      # 50m was too tight for the initial convergence: the 04:43 run moved
      # +23 GiB (dataset 379G -> 402G) and was still killed at the ceiling.
      #
      # 4h was still too tight. EVERY run under it ended in
      # "Failed with result 'timeout'" at exactly four hours -- 14:00:36, then
      # 16:43:36 -> 20:43:36 -- and across the unit's whole history there was
      # exactly one "Finished Pull", from the 2026-08-10 run that aborted early
      # on the unsupported --crtimes flag. A full pass had never completed.
      # Throughput is the reason it varies so much: 7-8 MB/s on large files but
      # ~1 MB/s on small ones, which over a jump host is overhead-dominated.
      #
      # 12h reflects John's judgement that this source is "sometimes big". It
      # is a ceiling against a WEDGED transfer, not a target: a healthy
      # steady-state delta finishes in minutes, and the timer's overlap guard
      # means a long run simply causes the next hourly trigger to be dropped
      # rather than stacking a second copy.
      #
      # The cost is detection latency -- a genuinely hung transfer now sits for
      # up to 12h before systemd kills it. That is acceptable here because the
      # job is a backup with no downstream consumer waiting on it, and because
      # a hang is still eventually caught rather than silently ignored.
      #
      # Note this unit is EXCLUDED from ServiceStuckActivating (see
      # modules/monitoring/alerts/systemd.yaml) precisely because a legitimate
      # run now sits in `activating` for hours.
      TimeoutStartSec = "12h";
      Nice = 10;
      IOSchedulingClass = "idle";
    };

    # A plain `exec` is now correct. Until 3.1.0 this had to capture the output
    # and grep it for "done (with errors)", because pushme always exited 0 and a
    # failed transfer was indistinguishable from a good one. 3.1.0 returns 1 on
    # transfer error and 2 on usage error, so systemd sees the truth directly and
    # the log-scraping guard is gone.
    #
    # A warning still exits 0 on purpose: it maps to rsync 23/24 (partial
    # transfer, vanished source files), both routine when mirroring a home
    # directory somebody is actively using.
    script = ''
      exec ${inputs.pushme.packages.${system}.default}/bin/pushme \
        --no-color \
        --filesets work/positron \
        andoria tank
    '';
  };

  systemd.timers.pushme-positron = {
    description = "Hourly andoria-08 -> /tank/Backups/Contracts/Positron/nfs sync";
    # ARMED 2026-08-12, once pushme 3.1.0 supplied SshOptions and real exit
    # codes. Restored together with `restartUnits` on the sops secret above --
    # they are a pair.
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
