{ config, lib, pkgs, ... }:

{
  # SOPS secrets for Samba user passwords
  sops.secrets."samba/johnw-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."samba/assembly-password" = {
    sopsFile = ../../secrets.yaml;
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

        # Private user shares for johnw
        "johnw-documents" = {
          path = "/tank/Documents";
          comment = "johnw's Documents";
          "valid users" = "johnw";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "johnw";
          "force group" = "johnw";
        };

        "johnw-downloads" = {
          path = "/tank/Downloads";
          comment = "johnw's Downloads";
          "valid users" = "johnw";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "johnw";
          "force group" = "johnw";
        };

        "johnw-home" = {
          path = "/tank/Home";
          comment = "johnw's Home";
          "valid users" = "johnw";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "johnw";
          "force group" = "johnw";
        };

        # Private user shares for assembly
        "assembly-home" = {
          path = "/home/assembly";
          comment = "assembly's Home";
          "valid users" = "assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "assembly";
          "force group" = "assembly";
        };

        # Shared media directories (accessible to both users)
        "media" = {
          path = "/tank/Media";
          comment = "Media Files";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        "photos" = {
          path = "/tank/Photos";
          comment = "Photo Collection";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        "pictures" = {
          path = "/tank/Pictures";
          comment = "Pictures";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        "music" = {
          path = "/tank/Music";
          comment = "Music Library";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        "video" = {
          path = "/tank/Video";
          comment = "Video Files";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        "audio" = {
          path = "/tank/Audio";
          comment = "Audio Files";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        "movies" = {
          path = "/tank/Movies";
          comment = "Movie Collection";
          "valid users" = "johnw assembly";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0664";
          "directory mask" = "0775";
        };
      };
    };

    # Web Services Dynamic Discovery (helps Windows 10+ discover the server)
    samba-wsdd = {
      enable = true;
      openFirewall = true;
    };
  };

  # Ensure Samba target starts at boot
  systemd.targets.samba = {
    wantedBy = [ "multi-user.target" ];
  };
}
