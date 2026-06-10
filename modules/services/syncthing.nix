{
  config,
  lib,
  pkgs,
  ...
}:

# Syncthing — two-way sync of /tank/Public with hera (~/Public).
#
# This is the 2026 restoration of the service dropped in June 2025. The 2025
# attempt failed on four self-inflicted wounds, each structurally prevented
# here:
#   1. nginx subpath proxying (/syncthing/ + sub_filter hacks) — now a clean
#      dedicated vhost at https://syncthing.vulcan.lan proxying at /
#      (grafana.nix:289-309 pattern; *.vulcan.lan is a Technitium wildcard).
#   2. Placeholder device IDs ("DEVICE-ID-OF-LAPTOP") with overrideDevices
#      — hera's REAL device ID is pinned below and guarded by a fail-closed
#      assertion (modeled on drafts-mcp.nix's pinned-hostkey assertion).
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
# Write access to /tank/Public (two-way sync): the dataset is multi-owner
# (root parent; aria2/copyparty/johnw subtrees) and had acltype=off, so the
# syncthing-public-acls oneshot enables POSIX ACLs on tank/Public and grants
# u:syncthing rwX (access + default) across the tree — additive, reversible
# (zfs set acltype=off), and ownership-preserving. johnw gets the same grant
# so files arriving from hera (owned syncthing:syncthing) stay editable
# locally. copyparty-ownership-fixup chowns are ACL-preserving, so the two
# mechanisms coexist.

let
  guiPort = 8384; # loopback only — see docs/ports.txt
  syncPort = 22000; # LAN TCP+UDP, sync transport
  discoveryPort = 21027; # LAN UDP, local discovery broadcast

  vhost = "syncthing.vulcan.lan";
  publicDir = "/tank/Public";
  seedDir = "/var/lib/syncthing-seed";
  configDir = "/var/lib/syncthing/.config/syncthing";

  # hera's real syncthing device ID (generated 2026-06-10 on hera from the
  # key pair in ~/.syncthing-staging, installed to
  # ~/Library/Application Support/Syncthing at deploy). A hera reinstall that
  # regenerates keys MUST update this pin — sync silently stops otherwise.
  heraDeviceId = "BZLR7L3-232RGLB-HWRZNFV-W3IPNB2-NRXL4XE-ZTV2IXC-5DBDPH5-NLPYPQT";

  # 8 dash-separated groups of 7 base32 chars. Fail-closed guard against the
  # 2025 placeholder-ID mistake: an unfilled/typo'd ID aborts evaluation.
  deviceIdOk = builtins.match "[A-Z2-7]{7}(-[A-Z2-7]{7}){7}" heraDeviceId != null;
in
{
  assertions = [
    {
      assertion = deviceIdOk;
      message = ''
        services/syncthing.nix: heraDeviceId is not a well-formed syncthing
        device ID. Refusing to deploy a placeholder (the 2025 failure mode):
        overrideDevices=true would delete the real peer.
      '';
    }
  ];

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

      devices.hera = {
        id = heraDeviceId;
        # Explicit address first; "dynamic" falls back to local discovery.
        addresses = [
          "tcp://hera.lan:${toString syncPort}"
          "dynamic"
        ];
      };

      folders."tank-public" = {
        path = publicDir;
        label = "Public";
        devices = [ "hera" ];
        type = "sendreceive";
        # Written to /tank/Public/.stignore via the REST API by
        # syncthing-init. hera mirrors these (plus macOS-only entries like
        # "Drop Box") in its own .stignore — ignores are per-device and NOT
        # synced, so both sides need them. No versioning: vulcan-side history
        # is already covered by hourly sanoid snapshots of tank.
        ignorePatterns = [
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
      };

      options = {
        # LAN-only posture: no global discovery, no relays, no NAT traversal,
        # no phone-home. Local discovery + the pinned address are sufficient.
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
      # wait for the dataset, start when it appears, skip cleanly when tank
      # is absent (flaky USB enclosure — bindTankModule.nix rationale).
      after = [
        "zfs.target"
        "zfs-import-tank.service"
        "tank-Public.mount"
      ];
      wantedBy = [ "tank-Public.mount" ];
      unitConfig = {
        RequiresMountsFor = [ publicDir ];
        ConditionPathIsMountPoint = publicDir;
      };
      # Upstream hardening lacks filesystem confinement entirely (no
      # ProtectSystem/ProtectHome/ReadWritePaths) — add the repo-canonical
      # strict block (glances.nix:98-121). Keys below are disjoint from the
      # upstream serviceConfig, so no mkForce is needed.
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          "/var/lib/syncthing"
          publicDir
        ];
        # AF_NETLINK: syncthing enumerates interfaces for local discovery.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        LockPersonality = true;

        # Resource limits (initial scan hashes the full 5.4G dataset).
        MemoryMax = "2G";
        TasksMax = 128;
      };
    };

    # Enables POSIX ACLs on tank/Public (acltype was `off`) and grants the
    # syncthing and johnw users rwX across the tree — access ACLs for
    # existing entries, default ACLs so future files/dirs created by ANY
    # owner (copyparty, aria2, johnw, syncthing) inherit the grants. ~3.6k
    # files, so the recursive pass is instant; it re-runs before every
    # syncthing start, which also heals ACL-less files restored from backup.
    syncthing-public-acls = {
      description = "POSIX ACL grants for syncthing on /tank/Public";
      requiredBy = [ "syncthing.service" ];
      before = [ "syncthing.service" ];
      after = [
        "zfs.target"
        "zfs-import-tank.service"
        "tank-Public.mount"
      ];
      unitConfig = {
        RequiresMountsFor = [ publicDir ];
        ConditionPathIsMountPoint = publicDir;
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

        acltype=$(zfs get -H -o value acltype tank/Public)
        if [ "$acltype" != "posix" ] && [ "$acltype" != "posixacl" ]; then
          echo "Enabling POSIX ACLs on tank/Public (was: $acltype)"
          zfs set acltype=posix tank/Public
        fi

        # acltype is normally applied live; remount once if the VFS layer
        # hasn't picked it up yet.
        if ! setfacl -m u:syncthing:rwX ${publicDir} 2>/dev/null; then
          echo "setfacl failed post-property-change; remounting ${publicDir}"
          mount -o remount ${publicDir}
          setfacl -m u:syncthing:rwX ${publicDir}
        fi

        setfacl -R \
          -m u:syncthing:rwX -m d:u:syncthing:rwX \
          -m u:johnw:rwX     -m d:u:johnw:rwX \
          ${publicDir}
      '';
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
           && [ "$(jq -r .apiKey <<<"$cur")" = "$want_key" ]; then
          echo "GUI user and API key already pinned"
          exit 0
        fi

        # --rawfile keeps the key value off argv (only the sops path appears
        # in /proc cmdline); rtrimstr drops the file's trailing newline.
        jq -n --arg u "$gui_user" \
          --rawfile k ${config.sops.secrets."syncthing/api-key".path} \
          '{user: $u, apiKey: ($k | rtrimstr("\n"))}' \
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
