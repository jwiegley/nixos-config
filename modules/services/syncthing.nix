{
  config,
  inputs,
  lib,
  pkgs,
  utils,
  ...
}:

let
  guiPort = 8384;
  syncPort = 22000;
  seedDir = "/var/lib/syncthing-seed";
  syncthingPackage =
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.syncthing.overrideAttrs
      (
        _finalAttrs: _previousAttrs: {
          version = "2.1.3";
          src = pkgs.fetchFromGitHub {
            owner = "syncthing";
            repo = "syncthing";
            rev = "v2.1.3";
            hash = "sha256-uTjmOAjis2eBm2SnZbyvDDiQXKN8De+DhjNHbFLLbn0=";
          };
          vendorHash = "sha256-ueUf9YEa5z7mG6MofIJ3Xco+PxVPi/85Rdi+1aean6c=";
        }
      );

  devices = {
    hera = {
      id = "MDOPNSZ-WLGJBFD-4YUV4S3-QEUZGWP-TLIRRVK-ZXFJ7Q2-IJ3FRBO-ZQVRPAD";
      addresses = [ "tcp://192.168.1.4:${toString syncPort}" ];
      allowedNetworks = [ "192.168.1.4/32" ];
      autoAcceptFolders = false;
      introducer = false;
      untrusted = false;
      paused = false;
      compression = "metadata";
    };
  };

  folders = {
    obsidian = {
      label = "Obsidian";
      path = "/tank/doc/obsidian";
      dataset = "tank/doc";
      mode = "0700";
      devices = [ "hera" ];
      ignorePatterns = [
        "(?d).DS_Store"
        "/.git"
      ];
    };
    desktop = {
      label = "Desktop";
      path = "/tank/Desktop";
      dataset = "tank/Desktop";
      mode = "0700";
      devices = [ "hera" ];
      ignorePatterns = [ "(?d).DS_Store" ];
    };
  };

  folderList = lib.attrValues folders;
  folderPaths = map (folder: folder.path) folderList;
  datasets = lib.unique (map (folder: folder.dataset) folderList);
  mountpointOf = dataset: "/${dataset}";
  datasetMounts = map mountpointOf datasets;
  mountUnits = map (mountpoint: "${utils.escapeSystemdPath mountpoint}.mount") datasetMounts;
  ancestorsWithin =
    folder:
    let
      mountpoint = mountpointOf folder.dataset;
      between = lib.init (lib.splitString "/" (lib.removePrefix (mountpoint + "/") folder.path));
    in
    if folder.path == mountpoint then
      [ ]
    else
      lib.foldl' (acc: component: acc ++ [ "${lib.last acc}/${component}" ]) [ mountpoint ] between;
  deviceIdFormat = "[A-Z2-7]{7}(-[A-Z2-7]{7}){7}";
in
{
  assertions = [
    {
      assertion = syncthingPackage.version == "2.1.3";
      message = "Vulcan's Syncthing package must remain pinned to 2.1.3";
    }
  ]
  ++ lib.mapAttrsToList (name: device: {
    assertion = builtins.match deviceIdFormat device.id != null;
    message = "Syncthing device ${name} does not have a valid pinned device ID";
  }) devices
  ++ lib.mapAttrsToList (id: folder: {
    assertion = lib.all (device: lib.hasAttr device devices) folder.devices;
    message = "Syncthing folder ${id} references an undeclared device";
  }) folders
  ++ lib.mapAttrsToList (id: folder: {
    assertion =
      folder.path == mountpointOf folder.dataset
      || lib.hasPrefix (mountpointOf folder.dataset + "/") folder.path;
    message = "Syncthing folder ${id} is outside its declared ZFS dataset";
  }) folders;

  services.syncthing = {
    enable = true;
    package = syncthingPackage;
    cert = "${seedDir}/cert.pem";
    key = "${seedDir}/key.pem";
    guiAddress = "127.0.0.1:${toString guiPort}";
    openDefaultPorts = false;
    overrideDevices = true;
    overrideFolders = true;

    settings = {
      inherit devices;
      folders = lib.mapAttrs (
        _: folder:
        {
          type = "sendreceive";
          filesystemType = "basic";
          fsWatcherEnabled = true;
          fsWatcherDelayS = 1.0;
          fsWatcherTimeoutS = 0.0;
          rescanIntervalS = 300;
          # The local POSIX ACL, not remote mode bits, keeps both the service
          # account and johnw able to work with newly received files.
          ignorePerms = true;
          autoNormalize = true;
          syncOwnership = false;
          sendOwnership = false;
          copyOwnershipFromParent = false;
          # POSIX ACLs and macOS metadata are host-local policy.
          syncXattrs = false;
          sendXattrs = false;
        }
        // removeAttrs folder [
          "dataset"
          "mode"
        ]
      ) folders;
      options = {
        listenAddresses = [ "tcp://192.168.1.2:${toString syncPort}" ];
        alwaysLocalNets = [ "192.168.1.4/32" ];
        reconnectionIntervalS = 5;
        globalAnnounceEnabled = false;
        globalAnnounceServers = [ ];
        localAnnounceEnabled = false;
        announceLANAddresses = false;
        relaysEnabled = false;
        natEnabled = false;
        stunServers = [ ];
        urAccepted = -1;
        crashReportingEnabled = false;
        autoUpgradeIntervalH = 0;
        startBrowser = false;
      };
    };
  };

  networking.firewall.interfaces.end0.allowedTCPPorts = [ syncPort ];

  systemd.services = {
    syncthing = {
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
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/syncthing" ] ++ folderPaths;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        LockPersonality = true;
        MemoryMax = "2G";
        TasksMax = 512;
      };
    };

    syncthing-folder-acls = {
      description = "POSIX ACL grants for Syncthing folders";
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
        pkgs.coreutils
        pkgs.findutils
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail
      ''
      + lib.concatMapStrings (dataset: ''
        acltype=$(zfs get -H -o value acltype ${lib.escapeShellArg dataset})
        if [ "$acltype" != "posix" ] && [ "$acltype" != "posixacl" ]; then
          zfs set acltype=posix ${lib.escapeShellArg dataset}
        fi
      '') datasets
      + lib.concatMapStrings (
        folder:
        let
          path = lib.escapeShellArg folder.path;
          mountpoint = lib.escapeShellArg (mountpointOf folder.dataset);
          traversalGrants = lib.concatMapStrings (
            directory: "setfacl -m u:syncthing:x ${lib.escapeShellArg directory}\n"
          ) (ancestorsWithin folder);
        in
        ''
          [ -d ${path} ] || install -d -m ${folder.mode} -o syncthing -g syncthing ${path}
          chmod ${folder.mode} ${path}

          if ! setfacl -m u:syncthing:rwX ${path} 2>/dev/null; then
            mount -o remount ${mountpoint}
            setfacl -m u:syncthing:rwX ${path}
          fi

          ${traversalGrants}
          setfacl -R \
            -m u:syncthing:rwX \
            -m u:johnw:rwX \
            ${path}
          find ${path} -type d -exec setfacl \
            -m d:u:syncthing:rwX \
            -m d:u:johnw:rwX \
            {} +
        ''
      ) folderList;
    };
  };
}
