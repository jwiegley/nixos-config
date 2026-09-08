{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  flakeAttr =
    "/etc/nixos#nixosConfigurations.${config.networking.hostName}" + ".config.system.build.toplevel";

  exporter = pkgs.writers.writePython3Bin "deploy-canary-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/deploy-canary-exporter.py);
in
{
  # Can this host still be DEPLOYED? Nothing else here asks.
  #
  # On 2026-09-08 every nixos-rebuild had been blocked for up to four days and no alert
  # fired (obr nixos-obc, nixos-cur). Four orphaned nix-daemon workers held a build lock
  # dated Sep 4 on a path whose output already existed; every build queued behind it
  # forever. It was found only because a switch was attempted by hand and then strace'd.
  #
  # The blind spot is structural: nixos-rebuild is run interactively rather than by a
  # timer, so no unit fails; no metric moves; and the machine keeps serving its last-good
  # generation in perfect health. Every other collector watches whether the system is
  # RUNNING. This one watches whether it can still be CHANGED -- which is invisible right
  # up until a patch has to go out.
  #
  # WHY TWO CHECKS AND NOT THE OBVIOUS ONE. The plan check (`nix build --dry-run`) catches
  # eval errors and unbuildable inputs -- it would have caught agent-cat-pi-extension
  # (nixos-4o4) the day it broke instead of days later. But it WOULD NOT have caught the
  # incident this exists for: that hang was in realisation, after evaluation had already
  # finished and printed its derivation list, and --dry-run stops before realising. The
  # held-lock check covers that path. Neither subsumes the other.
  #
  # See the script's docstring for what distinguishes a real build lock from the ~26
  # Cargo.lock files the store carries as ordinary package contents, and why holder
  # detection is one pass over /proc rather than the O(locks x processes) shape that
  # measured over two minutes during the investigation.
  systemd.services.deploy-canary-exporter = {
    description = "Export whether this host can still evaluate and deploy a new system";
    after = [ "prometheus-node-exporter.service" ];

    # HOME is redirected into the unit's own CacheDirectory, and that is load-bearing
    # twice over.
    #
    # 1. /etc/nixos is owned by johnw, not root, so libgit2's ownership guard refuses to
    #    open it for this root-run unit:
    #        error: opening Git repository "/etc/nixos": repository path is not owned by
    #        current user
    #    Root's own ~/.gitconfig already exempts it, but ProtectHome=true hides /root, so
    #    that exemption is unreadable here. The exemption is therefore supplied in a
    #    .gitconfig written into this HOME by ExecStartPre.
    #
    #    NOT GIT_CONFIG_COUNT/KEY/VALUE, and NOT GIT_CONFIG_GLOBAL: both were tried and
    #    neither works. Those are git-CLI mechanisms, and nix fetches flakes with
    #    libgit2, which discovers global config through $HOME instead.
    #
    # 2. nix wants a writable $HOME/.cache/nix. Pointing HOME at any read-only location
    #    fails with "creating directory '.../.cache/nix': Read-only file system", so it
    #    has to be a directory systemd actually creates for us.
    #
    # This bit the collector on its first real run: standalone `sudo python3 ...` passed
    # (root's home was visible and writable) while the unit failed in 0.028s. The canary
    # would have gone on to alert about itself -- which the DeployPlanFailing rule would
    # have reported honestly, but about the wrong thing.
    environment.HOME = "/var/cache/deploy-canary";

    serviceConfig = {
      Type = "oneshot";
      # Root for two reasons: resolving /proc/<pid>/fd for processes owned by other users
      # (the incident's holders were nix-daemon workers, not ours), and reading the flake
      # from root-owned /etc/nixos.
      User = "root";
      Group = "root";

      # Provides the writable HOME above (/var/cache/deploy-canary) that nix needs for
      # its eval cache, and hosts the .gitconfig libgit2 reads for the safe.directory
      # exemption. Written every run so it cannot drift from what the unit declares.
      CacheDirectory = "deploy-canary";
      ExecStartPre = "${pkgs.writeShellScript "deploy-canary-gitconfig" ''
        printf '[safe]\n\tdirectory = /etc/nixos\n' > "$CACHE_DIRECTORY/.gitconfig"
      ''}";

      ExecStart = "${lib.getExe exporter} ${lib.escapeShellArg flakeAttr}";

      # Above the script's own 600s plan timeout so the script always gets to write its
      # metrics -- a unit killed by systemd would leave the LAST run's .prom in place and
      # the failure would read as success until the staleness rule caught up.
      TimeoutStartSec = "15m";

      # DELIBERATELY NOT holding /etc/nixos/.nixos-build. A dry-run mutates nothing, and
      # taking the lock would let this collector block a real interactive rebuild for up
      # to its whole timeout -- turning a monitor for "cannot deploy" into a cause of it.
      #
      # Hardening: reads the store, /proc and the flake; writes exactly one file.
      # NOT DynamicUser -- textfileDir is mode 1777 (sticky), so a rotating uid cannot
      # rename(2) over the .prom left by the previous run.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    path = [
      config.nix.package
      pkgs.git # flake evaluation of a git tree
    ];
  };

  systemd.timers.deploy-canary-exporter = {
    description = "Timer for the deploy canary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # DAILY. Both conditions are latches, not fluctuations: a stale held lock and a
      # broken input each persist until someone acts, so detection latency costs only the
      # delay before a human is told. Daily also keeps the cost honest -- the plan check
      # is a full flake evaluation (~50s measured), which is not something to run hourly
      # for a condition that cannot appear spontaneously between deploys.
      OnBootSec = "20m";
      OnCalendar = "daily";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
