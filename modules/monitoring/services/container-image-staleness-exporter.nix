{
  config,
  lib,
  pkgs,
  ...
}:

# Moving-tag container image staleness / update-drift -> Prometheus textfile.
#
# Decision (deferred-specs worklist "image-staleness-drift"):
#   - skopeo-based daily digest-drift collector for MOVING-TAG containers.
#   - Compares each running container's local ARCH-SPECIFIC image digest
#     (podman image inspect --format '{{.Digest}}') against the same tag's
#     remote arm64 sub-manifest digest, fetched with `skopeo inspect --raw`
#     (NO pull). Emits container_image_outdated{name,image} (1 if the running
#     digest != the upstream tag's arm64 digest), container_image_local_age_days
#     {name} (days since the running image was built upstream, .Created), and
#     image_staleness_scan_last_success_timestamp_seconds (sweep dead-man).
#   - Vulnerability/CVE semantics are explicitly OUT OF SCOPE — that is
#     container-cve-exporter.nix's job. This collector answers only "is the
#     running image behind its moving tag, and for how long".
#
# Why skopeo + --raw (not plain `skopeo inspect`, not `podman manifest inspect`):
#   `skopeo inspect docker://<ref>` reports the multi-arch INDEX digest, which
#   never equals the running container's arch sub-manifest digest — comparing
#   the two false-positives forever. `skopeo inspect --raw docker://<ref>`
#   returns the raw manifest LIST, from which we pick the arm64 entry's digest
#   ourselves. Verified live 2026-06-10: wallabag/shlink remote arm64
#   digest == local .Digest (MATCH), speedtest-tracker differs (a real pending
#   update) — arch-correct, no spurious drift. (vulcan is aarch64.)
#
# How container images are ACTUALLY refreshed today (read-only context, do NOT
# touch): modules/maintenance/timers.nix defines update-containers.{service,
# timer} (OnCalendar=daily, RandomizedDelaySec=30m, Persistent). Its script
# (updateContainersScript) iterates a root sweep + the CONTAINER_USERS rootless
# list, runs `podman pull` per quadlet image, and restarts only the units whose
# image changed. So drift is normally self-correcting within ~24h of any
# upstream push. This collector is the INDEPENDENT ground-truth signal that the
# pull path is actually advancing each image; container_image_outdated stays 1
# only when that nightly pull has demonstrably failed to keep an image current.
#   NOTE: enabling native `podman-auto-update` (io.containers.autoupdate labels
#   + the podman-auto-update.timer, currently dormant/linked) would DUPLICATE
#   and conflict with update-containers' controlled pull-then-restart logic — it
#   is a SEPARATE operator decision, intentionally NOT enabled here.
#
# Registry rate-limit posture: daily cadence + RandomizedDelaySec jitter, ~15
# `skopeo inspect --raw` calls per run (metadata-only, far cheaper than a pull,
# well under docker.io's anonymous ceiling of 100 pulls/6h). All three
# registries in use (ghcr.io / docker.io / lscr.io) answer anonymously — no
# credentials configured or required, no secrets touched. On a per-image fetch
# failure (registry outage / throttle / transient DNS) the sweep does NOT abort:
# image_staleness_scan_failed{name} is set to 1 and that image is skipped, so a
# blip never wipes the whole textfile.
#
# Output is digest hashes + epoch integers only (never registry creds, env, or
# file contents), written 0644 to the node-exporter textfile dir like every
# other collector. No new listening port (textfile-scraped). Runs as root to
# sudo -u into the 0700 per-user rootless stores, identical privilege posture to
# container-store-size-exporter / container-cve-exporter.

let
  # Rootless quadlet users with a persistent podman store. DERIVED, not copied:
  # a user has a per-user podman graphroot iff its Home Manager home lives under
  # /var/lib/containers/. This is the same structural predicate that
  # modules/users/home-manager/rootless-podman-image-prune.nix:38 uses to decide
  # which users get the weekly image-prune timer, so the two can never disagree.
  #
  # Verified 2026-07-29 by `nix eval`: yields the derived rootless-container-user set, which used to be
  # hand-listed here, in container-health-exporter.nix, in container-cve-exporter.nix
  # and in maintenance/timers.nix. Structural exclusions, all correct:
  #   - technitium-dns-exporter: ROOT podman quadlet, no HM user — covered by the
  #     root sweep below, and its localhost/* image has no upstream tag to drift
  #     against. (config.users.users would wrongly include it: 15 names. That is
  #     why this derives from home-manager.users, not users.users.)
  #   - zimit: transient on-demand containers, no persistent PODMAN_SYSTEMD_UNIT.
  #   - johnw: human account (/home/johnw).
  # Other root quadlets (matter-server, budget-board-{client,server},
  # wyoming-openai) likewise fall under the root sweep below.
  rootlessUsers = lib.filter (
    u: lib.hasPrefix "/var/lib/containers/" config.home-manager.users.${u}.home.homeDirectory
  ) (lib.attrNames config.home-manager.users);

  rootlessUsersShell = lib.concatStringsSep " " rootlessUsers;
in
{
  systemd.services.container-image-staleness-exporter = {
    description = "Moving-tag container image staleness/drift exporter (skopeo) -> textfile";
    after = [
      "network-online.target"
      "podman.service"
    ];
    wants = [ "network-online.target" ]; # remote manifest fetch needs egress
    # No wantedBy - runs via timer only.

    serviceConfig = {
      Type = "oneshot";
      # Needs root to sudo -u into the 0700 per-user rootless stores and to read
      # the root podman graphroot.
      User = "root";
      Group = "root";

      # ~15 metadata-only registry fetches; generous ceiling for a slow registry.
      TimeoutStartSec = "15min";
      # Never compete with live services.
      Nice = 15;
      IOSchedulingClass = "idle";

      # Persists the first-seen-outdated epoch per (name,image) ACROSS daily runs
      # so we can emit container_image_outdated_since_days without relying on
      # Prometheus `for:` (which resets on every prometheus restart and cannot
      # span the multi-day window this rule needs). 0750 root.
      StateDirectory = "container-image-staleness";
      StateDirectoryMode = "0750";
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];

      ExecStart = pkgs.writeShellScript "container-image-staleness-exporter" ''
        set -uo pipefail

        SKOPEO="${pkgs.skopeo}/bin/skopeo"
        JQ="${pkgs.jq}/bin/jq"
        PODMAN="${pkgs.podman}/bin/podman"
        SUDO="${pkgs.sudo}/bin/sudo"
        DATE="${pkgs.coreutils}/bin/date"

        METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/container_image_staleness.prom"
        METRICS_TMP="$METRICS_FILE.tmp"

        # Cross-run state: "<name>\t<image>\t<first_outdated_epoch>" per line.
        STATE_DIR=/var/lib/container-image-staleness
        STATE_FILE="$STATE_DIR/first_outdated.tsv"
        STATE_TMP="$STATE_FILE.tmp"
        mkdir -p "$STATE_DIR"
        : > "$STATE_TMP"

        # vulcan is aarch64 — compare arm64-to-arm64. Pinning the arch is what
        # keeps this correct (index-vs-arch comparison would drift forever).
        ARCH="arm64"
        NOW=$($DATE +%s)

        # first_outdated_epoch <name> <image> -- looks up the prior run's
        # first-seen-outdated timestamp for this (name,image); empty if never.
        first_outdated_epoch() {
          local n="$1" i="$2"
          [[ -f "$STATE_FILE" ]] || return 0
          ${pkgs.gawk}/bin/awk -F'\t' -v n="$n" -v i="$i" \
            '$1==n && $2==i {print $3; exit}' "$STATE_FILE"
        }

        {
          echo "# HELP container_image_outdated Running arch-digest differs from the upstream moving tag (1=outdated,0=current)"
          echo "# TYPE container_image_outdated gauge"
          echo "# HELP container_image_outdated_since_days Days the running image has been outdated vs its moving tag (0 when current)"
          echo "# TYPE container_image_outdated_since_days gauge"
          echo "# HELP container_image_local_age_days Days since the running image was built upstream (image .Created)"
          echo "# TYPE container_image_local_age_days gauge"
          echo "# HELP image_staleness_scan_failed Remote manifest fetch failed for this image this run (1=failed,0=ok)"
          echo "# TYPE image_staleness_scan_failed gauge"
          echo "# HELP image_staleness_scan_last_success_timestamp_seconds Unix time the whole staleness sweep last completed"
          echo "# TYPE image_staleness_scan_last_success_timestamp_seconds gauge"
        } > "$METRICS_TMP"

        # remote_arm64_digest <ref> -- echo the arm64 sub-manifest digest from
        # the upstream manifest list, or "" on any failure. --raw returns the
        # manifest WITHOUT pulling. For a single-arch image (no .manifests list)
        # the raw manifest has no digest of its own; fall back to skopeo's
        # computed manifest digest via `inspect` .Digest in that branch (single
        # arch => index digest == the only arch digest, so no mismatch).
        remote_arm64_digest() {
          local ref="$1" raw d
          raw=$(timeout 60 "$SKOPEO" inspect --raw "docker://$ref" 2>/dev/null) || return 1
          [[ -z "$raw" ]] && return 1
          if printf '%s' "$raw" | "$JQ" -e '.manifests' >/dev/null 2>&1; then
            d=$(printf '%s' "$raw" | "$JQ" -r --arg a "$ARCH" \
              '[.manifests[] | select(.platform.architecture==$a)] | (.[0].digest // "")' 2>/dev/null)
          else
            # single-arch manifest: ask skopeo for its computed digest
            d=$(timeout 60 "$SKOPEO" inspect "docker://$ref" 2>/dev/null \
              | "$JQ" -r '.Digest // ""' 2>/dev/null)
          fi
          [[ -n "$d" && "$d" != "null" ]] || return 1
          printf '%s' "$d"
        }

        # sweep <podman-cmd> -- enumerate running quadlet containers and emit the
        # staleness series per container. Reads into an array FIRST (not a
        # `while read` pipe) so the STATE_TMP appends survive in this shell.
        sweep() {
          local pcmd="$1" line name image registry
          local -a lines=()
          while IFS= read -r line; do lines+=("$line"); done < <(
            $pcmd ps --filter "label=PODMAN_SYSTEMD_UNIT" \
              --format "{{.Names}}	{{.Image}}" 2>/dev/null
          )
          for line in "''${lines[@]}"; do
            name="''${line%%	*}"; image="''${line#*	}"
            [[ -z "$name" || -z "$image" || "$name" == "$image" ]] && continue
            # Skip locally-built images (no upstream tag to drift against).
            case "$image" in localhost/*) continue ;; esac
            registry="''${image%%/*}"

            # Local build age (best-effort; emitted whenever .Created parses).
            local created age_days
            # Ask podman for RFC3339 rather than its default rendering. `{{.Created}}`
            # emits Go's native time.Time string -- "2025-08-14 08:01:41.197445042
            # +0000 UTC" -- and GNU date REFUSES that: it will not accept a trailing
            # " UTC" after an explicit "+0000" numeric offset. `date -d` exited 1 on
            # every image, so the guard below never passed and
            # container_image_local_age_days had NEVER emitted a single sample since
            # the exporter was written. The metric name was absent from Prometheus's
            # __name__ index entirely, which is how it was finally spotted.
            #
            # Formatting on podman's side rather than stripping " UTC" in shell,
            # because that survives podman changing its default rendering again.
            # Verified 2026-08-20 against all 11 images this exporter actually
            # inspects (it enumerates running containers, so dangling <none> images
            # never reach it): 11/11 parse, ages 1-317 days.
            created=$($pcmd image inspect "$image" --format '{{.Created.Format "2006-01-02T15:04:05Z07:00"}}' 2>/dev/null || echo "")
            if [[ -n "$created" ]]; then
              local created_epoch
              created_epoch=$($DATE -d "$created" +%s 2>/dev/null || echo "")
              if [[ -n "$created_epoch" ]]; then
                age_days=$(( (NOW - created_epoch) / 86400 ))
                echo "container_image_local_age_days{name=\"$name\",image=\"$image\",registry=\"$registry\"} $age_days" >> "$METRICS_TMP"
              fi
            fi

            # Local running arch sub-manifest digest.
            local local_digest
            local_digest=$($pcmd image inspect "$image" --format '{{.Digest}}' 2>/dev/null || echo "")

            # Remote arm64 digest (no pull). On failure: mark scan_failed, skip
            # the outdated comparison, but PRESERVE any prior first-outdated state
            # so a transient blip doesn't reset the since-days clock.
            local remote_digest
            if ! remote_digest=$(remote_arm64_digest "$image"); then
              echo "image_staleness_scan_failed{name=\"$name\",image=\"$image\",registry=\"$registry\"} 1" >> "$METRICS_TMP"
              local prior_blip
              prior_blip=$(first_outdated_epoch "$name" "$image")
              if [[ -n "$prior_blip" ]]; then
                printf '%s\t%s\t%s\n' "$name" "$image" "$prior_blip" >> "$STATE_TMP"
              fi
              continue
            fi
            echo "image_staleness_scan_failed{name=\"$name\",image=\"$image\",registry=\"$registry\"} 0" >> "$METRICS_TMP"

            # Outdated comparison (only when both digests are known).
            if [[ -n "$local_digest" && -n "$remote_digest" ]]; then
              local out since_days prior
              if [[ "$local_digest" == "$remote_digest" ]]; then
                out=0
                since_days=0
                # current => clear any persisted first-outdated marker
              else
                out=1
                prior=$(first_outdated_epoch "$name" "$image")
                if [[ -z "$prior" ]]; then
                  prior=$NOW           # first run we observed this drift
                fi
                since_days=$(( (NOW - prior) / 86400 ))
                printf '%s\t%s\t%s\n' "$name" "$image" "$prior" >> "$STATE_TMP"
              fi
              echo "container_image_outdated{name=\"$name\",image=\"$image\",registry=\"$registry\"} $out" >> "$METRICS_TMP"
              echo "container_image_outdated_since_days{name=\"$name\",image=\"$image\",registry=\"$registry\"} $since_days" >> "$METRICS_TMP"
            fi
          done
        }

        # Root podman store (matter-server, budget-board-*, wyoming-openai, ...).
        sweep "$PODMAN"

        # Rootless per-user stores. zimit + johnw excluded by construction.
        for u in ${rootlessUsersShell}; do
          if id "$u" &>/dev/null; then
            sweep "$SUDO -u $u $PODMAN"
          fi
        done

        # Persist the updated first-outdated state atomically.
        mv "$STATE_TMP" "$STATE_FILE"
        chmod 0640 "$STATE_FILE" 2>/dev/null || true

        # Sweep-complete dead-man marker.
        echo "image_staleness_scan_last_success_timestamp_seconds $($DATE +%s)" >> "$METRICS_TMP"

        mv "$METRICS_TMP" "$METRICS_FILE"
        chmod 0644 "$METRICS_FILE"
      '';
    };
  };

  systemd.timers.container-image-staleness-exporter = {
    description = "Moving-tag container image staleness exporter timer (daily)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Run AFTER update-containers (~00:08-00:38) so the read reflects the
      # freshly-pulled state and rarely fires transiently. Fixed slot rather
      # than After= ordering (timers don't order cleanly against oneshots).
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
      AccuracySec = "1m";
    };
  };

  # Alert rules: modules/monitoring/alerts/container-health.yaml (auto-discovered
  # by alerting.nix). ContainerImageOutdated fires on
  # container_image_outdated_since_days > 30 (warning) — a refresh nudge, not a
  # restart-fragile `for: 30d`.
}
