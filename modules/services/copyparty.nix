{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.copyparty;
  dataDir = "/var/lib/copyparty";
  shareDir = cfg.shareDir;  # Main share directory

  # Determine if using SOPS or password files
  useSOPS = cfg.passwordFiles == null;

  # Script to generate config with passwords from secrets or files
  configGenerator = pkgs.writeShellScript "copyparty-config-generator" (
    (if cfg.passwordFiles != null then ''
      # Read passwords from password files
      ADMIN_PASS=$(cat ${cfg.passwordFiles.admin})
      JOHNW_PASS=$(cat ${cfg.passwordFiles.johnw})
      FRIEND_PASS=$(cat ${cfg.passwordFiles.friend})
    '' else ''
      # Read passwords from SOPS secrets
      ADMIN_PASS=$(cat ${config.sops.secrets."copyparty/admin-password".path})
      JOHNW_PASS=$(cat ${config.sops.secrets."copyparty/johnw-password".path})
      FRIEND_PASS=$(cat ${config.sops.secrets."copyparty/friend-password".path})
    '') + ''

    # Generate configuration file
    cat > ${dataDir}/copyparty.conf <<EOF
    [global]
      # Listen on all interfaces for container port forwarding
      i: 0.0.0.0
      # Port configuration
      p: ${toString cfg.port}
      # Reverse proxy configuration - required to detect real client IPs
      rproxy: -1
      xff-hdr: x-forwarded-for
      # Enable Prometheus metrics
      stats
      # Enable media indexing and search
      e2dsa
      # Enable audio metadata
      e2ts
      # Generate QR codes for mobile access
      qr
      # Theme
      theme: 3
      ups-when    # everyone can see upload times
      ups-who: 1  # but only admins can see the list,
                  # so ups-when doesn't take effect

    [accounts]
      johnw: $JOHNW_PASS
      friend: $FRIEND_PASS

    [/pub]
      ${shareDir}/pub
      accs:
        r: *
        rwmda: johnw
      flags:
        # Enable deduplication
        nodupe
        # Enable media indexing
        e2d
        # Enable directory tags
        d2t

    [/share]
      ${shareDir}/share
      accs:
        g: *
        rwmda: johnw
      flags:
        # Enable deduplication
        nodupe
        # Enable media indexing
        e2d
        # Enable directory tags
        d2t

    [/files]
      ${shareDir}/files
      accs:
        r: friend
        rwmda: johnw
      flags:
        # Enable deduplication
        nodupe
        # Enable media indexing
        e2d
        # Enable directory tags
        d2t

    [/private]
      ${shareDir}/private
      accs:
        g: friend
        rwmda: johnw
      flags:
        # Enable deduplication
        nodupe
        # Enable media indexing
        e2d
        # Enable directory tags
        d2t

    [/upload]
      ${shareDir}/upload
      accs:
        w: friend      # anyone can upload (but not browse)
        rwmda: johnw   # admin can browse and manage

    ${cfg.extraConfig}
    EOF
  '');

  # Python environment with copyparty and optional dependencies
  copypartyEnv = pkgs.python3.withPackages (ps: with ps; [
    copyparty
    pillow  # For thumbnails
    mutagen  # For audio metadata
    jinja2  # Core dependency
  ]);

in {
  options.services.copyparty = {
    enable = mkEnableOption "copyparty file server";

    port = mkOption {
      type = types.port;
      default = 3923;
      description = "Port for copyparty to listen on (loopback only)";
    };

    shareDir = mkOption {
      type = types.str;
      default = "/tank/Public";
      description = "Directory to share via copyparty";
    };

    passwordFiles = mkOption {
      type = types.nullOr (types.attrsOf types.path);
      default = null;
      example = {
        admin = "/run/secrets/admin-password";
        johnw = "/run/secrets/johnw-password";
        friend = "/run/secrets/friend-password";
      };
      description = "Paths to files containing passwords for each user. Alternative to SOPS secrets.";
    };

    accounts = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = { alice = "password123"; bob = "secret456"; };
      description = "User accounts for authentication. Format: username = password. Passwords can be plaintext or hashed.";
    };

    writeUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" "bob" ];
      description = "List of users who have write access to shares";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra configuration to append to copyparty.conf";
    };

    domain = mkOption {
      type = types.str;
      default = "copyparty.vulcan.lan";
      description = "Domain name for nginx virtual host";
    };
  };

  config = mkIf cfg.enable {

    # Create copyparty user and group
    users.users.copyparty = {
      isSystemUser = true;
      group = "copyparty";
      description = "Copyparty file server user";
      home = dataDir;
      createHome = true;
    };

    users.groups.copyparty = {
      members = [ "prometheus" ];  # Allow Prometheus to read secrets
    };

    # Ensure share directory exists and has correct permissions
    systemd.tmpfiles.rules = [
      "d ${shareDir} 0755 copyparty copyparty -"
      "d ${dataDir} 0755 copyparty copyparty -"
      "d ${dataDir}/.hist 0755 copyparty copyparty -"
      "d ${dataDir}/.th 0755 copyparty copyparty -"
    ];

    # Copyparty systemd service
    systemd.services.copyparty = {
      description = "Copyparty file server with media indexing";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # Generate config before starting
      preStart = ''
        ${configGenerator}
      '';

      serviceConfig = {
        Type = "notify";
        User = "copyparty";
        Group = "copyparty";
        WorkingDirectory = dataDir;

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ dataDir shareDir ];

        # Resource limits
        MemoryMax = "2G";
        TasksMax = 512;

        # Start copyparty with generated config file
        ExecStart = "${copypartyEnv}/bin/copyparty -c ${dataDir}/copyparty.conf --hist ${dataDir}/.hist";

        # Reload configuration on SIGUSR1
        ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";

        Restart = "always";
        RestartSec = 5;
      };
    };

    # Allow loopback traffic
    networking.firewall.interfaces."lo".allowedTCPPorts = [ cfg.port ];
  };
}
