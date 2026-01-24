{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  common = import ../lib/common.nix { inherit secrets; };
in
{
  # BudgetBoard - Personal finance and budgeting application
  # Architecture: C# backend server + React frontend client in a Podman Pod
  # Database: PostgreSQL (using host instance)
  #
  # NOTE: Uses a Pod because Podman network has dns_enabled=false (conflicts with Technitium DNS)
  # Containers in a pod share network namespace and communicate via localhost

  # SOPS secrets for BudgetBoard
  sops.secrets."budgetboard/database-password" = {
    sopsFile = common.secretsPath;
    owner = "root";
    group = "postgres";
    mode = "0440";
    restartUnits = [
      "budgetboard-server.service"
    ];
  };

  # Create environment file for server with database credentials
  systemd.tmpfiles.rules = [
    "d /var/lib/budgetboard-server 0755 root root -"
    "d /var/lib/budgetboard-client 0755 root root -"
    "d /run/budgetboard 0755 root root -"
  ];

  # Generate environment file from SOPS secret
  systemd.services.budgetboard-env-setup = {
    description = "Generate BudgetBoard environment file from SOPS secrets";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
    before = [ "podman-budgetboard-server.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Create environment file with database password
      echo "POSTGRES_PASSWORD=$(cat ${
        config.sops.secrets."budgetboard/database-password".path
      })" > /run/budgetboard/server.env
      chmod 600 /run/budgetboard/server.env
    '';
  };

  # Cleanup service to handle stale pods/containers after reboot
  # This prevents cgroup errors when the pod service tries to start
  systemd.services.budget-board-cleanup = {
    description = "Cleanup stale BudgetBoard pod and containers";
    before = [ "budget-board-pod.service" ];
    wantedBy = [ "budget-board-pod.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Remove any leftover pod and containers from previous session
      # Ignore errors from stale cgroups after reboot
      ${pkgs.podman}/bin/podman pod rm -f budget-board || true
      ${pkgs.podman}/bin/podman rm -f budget-board-server budget-board-client || true
    '';
  };

  # BudgetBoard Pod - containers share network namespace
  virtualisation.quadlet.pods.budget-board = {
    podConfig = {
      # Expose client port to host
      publishPorts = [
        "127.0.0.1:6253:6253/tcp"
      ];
      networks = [ "podman" ];
    };
  };

  # BudgetBoard Server (C# backend) - runs in pod
  virtualisation.quadlet.containers.budget-board-server = {
    autoStart = true;

    containerConfig = {
      image = "ghcr.io/teelur/budget-board/server:release";

      # Server listens on localhost:8080 within the pod
      # No port publishing needed - client accesses via pod's shared network

      # Health check configuration
      # Uses bash TCP redirection instead of curl (which isn't in the container image)
      # More lenient settings to handle database migrations and slow starts
      healthCmd = "CMD-SHELL timeout 5 bash -c '</dev/tcp/localhost/8080' || exit 1";
      healthInterval = "30s";
      healthTimeout = "15s";
      healthStartPeriod = "120s"; # Give 2 minutes for DB migrations
      healthRetries = 5; # More retries before marking unhealthy

      environments = {
        # Logging configuration
        "Logging__LogLevel__Default" = "Information";

        # Client address for server-to-client communication
        # Uses localhost since containers share network namespace in pod
        "CLIENT_ADDRESS" = "localhost";

        # PostgreSQL connection to host database
        "POSTGRES_HOST" = common.postgresDefaults.host;
        "POSTGRES_PORT" = toString common.postgresDefaults.port;
        "POSTGRES_DATABASE" = "budgetboard";
        "POSTGRES_USER" = "budgetboard";

        # Enable automatic database schema updates
        "AUTO_UPDATE_DB" = "true";

        # Automatic SimpleFIN sync configuration
        # DISABLE_AUTO_SYNC defaults to false (enabled)
        # SYNC_INTERVAL_HOURS: sync every 24 hours (daily)
        "SYNC_INTERVAL_HOURS" = "24";
      };

      # Password loaded from generated environment file
      environmentFiles = [ "/run/budgetboard/server.env" ];

      volumes = [
        "/var/lib/budgetboard-server:/app/data:rw"
      ];

      # Join the budget-board pod
      pod = "budget-board.pod";
    };

    unitConfig = {
      After = [
        "sops-nix.service"
        "podman.service"
        "postgresql.service"
        "budgetboard-env-setup.service"
        "budget-board-pod.service"
      ];
      Wants = [
        "sops-nix.service"
        "postgresql.service"
        "budgetboard-env-setup.service"
      ];
      Requires = [
        "postgresql.service"
        "budgetboard-env-setup.service"
        "budget-board-pod.service"
      ];
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    serviceConfig = {
      # Wait for PostgreSQL to be ready before starting container
      # pg_isready doesn't require authentication, perfect for pre-start checks
      ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h ${common.postgresDefaults.host} -p ${toString common.postgresDefaults.port} -t 60";
      Restart = "always";
      RestartSec = "15s"; # Wait longer between restart attempts
      TimeoutStartSec = "180s"; # Allow up to 3 minutes for startup (includes DB migrations)
      # NOTE: StartLimitBurst/StartLimitIntervalSec are in unitConfig (belong in [Unit], not [Service])
      # Filter out info-level logs to reduce log volume
      LogLevelMax = "warning";
    };
  };

  # BudgetBoard Client (React frontend) - runs in pod
  virtualisation.quadlet.containers.budget-board-client = {
    autoStart = true;

    containerConfig = {
      image = "ghcr.io/teelur/budget-board/client:release";

      # Port exposed via pod configuration above
      # Client's nginx proxies to localhost:8080 (server in same pod)
      # VITE_SERVER_ADDRESS=localhost makes the entrypoint script generate correct backend config

      # Health check configuration
      healthCmd = "CMD-SHELL curl -f http://localhost:6253/ || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthStartPeriod = "30s";
      healthRetries = 3;

      environments = {
        # Client listening port
        "PORT" = "6253";
        # Backend address - uses localhost since containers share network namespace in pod
        "VITE_SERVER_ADDRESS" = "localhost";
      };

      volumes = [
        "/var/lib/budgetboard-client:/app/data:rw"
      ];

      # Join the budget-board pod (shares network with server)
      pod = "budget-board.pod";
    };

    unitConfig = {
      After = [
        "podman.service"
        "budget-board-server.service"
        "budget-board-pod.service"
      ];
      Wants = [ "budget-board-server.service" ];
      Requires = [ "budget-board-pod.service" ];
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
      # Filter out info-level HTTP access logs to reduce log volume
      # Saves ~4,272 lines/day by only logging warnings and above
      LogLevelMax = "warning";
    };
  };

  # Nginx reverse proxy for HTTPS access
  services.nginx.virtualHosts."budget.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/budget.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/budget.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:6253";
      proxyWebsockets = true;
    };
  };

  # Certificate generation for BudgetBoard web interface
  systemd.services.budgetboard-certificate = {
    description = "Generate BudgetBoard TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [
      pkgs.openssl
      pkgs.step-cli
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/budget.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/budget.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create self-signed certificate as fallback for nginx
      echo "Creating temporary self-signed certificate for budget.vulcan.lan"
      echo "Generate proper certificate with: sudo /etc/nixos/certs/renew-certificate.sh budget.vulcan.lan -o /var/lib/nginx-certs -d 365 --owner root:nginx"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=budget.vulcan.lan" \
        -addext "subjectAltName=DNS:budget.vulcan.lan"

      # Set proper permissions for nginx
      chmod 644 "$CERT_FILE"
      chmod 640 "$KEY_FILE"
      chown root:nginx "$CERT_FILE" "$KEY_FILE"

      echo "Certificate generated successfully"
    '';
  };

  # Note: The quadlet definitions above (lines 73-192) handle container lifecycle.
  # Manual systemd services removed to avoid conflict with quadlet-generated services.

  # Firewall configuration
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    6253 # budgetboard-client
  ];
}
