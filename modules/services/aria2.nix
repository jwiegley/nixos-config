{
  config,
  lib,
  pkgs,
  ...
}:

let
  downloadDir = "/tank/Public/download";
  rpcPort = 6800;

  # Fetch AriaNG latest release
  ariangSource = pkgs.fetchzip {
    url = "https://github.com/mayswind/AriaNg/releases/download/1.3.7/AriaNg-1.3.7.zip";
    sha256 = "sha256-9YUscIGHHUg2V5fGgBqLw87oFZrwj1frwl4YsIxXzTM=";
    stripRoot = false;
  };

  # Create pre-configured AriaNG with RPC settings
  ariang = pkgs.runCommand "ariang-configured" { } ''
        cp -r ${ariangSource} $out
        chmod -R u+w $out

        # Create configuration script that will be injected
        cat > $out/config.js << 'EOF'
    // Auto-configuration for aria2 RPC
    (function() {
      var storageKey = 'AriaNg.RpcSettings';
      var defaultConfig = {
        "rpcAlias": "vulcan",
        "rpcHost": "aria.vulcan.lan",
        "rpcPort": "443",
        "rpcInterface": "https",
        "protocol": "jsonrpc",
        "httpMethod": "POST",
        "secret": "",
        "path": "/jsonrpc",
        "isDefault": true
      };

      // Only set if not already configured
      if (!localStorage.getItem(storageKey)) {
        localStorage.setItem(storageKey, JSON.stringify([defaultConfig]));
        console.log('AriaNG: Auto-configured RPC settings');
      }
    })();
    EOF

        # Inject the configuration into index.html
        sed -i 's|<head>|<head><script src="config.js"></script>|' $out/index.html
  '';

in
{
  # Create aria2 user and group
  users.users.aria2 = {
    isSystemUser = true;
    group = "aria2";
    description = "aria2 download manager user";
    home = "/var/lib/aria2";
    createHome = true;
  };

  users.groups.aria2 = { };

  # SOPS secret for RPC authentication
  sops.secrets.aria2_rpc_secret = {
    mode = "0400";
    owner = "aria2";
    group = "aria2";
    restartUnits = [ "aria2.service" ];
  };

  # aria2 systemd service
  systemd.services.aria2 = {
    description = "aria2 Download Manager";
    after = [
      "network.target"
      "zfs-import-tank.service"
    ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      RequiresMountsFor = [ downloadDir ];
      ConditionPathIsMountPoint = "/tank";
    };

    serviceConfig = {
      Type = "forking";
      User = "aria2";
      Group = "aria2";
      Restart = "on-failure";
      RestartSec = 10;

      # Load RPC secret from SOPS
      LoadCredential = "rpc-secret:/run/secrets/aria2_rpc_secret";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "full"; # Changed from "strict" to allow DNS resolution
      ProtectHome = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      PrivateMounts = false; # Need access to ZFS mounts

      # Read/write access to download directory and state directory
      ReadWritePaths = [
        downloadDir
        "/var/lib/aria2"
      ];
    };

    script = ''
      # Read RPC secret from credential
      RPC_SECRET=$(cat $CREDENTIALS_DIRECTORY/rpc-secret)

      # Start aria2c daemon
      exec ${pkgs.aria2}/bin/aria2c \
        --enable-rpc=true \
        --rpc-listen-all=false \
        --rpc-listen-port=${toString rpcPort} \
        --rpc-secret="$RPC_SECRET" \
        --rpc-allow-origin-all=true \
        --daemon=true \
        --dir=${downloadDir} \
        --input-file=/var/lib/aria2/aria2.session \
        --save-session=/var/lib/aria2/aria2.session \
        --save-session-interval=60 \
        --max-concurrent-downloads=5 \
        --max-connection-per-server=16 \
        --min-split-size=10M \
        --split=16 \
        --continue=true \
        --max-overall-download-limit=0 \
        --max-overall-upload-limit=0 \
        --auto-file-renaming=true \
        --allow-overwrite=false \
        --file-allocation=falloc \
        --disk-cache=64M \
        --log=/var/lib/aria2/aria2.log \
        --log-level=notice \
        --console-log-level=notice
    '';

    preStart = ''
      # Ensure session file exists
      touch /var/lib/aria2/aria2.session
      chown aria2:aria2 /var/lib/aria2/aria2.session

      # Ensure download directory has correct permissions
      if [ -d ${downloadDir} ]; then
        chown aria2:aria2 ${downloadDir}
      else
        echo "ERROR: Download directory ${downloadDir} does not exist!"
        exit 1
      fi
    '';
  };

  # AriaNG web interface served via nginx
  services.nginx.virtualHosts."aria.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/aria.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/aria.vulcan.lan.key";

    locations."/" = {
      root = ariang;
      index = "index.html";
      extraConfig = ''
        add_header Cache-Control "no-cache, must-revalidate";
      '';
    };

    # Proxy aria2 RPC endpoint
    locations."/jsonrpc" = {
      proxyPass = "http://127.0.0.1:${toString rpcPort}/jsonrpc";
      recommendedProxySettings = true;
      extraConfig = ''
        # WebSocket support for aria2 RPC
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
      '';
    };
  };

  # Allow local RPC access
  networking.firewall.interfaces."lo".allowedTCPPorts = [ rpcPort ];

  # Ensure proper directory permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/aria2 0755 aria2 aria2 -"
  ];
}
