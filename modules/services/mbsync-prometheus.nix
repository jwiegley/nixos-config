{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Prometheus exporter for mbsync metrics (serves metrics for all mbsync users)
  systemd.services.mbsync-metrics-exporter = {
    description = "Export mbsync metrics for Prometheus (all users)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      Restart = "always";
      RestartSec = "10s";

      ExecStart = pkgs.writeShellScript "mbsync-metrics-server" ''
                #!/usr/bin/env bash
                set -euo pipefail

                PORT=9280

                # Create Python HTTP server for metrics
                ${pkgs.python3}/bin/python3 - <<'PYTHON'
        import http.server
        import socketserver

        PORT = 9280

        class MetricsHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/metrics':
                    # Collect metrics from all mbsync users
                    metrics = []

                    # Assembly user metrics
                    try:
                        with open("/var/lib/mbsync-assembly/metrics", "r") as f:
                            metrics.extend([line.strip() for line in f if line.strip()])
                    except FileNotFoundError:
                        metrics.append("# No metrics found for assembly user")

                    # Johnw user metrics
                    try:
                        with open("/var/lib/mbsync-johnw/metrics", "r") as f:
                            metrics.extend([line.strip() for line in f if line.strip()])
                    except FileNotFoundError:
                        metrics.append("# No metrics found for johnw user")

                    # If no metrics at all, provide defaults
                    if not metrics:
                        metrics = ["mbsync_sync_status 0"]

                    # Add help text and type information
                    response = """# HELP mbsync_assembly_sync_status Whether the last sync was successful (1) or failed (0) for assembly user
        # TYPE mbsync_assembly_sync_status gauge
        # HELP mbsync_assembly_last_success_timestamp Unix timestamp of last successful sync for assembly user
        # TYPE mbsync_assembly_last_success_timestamp gauge
        # HELP mbsync_assembly_last_failure_timestamp Unix timestamp of last failed sync for assembly user
        # TYPE mbsync_assembly_last_failure_timestamp gauge
        # HELP mbsync_assembly_inbox_messages Number of messages in INBOX for assembly user
        # TYPE mbsync_assembly_inbox_messages gauge
        # HELP mbsync_johnw_sync_status Whether the last sync was successful (1) or failed (0) for johnw user
        # TYPE mbsync_johnw_sync_status gauge
        # HELP mbsync_johnw_last_success_timestamp Unix timestamp of last successful sync for johnw user
        # TYPE mbsync_johnw_last_success_timestamp gauge
        # HELP mbsync_johnw_last_failure_timestamp Unix timestamp of last failed sync for johnw user
        # TYPE mbsync_johnw_last_failure_timestamp gauge
        # HELP mbsync_johnw_inbox_messages Number of messages in INBOX for johnw user
        # TYPE mbsync_johnw_inbox_messages gauge
        """ + "\n".join(metrics)

                    self.send_response(200)
                    self.send_header('Content-type', 'text/plain; version=0.0.4')
                    self.end_headers()
                    self.wfile.write(response.encode())
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, format, *args):
                # Suppress access logs
                pass

        with socketserver.TCPServer(("", PORT), MetricsHandler) as httpd:
            print(f"Serving mbsync metrics on port {PORT}")
            httpd.serve_forever()
        PYTHON
      '';

      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = [
        "/var/lib/mbsync-assembly/metrics"
        "/var/lib/mbsync-johnw/metrics"
      ];
    };

    path = [
      pkgs.coreutils
      pkgs.python3
    ];
  };

  # Add mbsync monitoring to Prometheus
  services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
    {
      job_name = "mbsync";
      static_configs = [
        {
          targets = [ "localhost:9280" ];
          labels = {
            service = "mbsync";
          };
        }
      ];
      scrape_interval = "60s";
    }
  ];

  # Open firewall port for metrics exporter (internal only)
  networking.firewall.interfaces.lo.allowedTCPPorts = [ 9280 ];
}
