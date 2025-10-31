{ config, lib, pkgs, secrets, ... }:

let
  common = import ../lib/common.nix { inherit secrets; };
in
{
  # ChangeDetection.io - Website change detection and monitoring service
  # Architecture: Main application + Prometheus exporter in a Podman Pod
  # Storage: File-based storage using volume mount
  #
  # NOTE: Uses a Pod because Podman network has dns_enabled=false (conflicts with Technitium DNS)
  # Containers in a pod share network namespace and communicate via localhost

  # SOPS secrets for ChangeDetection.io
  sops.secrets."changedetection/api-key" = {
    sopsFile = common.secretsPath;
    owner = "root";
    mode = "0440";
    restartUnits = [
      "podman-changedetection-app.service"
      "podman-changedetection-exporter.service"
    ];
  };

  # Create directories for persistent storage
  systemd.tmpfiles.rules = [
    "d /var/lib/changedetection 0755 root root -"
    "d /run/changedetection 0755 root root -"
  ];

  # Generate environment file from SOPS secret
  systemd.services.changedetection-env-setup = {
    description = "Generate ChangeDetection environment file from SOPS secrets";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
    before = [ "podman-changedetection-app.service" "podman-changedetection-exporter.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Create environment files with API key
      API_KEY=$(cat ${config.sops.secrets."changedetection/api-key".path})

      # App environment file
      cat > /run/changedetection/app.env << EOF
CHANGEDETECTION_API_KEY=$API_KEY
EOF
      chmod 600 /run/changedetection/app.env

      # Exporter environment file
      cat > /run/changedetection/exporter.env << EOF
CDIO_API_BASE_URL=http://localhost:5000
CDIO_API_KEY=$API_KEY
EOF
      chmod 600 /run/changedetection/exporter.env
    '';
  };

  # ChangeDetection Pod - containers share network namespace
  virtualisation.quadlet.pods.changedetection = {
    podConfig = {
      # Expose app and exporter ports to host
      publishPorts = [
        "127.0.0.1:5055:5000/tcp"  # Main app (internal 5000 -> external 5055)
        "127.0.0.1:9123:9123/tcp"  # Prometheus exporter
      ];
      networks = [ "podman" ];
    };
  };

  # ChangeDetection.io main application - runs in pod
  virtualisation.quadlet.containers.changedetection-app = {
    autoStart = true;

    containerConfig = {
      image = "ghcr.io/dgtlmoon/changedetection.io:latest";

      # App listens on port 5000 within the pod

      # Health check configuration
      healthCmd = "CMD-SHELL curl -f http://localhost:5000/ || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthStartPeriod = "45s";
      healthRetries = 3;

      environments = {
        "PORT" = "5000";
        "BASE_URL" = "https://changes.vulcan.lan";
        "FETCH_WORKERS" = "10";
        "LOGGER_LEVEL" = "INFO";
        "TZ" = "America/Los_Angeles";
      };

      # API key loaded from generated environment file
      environmentFiles = [ "/run/changedetection/app.env" ];

      volumes = [
        "/var/lib/changedetection:/datastore:rw"
      ];

      # Join the changedetection pod
      pod = "changedetection";
    };

    unitConfig = {
      After = [ "sops-nix.service" "podman.service" "changedetection-env-setup.service" "changedetection-pod.service" ];
      Wants = [ "sops-nix.service" "changedetection-env-setup.service" ];
      Requires = [ "changedetection-env-setup.service" "changedetection-pod.service" ];
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # ChangeDetection.io Prometheus exporter - runs in pod
  virtualisation.quadlet.containers.changedetection-exporter = {
    autoStart = true;

    containerConfig = {
      image = "ghcr.io/schaermu/changedetection.io-exporter:latest";

      # Exporter listens on port 9123 within the pod
      # Accesses main app via localhost:5000 (shared pod network)

      # Health check configuration
      healthCmd = "CMD-SHELL curl -f http://localhost:9123/metrics || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthStartPeriod = "30s";
      healthRetries = 3;

      # Configuration loaded from generated environment file
      environmentFiles = [ "/run/changedetection/exporter.env" ];

      # Join the changedetection pod (shares network with app)
      pod = "changedetection";
    };

    unitConfig = {
      After = [ "podman.service" "changedetection-app.service" "changedetection-env-setup.service" "changedetection-pod.service" ];
      Wants = [ "changedetection-app.service" "changedetection-env-setup.service" ];
      Requires = [ "changedetection-pod.service" "changedetection-env-setup.service" ];
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Systemd services to start the containers (workaround for quadlet not auto-generating services)
  systemd.services.changedetection-app-container = {
    description = "ChangeDetection.io Application Container";
    after = [ "changedetection-pod.service" "changedetection-env-setup.service" ];
    requires = [ "changedetection-pod.service" "changedetection-env-setup.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "forking";
      Restart = "always";
      RestartSec = "10s";
      ExecStartPre = "${pkgs.podman}/bin/podman rm -f changedetection-app || true";
      ExecStart = ''${pkgs.podman}/bin/podman run -d \
        --name changedetection-app \
        --pod changedetection \
        --env PORT=5000 \
        --env BASE_URL=https://changes.vulcan.lan \
        --env FETCH_WORKERS=10 \
        --env LOGGER_LEVEL=INFO \
        --env TZ=America/Los_Angeles \
        --env-file /run/changedetection/app.env \
        -v /var/lib/changedetection:/datastore:rw \
        ghcr.io/dgtlmoon/changedetection.io:latest'';
      ExecStop = "${pkgs.podman}/bin/podman stop changedetection-app";
    };
  };

  systemd.services.changedetection-exporter-container = {
    description = "ChangeDetection.io Prometheus Exporter Container";
    after = [ "changedetection-pod.service" "changedetection-env-setup.service" "changedetection-app-container.service" ];
    requires = [ "changedetection-pod.service" "changedetection-env-setup.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "forking";
      Restart = "always";
      RestartSec = "10s";
      ExecStartPre = "${pkgs.podman}/bin/podman rm -f changedetection-exporter || true";
      ExecStart = ''${pkgs.podman}/bin/podman run -d \
        --name changedetection-exporter \
        --pod changedetection \
        --env-file /run/changedetection/exporter.env \
        ghcr.io/schaermu/changedetection.io-exporter:latest'';
      ExecStop = "${pkgs.podman}/bin/podman stop changedetection-exporter";
    };
  };

  # Nginx reverse proxy for HTTPS access
  services.nginx.virtualHosts."changes.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/changes.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/changes.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:5055";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
      '';
    };
  };
}
