{ config, lib, pkgs, ... }:

let
  # List of ZFS filesystems to create Samba shares for
  # Generated from: zfs list -t filesystem -H -o name,mountpoint | grep '^tank' | grep -v 'none\|legacy'
  zfsFilesystems = [
    { name = "tank";                         mountpoint = "/tank"; }
    { name = "tank/Audio";                   mountpoint = "/tank/Audio"; }
    { name = "tank/Backups";                 mountpoint = "/tank/Backups"; }
    { name = "tank/Backups/Assembly";        mountpoint = "/tank/Backups/Assembly"; }
    { name = "tank/Backups/Assembly/Drive";  mountpoint = "/tank/Backups/Assembly/Drive"; }
    { name = "tank/Backups/Git";             mountpoint = "/tank/Backups/Git"; }
    { name = "tank/Backups/Images";          mountpoint = "/tank/Backups/Images"; }
    { name = "tank/Backups/Kadena";          mountpoint = "/tank/Backups/Kadena"; }
    { name = "tank/Backups/Machines";        mountpoint = "/tank/Backups/Machines"; }
    { name = "tank/Backups/Machines/Hera";   mountpoint = "/tank/Backups/Machines/Hera"; }
    { name = "tank/Backups/Machines/Clio";   mountpoint = "/tank/Backups/Machines/Clio"; }
    { name = "tank/Backups/Machines/Vulcan"; mountpoint = "/tank/Backups/Machines/Vulcan"; }
    { name = "tank/Backups/Machines/Athena"; mountpoint = "/tank/Backups/Machines/Athena"; }
    { name = "tank/Backups/Games";           mountpoint = "/tank/Backups/Games"; }
    { name = "tank/Databases";               mountpoint = "/tank/Databases"; }
    { name = "tank/Desktop";                 mountpoint = "/tank/Desktop"; }
    { name = "tank/Documents";               mountpoint = "/tank/Documents"; }
    { name = "tank/Downloads";               mountpoint = "/tank/Downloads"; }
    { name = "tank/Home";                    mountpoint = "/tank/Home"; }
    { name = "tank/Machines";                mountpoint = "/tank/Machines"; }
    { name = "tank/Media";                   mountpoint = "/tank/Media"; }
    { name = "tank/Models";                  mountpoint = "/tank/Models"; }
    { name = "tank/Models/HuggingFace";      mountpoint = "/tank/Models/HuggingFace"; }
    { name = "tank/Models/Llama.cpp";        mountpoint = "/tank/Models/Llama.cpp"; }
    { name = "tank/Movies";                  mountpoint = "/tank/Movies"; }
    { name = "tank/Music";                   mountpoint = "/tank/Music"; }
    { name = "tank/Photos";                  mountpoint = "/tank/Photos"; }
    { name = "tank/Pictures";                mountpoint = "/tank/Pictures"; }
    { name = "tank/Video";                   mountpoint = "/tank/Video"; }
    { name = "tank/Video/Zoom";              mountpoint = "/tank/Video/Zoom"; }
    { name = "tank/doc";                     mountpoint = "/tank/doc"; }
    { name = "tank/iCloud";                  mountpoint = "/tank/iCloud"; }
    { name = "tank/src";                     mountpoint = "/tank/src"; }
  ];

  # Function to generate a Samba share name from ZFS dataset name
  # Replaces "/" with "-" in the dataset name
  mkShareName = name: builtins.replaceStrings ["/"] ["-"] name;

  # Generate Samba share configurations for all ZFS filesystems
  zfsShares = lib.listToAttrs (map (fs: {
    name = mkShareName fs.name;
    value = {
      path = fs.mountpoint;
      comment = "ZFS: ${fs.name}";
      "valid users" = "johnw assembly";
      "read only" = "no";
      browseable = "yes";
      "create mask" = "0664";
      "directory mask" = "0775";
    };
  }) zfsFilesystems);

in
{
  # SOPS secrets for Samba user passwords
  sops.secrets."samba/johnw-password" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."samba/assembly-password" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # Activation script to set Samba passwords from SOPS secrets
  system.activationScripts.samba_users = lib.mkAfter ''
    # Ensure Samba users exist and set passwords from SOPS
    for user in johnw assembly; do
      if ${pkgs.glibc.getent}/bin/getent passwd "$user" > /dev/null; then
        password_file="/run/secrets/samba/$user-password"
        if [ -f "$password_file" ]; then
          password=$(cat "$password_file")
          echo -e "$password\n$password\n" | ${lib.getExe' pkgs.samba "smbpasswd"} -a -s "$user" 2>/dev/null || true
        fi
      fi
    done
  '';

  services = {
    # Main Samba service
    samba = {
      enable = true;
      openFirewall = true;  # Opens ports 139, 445, 137, 138

      # Enable Samba daemons
      smbd.enable = true;   # SMB/CIFS file sharing daemon
      nmbd.enable = true;   # NetBIOS name service (for network browsing)

      settings = {
        global = {
          # Security settings
          security = "user";
          "server role" = "standalone server";
          "server string" = "Vulcan NixOS Samba Server";
          workgroup = "WORKGROUP";

          # Modern protocol settings (SMB 3.1.1 minimum for security)
          "server min protocol" = "SMB3_11";
          "client min protocol" = "SMB3_11";

          # Encryption and signing (security best practices)
          "server signing" = "mandatory";
          "server smb encrypt" = "required";

          # Disable guest access
          "map to guest" = "never";
          "guest account" = "nobody";

          # Invalid users (security)
          "invalid users" = [ "root" ];

          # Password settings
          "passwd program" = "/run/wrappers/bin/passwd %u";
          "unix password sync" = "yes";

          # Performance optimizations
          "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=524288 SO_SNDBUF=524288";
          "read raw" = "yes";
          "write raw" = "yes";
          "max xmit" = "65535";
          "dead time" = "15";
          "getwd cache" = "yes";

          # Logging
          "logging" = "systemd";
          "log level" = "1";
        };
      } // zfsShares;
    };

    # Web Services Dynamic Discovery (helps Windows 10+ discover the server)
    samba-wsdd = {
      enable = true;
      openFirewall = true;
    };
  };

  # Ensure Samba services wait for ZFS mounts and auto-start when available
  # ConditionPathIsMountPoint prevents "failed" status during rebuild when mount unavailable
  systemd.services = {
    samba-nmbd = {
      after = [ "zfs.target" "zfs-import-tank.service" ];
      wantedBy = [ "tank.mount" ];
      unitConfig = {
        RequiresMountsFor = [ "/tank" ];
        ConditionPathIsMountPoint = "/tank";
      };
      serviceConfig = {
        RuntimeDirectory = "samba";
        RuntimeDirectoryMode = "0755";
      };
    };
    samba-smbd = {
      after = [ "zfs.target" "zfs-import-tank.service" ];
      wantedBy = [ "tank.mount" ];
      unitConfig = {
        RequiresMountsFor = [ "/tank" ];
        ConditionPathIsMountPoint = "/tank";
      };
      serviceConfig = {
        RuntimeDirectory = "samba";
        RuntimeDirectoryMode = "0755";
      };
    };
    samba-winbindd = {
      after = [ "zfs.target" "zfs-import-tank.service" ];
      wantedBy = [ "tank.mount" ];
      unitConfig = {
        RequiresMountsFor = [ "/tank" ];
        ConditionPathIsMountPoint = "/tank";
      };
      serviceConfig = {
        RuntimeDirectory = "samba";
        RuntimeDirectoryMode = "0755";
      };
    };
  };

  # Ensure Samba state directories have correct permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/samba 0755 root root -"
    "d /var/log/samba 0755 root root -"
    "d /var/log/samba/cores 0700 root root -"
  ];
}
