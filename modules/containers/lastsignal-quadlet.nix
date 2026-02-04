# LastSignal - System Configuration
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/lastsignal.nix)
# This file: Nginx virtual host, SOPS secrets, tmpfiles, and container image build

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  # Shared build script used by both activation (initial build) and timer (updates)
  buildLastsignalImage = pkgs.writeShellScript "build-lastsignal-image" ''
    set -euo pipefail

    export PATH=${
      lib.makeBinPath (
        with pkgs;
        [
          coreutils
          git
          podman
        ]
      )
    }

    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    BUILD_DIR=$(mktemp -d)
    trap "rm -rf $BUILD_DIR" EXIT

    log "Cloning lastsignal repository..."
    git clone --depth 1 https://github.com/giovantenne/lastsignal.git "$BUILD_DIR/lastsignal"

    log "Building lastsignal container image..."
    podman build -t localhost/lastsignal:latest "$BUILD_DIR/lastsignal"

    log "lastsignal image built successfully"
  '';
in
{
  # Nginx virtual host
  services.nginx.virtualHosts."lastsignal.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/lastsignal.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/lastsignal.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8190/";
      extraConfig = ''
        proxy_read_timeout 1h;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  # SOPS secrets
  sops.secrets."lastsignal-env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "lastsignal";
    path = "/run/secrets-lastsignal/lastsignal-env";
  };

  # tmpfiles rules for container data directory
  systemd.tmpfiles.rules = [
    "d /var/lib/containers/lastsignal/storage 0755 lastsignal lastsignal -"
  ];

  # Automatically build the container image if it doesn't exist
  # Runs as the lastsignal user so the image is stored in the rootless user's image store
  system.activationScripts.lastsignal-image = {
    text = ''
      LASTSIGNAL_UID=$(${pkgs.coreutils}/bin/id -u lastsignal 2>/dev/null || echo "")
      if [ -n "$LASTSIGNAL_UID" ]; then
        export XDG_RUNTIME_DIR="/run/user/$LASTSIGNAL_UID"
        ${pkgs.coreutils}/bin/mkdir -p "$XDG_RUNTIME_DIR"
        ${pkgs.coreutils}/bin/chown lastsignal:lastsignal "$XDG_RUNTIME_DIR"

        if ! ${pkgs.util-linux}/bin/runuser -u lastsignal -- env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" ${pkgs.podman}/bin/podman image exists localhost/lastsignal:latest 2>/dev/null; then
          ${pkgs.util-linux}/bin/runuser -u lastsignal -- env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" ${buildLastsignalImage}
        else
          echo "lastsignal image already exists"
        fi
      fi
    '';
    deps = [ ];
  };

  # Periodic rebuild service to pick up upstream updates
  # Rebuilds the image from latest git source and restarts the container
  systemd.services.update-lastsignal-image = {
    description = "Rebuild LastSignal container image from latest source";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "lastsignal";
      Group = "lastsignal";
      ExecStart = buildLastsignalImage;
      ExecStartPost = "${pkgs.systemd}/bin/systemctl --user --machine=lastsignal@ restart podman-lastsignal.service";
      TimeoutStartSec = "30m";
      RemainAfterExit = false;
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.timers.update-lastsignal-image = {
    description = "Timer for rebuilding LastSignal container image";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "2h";
      Persistent = true;
    };
  };
}
