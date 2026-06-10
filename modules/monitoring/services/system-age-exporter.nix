{
  config,
  lib,
  pkgs,
  ...
}:

let
  # "Is the system actually being patched?" textfile exporter (P1, monitoring
  # domain: security/correctness — docs/MONITORING_COVERAGE_PLAN.md).
  #
  # A green build/switch tells you the LAST switch succeeded; it tells you
  # nothing about whether the system is being kept current. Two cheap,
  # filesystem-derived signals answer that:
  #
  #   system_flake_lock_mtime_seconds
  #       mtime of /etc/nixos/flake.lock. `nix flake update` rewrites this file,
  #       so its mtime is "when did we last pull new inputs". A flake.lock that
  #       hasn't moved in a month means nixpkgs/inputs aren't being refreshed —
  #       the system is drifting away from upstream security fixes.
  #
  #   system_current_generation_build_timestamp_seconds
  #       mtime of /nix/var/nix/profiles/system — the per-switch symlink that
  #       nixos-rebuild repoints on every successful `switch`/`boot`. Verified
  #       live 2026-06-09: it updates to the switch wall-clock time (NOT the
  #       epoch-1 mtime that store paths carry), so it is a faithful "when did
  #       this generation go live" stamp. /run/current-system works equally well
  #       but the profile link is the canonical per-switch artifact.
  #
  # Emitted to the node-exporter textfile collector
  # (/var/lib/prometheus-node-exporter-textfiles/, picked up by job=node), the
  # same idiom as asymmetric-routing-exporter.nix / container-health-exporter.nix.
  # Alerts live in modules/monitoring/alerts/security.yaml
  # (SystemUpdatesStale / SystemGenerationStale).
  system-age-exporter = pkgs.writeShellApplication {
    name = "system-age-exporter";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
      TEMP_FILE="$TEXTFILE_DIR/system_age.prom.$$"
      OUTPUT_FILE="$TEXTFILE_DIR/system_age.prom"

      mkdir -p "$TEXTFILE_DIR"

      # mtime of the flake lock = "when were inputs last updated".
      # Default to 0 if the file is somehow missing so the rule fires loudly
      # rather than going silently absent.
      if [ -f /etc/nixos/flake.lock ]; then
        flake_lock_mtime=$(stat -c %Y /etc/nixos/flake.lock)
      else
        flake_lock_mtime=0
      fi

      # mtime of the system profile link = "when did the current generation go
      # live". Repointed by nixos-rebuild on every successful switch/boot.
      if [ -e /nix/var/nix/profiles/system ]; then
        generation_mtime=$(stat -c %Y /nix/var/nix/profiles/system)
      else
        generation_mtime=0
      fi

      cat > "$TEMP_FILE" << EOF
      # HELP system_flake_lock_mtime_seconds Unix mtime of /etc/nixos/flake.lock (when flake inputs were last updated)
      # TYPE system_flake_lock_mtime_seconds gauge
      system_flake_lock_mtime_seconds $flake_lock_mtime

      # HELP system_current_generation_build_timestamp_seconds Unix mtime of the /nix/var/nix/profiles/system link (when the current NixOS generation went live)
      # TYPE system_current_generation_build_timestamp_seconds gauge
      system_current_generation_build_timestamp_seconds $generation_mtime
      EOF

      # Atomic publish to avoid partial reads by the node-exporter collector.
      mv "$TEMP_FILE" "$OUTPUT_FILE"
      chmod 644 "$OUTPUT_FILE"
    '';
  };
in
{
  # ============================================================================
  # System-Age Prometheus Exporter
  # Daily textfile collector answering "is the system being patched?"
  # ============================================================================

  systemd.timers."system-age-exporter" = {
    description = "System-Age Exporter Timer (is the system being patched?)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Once shortly after boot, then daily. Persistent so a missed daily run
      # (host off) fires on the next boot rather than skipping silently.
      OnBootSec = "5min";
      OnCalendar = "daily";
      Persistent = true;
      Unit = "system-age-exporter.service";
    };
  };

  systemd.services."system-age-exporter" = {
    description = "System-Age Exporter (flake.lock + generation mtimes)";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe system-age-exporter}";
      User = "root";
      Group = "root";
      # Security hardening (mirrors asymmetric-routing-exporter.nix).
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
    };
  };
}
