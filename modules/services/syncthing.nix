{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

# Syncthing — declarative two-way LAN sync of tank directories with hera.
#
# Folders are declared exactly once in the `folders` attrset below. The
# syncthing folder settings, the ZFS mount gating, the sandbox write grants,
# and the ACL oneshot are all derived from that attrset, and the Nagios
# folder-completion check follows it automatically (syncthing-nagios.nix
# reads config.services.syncthing.settings.folders). Adding a synced
# directory is a single new entry — see the comment above `folders`.
#
# This is the 2026 restoration of the service dropped in June 2025. The 2025
# attempt failed on four self-inflicted wounds, each structurally prevented
# here:
#   1. nginx subpath proxying (/syncthing/ + sub_filter hacks) — now a clean
#      dedicated vhost at https://syncthing.vulcan.lan proxying at /
#      (grafana.nix:289-309 pattern; *.vulcan.lan is a Technitium wildcard).
#   2. Placeholder device IDs ("DEVICE-ID-OF-LAPTOP") with overrideDevices
#      — every peer's REAL device ID is pinned in `devices` and guarded by a
#      fail-closed assertion (modeled on drafts-mcp.nix's pinned-hostkey
#      assertion).
#   3. GUI credentials committed to git — the GUI password and API key live
#      only in sops (secrets.yaml: syncthing/gui-password, syncthing/api-key).
#   4. guiAddress 0.0.0.0 — the GUI binds 127.0.0.1 only; the LAN sees it
#      solely through the TLS vhost.
#
# Identity: the device key/cert pair is seeded from /var/lib/syncthing-seed
# (root-owned, populated at deploy time from the pre-generated identity) so
# vulcan's device ID survives a /var/lib/syncthing wipe. The upstream module
# re-installs them into configDir on every start (ExecStartPre).
#
# API-key stability (IMPORTANT, verified empirically 2026-06-10): a partial
# PUT to /rest/config/gui ZEROES omitted fields and syncthing regenerates the
# apikey — and syncthing-init PUTs settings.gui if it is declared. Therefore
# settings.gui is deliberately ABSENT below; the GUI user and the sops-pinned
# API key are applied by the syncthing-gui-pin oneshot via PATCH (which
# merges, never rotates). The sops API key is the single stable credential
# used by the Prometheus scrape (syncthing-metrics.nix) and the Nagios sync
# check (syncthing-nagios.nix); nagios and prometheus can both read it
# because they are members of the johnw group (gid 990).
#
# Write access to synced folders (two-way sync): tank datasets are
# multi-owner (e.g. tank/Public: aria2/copyparty/johnw subtrees) and shipped
# with acltype=off, so the syncthing-folder-acls oneshot enables POSIX ACLs
# on each folder's backing dataset and grants u:syncthing rwX (access +
# default) across each folder tree — additive, reversible (zfs set
# acltype=off), and ownership-preserving. Folders sitting below their
# dataset mountpoint additionally get search-only (x) grants on the parent
# directories in between (e.g. /tank/Video is 750 johnw:immich and would
# otherwise block traversal entirely). johnw gets the same rwX grant so
# files arriving from hera (owned syncthing:syncthing) stay editable
# locally. copyparty-ownership-fixup chowns are ACL-preserving, so the two
# mechanisms coexist on tank/Public.

let
  guiPort = 8384; # loopback only — see docs/ports.txt
  syncPort = 22000; # LAN TCP+UDP, sync transport
  discoveryPort = 21027; # LAN UDP, local discovery broadcast

  vhost = "syncthing.vulcan.lan";
  seedDir = "/var/lib/syncthing-seed";
  configDir = "/var/lib/syncthing/.config/syncthing";

  # -------------------------------------------------------------------------
  # Peers. Attr name = syncthing device name (referenced from
  # folders.<id>.devices); the body lands in settings.devices verbatim.
  # Device IDs are public key fingerprints — safe in git, but they MUST be
  # real: a reinstall that regenerates a peer's keys has to update the pin
  # here, or sync silently stops. A malformed ID aborts evaluation (see
  # assertions below).
  devices = {
    # hera's real syncthing device ID (generated 2026-06-10 on hera from the
    # key pair in ~/.syncthing-staging, installed to
    # ~/Library/Application Support/Syncthing at deploy).
    hera = {
      id = "BZLR7L3-232RGLB-HWRZNFV-W3IPNB2-NRXL4XE-ZTV2IXC-5DBDPH5-NLPYPQT";
      # Explicit address first; "dynamic" falls back to local discovery.
      addresses = [
        "tcp://hera.lan:${toString syncPort}"
        "dynamic"
      ];
    };
  };

  # macOS metadata junk that hera would otherwise sync over. Written to
  # <folder>/.stignore via the REST API by syncthing-init; ignores are
  # per-device and NOT synced, so hera mirrors these (plus macOS-only
  # entries like "Drop Box") in its own .stignore.
  macosJunk = [
    ".DS_Store"
    "._*"
    ".Spotlight-V100"
    ".Trashes"
    ".fseventsd"
    ".TemporaryItems"
    ".localized"
    "desktop.ini"
    "Thumbs.db"
  ];

  # -------------------------------------------------------------------------
  # Synced folders — the ONE place to declare a sync. Attr name = syncthing
  # folder ID. `dataset` names the backing ZFS dataset (it drives the mount
  # gating and the ACL oneshot; the folder path may sit below the dataset
  # mountpoint). Everything except `dataset` is passed to
  # settings.folders.<id> verbatim (label, path, devices, type,
  # ignorePatterns, versioning, ...); type defaults to "sendreceive".
  # No versioning on any folder: vulcan-side history is already covered by
  # sanoid snapshots of tank.
  #
  # Adding a folder:
  #   1. Add an entry here. A missing folder directory is created (and
  #      ACL-granted) by syncthing-folder-acls before syncthing starts.
  #   2. Rebuild: syncthing-init applies the config and offers the share to
  #      the listed peers.
  #   3. Accept the share on each peer, choosing its local path there.
  folders = {
    tank-public = {
      label = "Public";
      path = "/tank/Public";
      dataset = "tank/Public";
      devices = [ "hera" ];
      ignorePatterns = macosJunk;
    };
  };

  # ---- derived from `folders` — nothing below changes per folder ----------
  folderList = lib.attrValues folders;
  folderPaths = map (f: f.path) folderList;
  # Backing datasets (deduped: folders may share one). All tank datasets
  # mount at /<dataset-name>, so the mountpoint is derived, not declared.
  datasets = lib.unique (map (f: f.dataset) folderList);
  mountpointOf = ds: "/${ds}";
  datasetMounts = map mountpointOf datasets;
  mountUnits = map (mp: "${utils.escapeSystemdPath mp}.mount") datasetMounts;

  # Directories between a folder's dataset mountpoint (inclusive) and the
  # folder path (exclusive). The syncthing user needs search (x) on each of
  # them to reach a folder that sits below its dataset mountpoint —
  # /tank/Video is 750 johnw:immich, which stalled syncthing-init in a
  # stat-permission-denied retry loop on first deploy of tank-video-inbox
  # (2026-06-10). Empty when the folder path IS the mountpoint.
  ancestorsWithin =
    f:
    let
      mp = mountpointOf f.dataset;
      between = lib.init (lib.splitString "/" (lib.removePrefix (mp + "/") f.path));
    in
    if f.path == mp then [ ] else lib.foldl' (acc: c: acc ++ [ "${lib.last acc}/${c}" ]) [ mp ] between;

  # 8 dash-separated groups of 7 base32 chars.
  deviceIdFormat = "[A-Z2-7]{7}(-[A-Z2-7]{7}){7}";
in
{
  assertions =
    # Fail-closed guard against the 2025 placeholder-ID mistake: an
    # unfilled/typo'd device ID aborts evaluation.
    lib.mapAttrsToList (name: dev: {
      assertion = builtins.match deviceIdFormat dev.id != null;
      message = ''
        services/syncthing.nix: devices.${name}.id is not a well-formed
        syncthing device ID. Refusing to deploy a placeholder (the 2025
        failure mode): overrideDevices=true would delete the real peer.
      '';
    }) devices
    # A folder referencing an undeclared device would otherwise fail only at
    # runtime, inside syncthing-init.
    ++ lib.mapAttrsToList (id: f: {
      assertion = lib.all (d: lib.hasAttr d devices) (f.devices or [ ]);
      message = ''
        services/syncthing.nix: folders.${id}.devices references a device
        missing from the `devices` attrset.
      '';
    }) folders
    # ancestorsWithin and the mount gating both assume the folder lives on
    # its declared dataset.
    ++ lib.mapAttrsToList (id: f: {
      assertion = f.path == mountpointOf f.dataset || lib.hasPrefix (mountpointOf f.dataset + "/") f.path;
      message = ''
        services/syncthing.nix: folders.${id}.path (${f.path}) is not at or
        below the mountpoint of its declared dataset (${f.dataset}).
      '';
    }) folders;

  services.syncthing = {
    enable = true;

    # Defaults made explicit because they are load-bearing here: the GUI (and
    # the REST API + /metrics behind it) must never leave loopback, and the
    # firewall is scoped manually below instead of via openDefaultPorts.
    guiAddress = "127.0.0.1:${toString guiPort}";
    openDefaultPorts = false;

    # Stable identity: re-installed into configDir on every service start.
    cert = "${seedDir}/cert.pem";
    key = "${seedDir}/key.pem";

    # Plaintext GUI password from sops; syncthing-init bcrypt-hashes it and
    # PATCHes /rest/config/gui (never lands in git or the nix store).
    guiPasswordFile = config.sops.secrets."syncthing/gui-password".path;

    settings = {
      # NOTE: no `gui` attribute here — see the API-key-stability comment at
      # the top of this file. GUI user + API key are PATCHed by
      # syncthing-gui-pin instead.

      inherit devices;

      # `dataset` is vulcan-side metadata, not a syncthing folder option.
      folders = lib.mapAttrs (_: f: { type = "sendreceive"; } // removeAttrs f [ "dataset" ]) folders;

      options = {
        # LAN-only posture: no global discovery, no relays, no NAT traversal,
        # no phone-home. Local discovery + the pinned addresses are
        # sufficient.
        globalAnnounceEnabled = false;
        relaysEnabled = false;
        natEnabled = false;
        localAnnounceEnabled = true;
        urAccepted = -1;
        crashReportingEnabled = false;
      };
    };
  };

  sops.secrets."syncthing/gui-password" = {
    # Read by syncthing-init (runs as the syncthing user) for the bcrypt
    # PATCH of the GUI password.
    owner = "syncthing";
    mode = "0400";
    restartUnits = [ "syncthing-init.service" ];
  };

  sops.secrets."syncthing/api-key" = {
    # group johnw (gid 990) deliberately: nagios and prometheus are members,
    # so the Nagios sync check and the Prometheus scrape read this same file.
    # Declared once here; consumer modules must NOT re-declare owner/mode
    # (sops-nix definitions conflict) — they only reference .path.
    owner = "syncthing";
    group = "johnw";
    mode = "0440";
    restartUnits = [ "syncthing-gui-pin.service" ];
  };

  # GUI/REST stays on loopback; sync transport + discovery are LAN-facing.
  # Idioms per home-assistant.nix:1209-1222.
  networking.firewall = {
    interfaces."lo".allowedTCPPorts = [ guiPort ]; # syncthing GUI/REST/metrics
    allowedTCPPorts = [ syncPort ]; # syncthing sync transport
    allowedUDPPorts = [
      syncPort # syncthing QUIC transport
      discoveryPort # syncthing local discovery
    ];
  };

  # TLS vhost — step-ca cert; the FQDN is registered in
  # certs/renew-nginx-certs.sh DOMAINS for issuance + monthly renewal.
  # Proxies at / on a dedicated hostname: no subpath rewriting (2025 lesson).
  # proxyWebsockets covers the GUI's event long-poll/websocket stream.
  services.nginx.virtualHosts."${vhost}" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/${vhost}.crt";
    sslCertificateKey = "/var/lib/nginx-certs/${vhost}.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString guiPort}/";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  systemd.services = {
    syncthing = {
      # ZFS gating per immich.nix:74-103 (mirrors aria2.nix / samba.nix):
      # wait for every folder's backing dataset, start when they appear, and
      # skip cleanly while any is absent (flaky USB enclosure —
      # bindTankModule.nix rationale). Multiple Condition entries of the same
      # type AND together: a partially-mounted tank also skips.
      after = [
        "zfs.target"
        "zfs-import-tank.service"
      ]
      ++ mountUnits;
      wantedBy = mountUnits;
      unitConfig = {
        RequiresMountsFor = folderPaths;
        ConditionPathIsMountPoint = datasetMounts;
      };
      # Upstream hardening lacks filesystem confinement entirely (no
      # ProtectSystem/ProtectHome/ReadWritePaths) — add the repo-canonical
      # strict block (glances.nix:98-121). Keys below are disjoint from the
      # upstream serviceConfig, so no mkForce is needed.
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/syncthing" ] ++ folderPaths;
        # AF_NETLINK: syncthing enumerates interfaces for local discovery.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        LockPersonality = true;

        # Resource limits (the initial scan hashes every synced tree).
        # TasksMax counts OS threads: under bulk-transfer load the Go runtime
        # plus SQLite's blocking cgo calls exceeded 128 and pthread_create
        # EAGAIN'd into SIGABRT (two crashes during the 2026-06-10 initial
        # sync). 512 covers peak thread fan-out with margin while still
        # bounding a runaway.
        MemoryMax = "2G";
        TasksMax = 512;
      };
    };

    # Enables POSIX ACLs on each backing dataset (tank datasets shipped with
    # acltype=off) and grants the syncthing and johnw users rwX across every
    # folder tree — access ACLs for existing entries, default ACLs so future
    # files/dirs created by ANY owner (copyparty, aria2, johnw, syncthing)
    # inherit the grants. It re-runs before every syncthing start, which also
    # heals ACL-less files restored from backup, and it creates folder roots
    # that do not exist yet, so freshly-declared folders need no manual
    # mkdir.
    syncthing-folder-acls = {
      description = "POSIX ACL grants for syncthing folders";
      requiredBy = [ "syncthing.service" ];
      before = [ "syncthing.service" ];
      after = [
        "zfs.target"
        "zfs-import-tank.service"
      ]
      ++ mountUnits;
      unitConfig = {
        RequiresMountsFor = folderPaths;
        ConditionPathIsMountPoint = datasetMounts;
      };
      path = [
        config.boot.zfs.package
        pkgs.acl
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
      ''
      + lib.concatMapStrings (ds: ''
        acltype=$(zfs get -H -o value acltype ${lib.escapeShellArg ds})
        if [ "$acltype" != "posix" ] && [ "$acltype" != "posixacl" ]; then
          echo "Enabling POSIX ACLs on ${ds} (was: $acltype)"
          zfs set acltype=posix ${lib.escapeShellArg ds}
        fi
      '') datasets
      + lib.concatMapStrings (
        f:
        let
          path' = lib.escapeShellArg f.path;
          mount' = lib.escapeShellArg (mountpointOf f.dataset);
          # Search-only access ACLs (no default ACLs, nothing recursive) so
          # the syncthing user can traverse 750-style parents down to the
          # folder; see ancestorsWithin.
          traversalGrants = lib.concatMapStrings (d: "setfacl -m u:syncthing:x ${lib.escapeShellArg d}\n") (
            ancestorsWithin f
          );
        in
        ''
          [ -d ${path'} ] || install -d -m 0755 -o syncthing -g syncthing ${path'}

          # acltype is normally applied live; remount once if the VFS layer
          # hasn't picked it up yet.
          if ! setfacl -m u:syncthing:rwX ${path'} 2>/dev/null; then
            echo "setfacl failed post-property-change; remounting ${mountpointOf f.dataset}"
            mount -o remount ${mount'}
            setfacl -m u:syncthing:rwX ${path'}
          fi

          ${traversalGrants}
          setfacl -R \
            -m u:syncthing:rwX -m d:u:syncthing:rwX \
            -m u:johnw:rwX     -m d:u:johnw:rwX \
            ${path'}
        ''
      ) folderList;
    };

    # Pins the GUI user and the sops API key via PATCH /rest/config/gui.
    # PATCH merges (PUT rotates the apikey — verified; see header comment).
    # Idempotent: exits early when both already match.
    syncthing-gui-pin = {
      description = "Pin syncthing GUI user + sops API key";
      requisite = [ "syncthing.service" ];
      after = [
        "syncthing.service"
        "syncthing-init.service"
      ];
      wants = [ "syncthing-init.service" ];
      partOf = [ "syncthing.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.curl
        pkgs.jq
        pkgs.libxml2
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "syncthing-gui-pin";
      };
      script = ''
        set -euo pipefail
        umask 0077

        gui_user="johnw"
        want_key=$(cat ${config.sops.secrets."syncthing/api-key".path})

        # Wait for the daemon to materialize config.xml (first boot).
        for _ in $(seq 1 60); do
          [ -s ${configDir}/config.xml ] && break
          sleep 2
        done

        # Auth via header file, not argv (keys must not hit /proc cmdlines).
        hdr="$RUNTIME_DIRECTORY/headers"
        refresh_hdr() {
          printf 'X-API-Key: %s\n' \
            "$(xmllint --xpath 'string(configuration/gui/apikey)' \
                ${configDir}/config.xml)" > "$hdr"
        }
        api() { curl -sS --retry 30 --retry-delay 2 --retry-all-errors \
                  -H "@$hdr" "$@"; }

        refresh_hdr
        cur=$(api http://127.0.0.1:${toString guiPort}/rest/config/gui)
        if [ "$(jq -r .user <<<"$cur")" = "$gui_user" ] \
           && [ "$(jq -r .apiKey <<<"$cur")" = "$want_key" ] \
           && [ "$(jq -r .insecureSkipHostcheck <<<"$cur")" = "true" ]; then
          echo "GUI user, API key, and host-check setting already pinned"
          exit 0
        fi

        # --rawfile keeps the key value off argv (only the sops path appears
        # in /proc cmdline); rtrimstr drops the file's trailing newline.
        # insecureSkipHostcheck: the GUI sits behind the nginx vhost, whose
        # proxied Host header (syncthing.vulcan.lan) otherwise trips
        # syncthing's DNS-rebinding host check (403). Safe here: GUI auth is
        # enabled, and the listener never leaves loopback — the host check
        # exists to protect unauthenticated localhost GUIs.
        jq -n --arg u "$gui_user" \
          --rawfile k ${config.sops.secrets."syncthing/api-key".path} \
          '{user: $u, apiKey: ($k | rtrimstr("\n")), insecureSkipHostcheck: true}' \
          | api -X PATCH --json @- http://127.0.0.1:${toString guiPort}/rest/config/gui

        # The PATCH may invalidate the old key mid-session; re-read it for
        # the restart-required check (mirrors the upstream init script).
        refresh_hdr
        if api http://127.0.0.1:${toString guiPort}/rest/config/restart-required \
             | jq -e .requiresRestart >/dev/null; then
          api -X POST http://127.0.0.1:${toString guiPort}/rest/system/restart
        fi
        echo "Pinned GUI user + API key"
      '';
    };
  };
}
