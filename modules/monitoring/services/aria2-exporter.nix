{
  config,
  lib,
  pkgs,
  ...
}:

let
  exporterPort = 9374;

  # Custom aria2 Prometheus exporter
  aria2Exporter = pkgs.writeScriptBin "aria2-exporter" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import socketserver
    import json
    import urllib.request
    import urllib.error
    import time
    import os
    from datetime import datetime

    PORT = ${toString exporterPort}
    ARIA2_RPC_URL = "http://127.0.0.1:6800/jsonrpc"

    # Read RPC secret from file
    def get_rpc_secret():
        secret_file = "/run/secrets/aria2_rpc_secret"
        try:
            with open(secret_file, 'r') as f:
                return f.read().strip()
        except Exception as e:
            print(f"Error reading RPC secret: {e}")
            return None

    RPC_SECRET = get_rpc_secret()

    def call_aria2_rpc(method, params=None):
        """Call aria2 JSON-RPC method"""
        if params is None:
            params = []

        # Add RPC secret as first parameter if available
        if RPC_SECRET:
            params = [f"token:{RPC_SECRET}"] + params

        payload = {
            "jsonrpc": "2.0",
            "id": "1",
            "method": method,
            "params": params
        }

        try:
            req = urllib.request.Request(
                ARIA2_RPC_URL,
                data=json.dumps(payload).encode('utf-8'),
                headers={'Content-Type': 'application/json'}
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                result = json.loads(response.read().decode('utf-8'))
                return result.get('result')
        except Exception as e:
            print(f"Error calling aria2 RPC: {e}")
            return None

    def get_metrics():
        """Collect metrics from aria2"""
        metrics = []

        # Check if aria2 is responding
        version = call_aria2_rpc("aria2.getVersion")
        if version:
            metrics.append('aria2_up 1')
            metrics.append(f'aria2_version_info{{version="{version.get("version", "unknown")}"}} 1')
        else:
            metrics.append('aria2_up 0')
            return metrics

        # Get global statistics
        stats = call_aria2_rpc("aria2.getGlobalStat")
        if stats:
            metrics.append(f'aria2_download_speed_bytes {stats.get("downloadSpeed", 0)}')
            metrics.append(f'aria2_upload_speed_bytes {stats.get("uploadSpeed", 0)}')
            metrics.append(f'aria2_active_downloads {stats.get("numActive", 0)}')
            metrics.append(f'aria2_waiting_downloads {stats.get("numWaiting", 0)}')
            metrics.append(f'aria2_stopped_downloads {stats.get("numStopped", 0)}')
            metrics.append(f'aria2_stopped_total_downloads {stats.get("numStoppedTotal", 0)}')

        # Get active downloads
        active = call_aria2_rpc("aria2.tellActive")
        if active:
            total_size = 0
            completed_size = 0

            for download in active:
                total_size += int(download.get("totalLength", 0))
                completed_size += int(download.get("completedLength", 0))

            metrics.append(f'aria2_active_total_bytes {total_size}')
            metrics.append(f'aria2_active_completed_bytes {completed_size}')

            if total_size > 0:
                progress = (completed_size / total_size) * 100
                metrics.append(f'aria2_active_progress_percent {progress:.2f}')

        # Get waiting downloads
        waiting = call_aria2_rpc("aria2.tellWaiting", [0, 1000])
        if waiting:
            metrics.append(f'aria2_queue_size {len(waiting)}')

        # Get stopped downloads (completed, error, or removed)
        stopped = call_aria2_rpc("aria2.tellStopped", [0, 1000])
        if stopped:
            completed = sum(1 for d in stopped if d.get("status") == "complete")
            error = sum(1 for d in stopped if d.get("status") == "error")
            removed = sum(1 for d in stopped if d.get("status") == "removed")

            metrics.append(f'aria2_completed_downloads {completed}')
            metrics.append(f'aria2_error_downloads {error}')
            metrics.append(f'aria2_removed_downloads {removed}')

        return metrics

    class MetricsHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/metrics':
                try:
                    metrics = get_metrics()
                    output = '\n'.join(metrics) + '\n'

                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain; version=0.0.4')
                    self.end_headers()
                    self.wfile.write(output.encode('utf-8'))
                except Exception as e:
                    print(f"Error generating metrics: {e}")
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(b"Internal Server Error\n")
            elif self.path == '/health':
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK\n")
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            # Suppress request logging
            pass

    print(f"aria2 Prometheus Exporter starting on port {PORT}")
    with socketserver.TCPServer(("127.0.0.1", PORT), MetricsHandler) as httpd:
        print(f"Serving metrics at http://127.0.0.1:{PORT}/metrics")
        httpd.serve_forever()
  '';

in
{
  # aria2 Prometheus exporter service
  systemd.services.aria2-exporter = {
    description = "aria2 Prometheus Metrics Exporter";
    after = [
      "network.target"
      "aria2.service"
    ];
    wantedBy = [ "multi-user.target" ];
    wants = [ "aria2.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${aria2Exporter}/bin/aria2-exporter";
      Restart = "always";
      RestartSec = 10;
      User = "aria2";
      Group = "aria2";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      PrivateMounts = true;

      # Allow reading the RPC secret
      LoadCredential = "rpc-secret:/run/secrets/aria2_rpc_secret";
    };
  };

  # Prometheus scrape configuration
  services.prometheus.scrapeConfigs = [
    {
      job_name = "aria2";
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString exporterPort}" ];
          labels = {
            instance = "vulcan";
            service = "aria2";
          };
        }
      ];
      scrape_interval = "15s";
    }
  ];

  # Allow local access to exporter
  networking.firewall.interfaces."lo".allowedTCPPorts = [ exporterPort ];
}
