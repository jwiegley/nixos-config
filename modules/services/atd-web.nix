{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Simple web interface to display atd queue status and job history
  atd-web-server = pkgs.writeScriptBin "atd-web-server" ''
    #!${pkgs.python3}/bin/python3

    import subprocess
    import http.server
    import socketserver
    from datetime import datetime
    import html
    import urllib.parse

    PORT = 9281

    class AtdStatusHandler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            # Parse URL and query parameters
            parsed_path = urllib.parse.urlparse(self.path)
            path = parsed_path.path
            query = urllib.parse.parse_qs(parsed_path.query)

            if path == '/':
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html_content = self.generate_status_page()
                self.wfile.write(html_content.encode('utf-8'))
            elif path == '/command':
                # Display queued job command
                job_id = query.get('id', [""])[0]
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.end_headers()
                html_content = self.generate_job_command_page(job_id)
                self.wfile.write(html_content.encode('utf-8'))
            elif path == '/health':
                self.send_response(200)
                self.send_header('Content-type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'OK')
            else:
                self.send_error(404)

        def generate_job_command_page(self, job_id):
            """Generate page showing the command for a queued job"""
            if not job_id or not job_id.isdigit():
                return "<html><body><h1>Invalid job ID</h1></body></html>"

            try:
                result = subprocess.run(['/run/wrappers/bin/at', '-c', job_id],
                                      capture_output=True, text=True, errors='replace')
                if result.returncode != 0:
                    return f"<html><body><h1>Job {html.escape(job_id)} not found</h1></body></html>"

                command_output = result.stdout
            except Exception as e:
                return f"<html><body><h1>Error retrieving job: {html.escape(str(e))}</h1></body></html>"

            return f"""<!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>ATD Job {job_id} Command - vulcan.lan</title>
        <style>
            body {{
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
                max-width: 1200px;
                margin: 0 auto;
                padding: 20px;
                background-color: #f5f5f5;
            }}
            .header {{
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 30px;
                border-radius: 10px;
                margin-bottom: 30px;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            }}
            .card {{
                background: white;
                padding: 25px;
                border-radius: 10px;
                margin-bottom: 20px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }}
            .command {{
                background: #1e1e1e;
                color: #d4d4d4;
                padding: 20px;
                border-radius: 8px;
                font-family: 'Courier New', monospace;
                white-space: pre-wrap;
                overflow-x: auto;
                font-size: 0.9em;
            }}
            .back-link {{
                display: inline-block;
                padding: 10px 20px;
                background: #667eea;
                color: white;
                text-decoration: none;
                border-radius: 5px;
                margin-bottom: 20px;
            }}
            .back-link:hover {{
                background: #5568d3;
            }}
        </style>
    </head>
    <body>
        <div class="header">
            <h1>📋 Job #{job_id} Command</h1>
            <p>Queued Job Command Details</p>
        </div>

        <a href="/" class="back-link">← Back to Dashboard</a>

        <div class="card">
            <h2>Job Command Script</h2>
            <div class="command">{html.escape(command_output)}</div>
        </div>
    </body>
    </html>"""

        def generate_status_page(self):
            # Get atd service status
            try:
                result = subprocess.run(['systemctl', 'is-active', 'atd'],
                                      capture_output=True, text=True)
                service_status = result.stdout.strip()
                service_color = 'green' if service_status == 'active' else 'red'
            except:
                service_status = 'unknown'
                service_color = 'orange'

            # Get queue information
            try:
                result = subprocess.run(['/run/wrappers/bin/atq'], capture_output=True, text=True)
                queue_output = result.stdout.strip()
                if queue_output:
                    queue_lines = queue_output.split('\n')
                    queue_count = len(queue_lines)
                    queue_table = '<table style="width:100%; border-collapse: collapse; margin-top: 20px;">'
                    queue_table += '<tr style="background-color: #f0f0f0;">'
                    queue_table += '<th style="border: 1px solid #ddd; padding: 8px;">Job ID</th>'
                    queue_table += '<th style="border: 1px solid #ddd; padding: 8px;">Scheduled Time</th>'
                    queue_table += '<th style="border: 1px solid #ddd; padding: 8px;">Queue</th>'
                    queue_table += '<th style="border: 1px solid #ddd; padding: 8px;">User</th>'
                    queue_table += '</tr>'

                    for line in queue_lines:
                        parts = line.split()
                        if len(parts) >= 7:
                            job_id = parts[0]
                            # Format: Mon Nov 17 12:44:00 2025
                            scheduled_time = " ".join(parts[1:6])
                            queue = parts[6]
                            user = parts[7] if len(parts) > 7 else ""

                            queue_table += '<tr>'
                            queue_table += f'<td style="border: 1px solid #ddd; padding: 8px;"><a href="/command?id={urllib.parse.quote(job_id)}">{html.escape(job_id)}</a></td>'
                            queue_table += f'<td style="border: 1px solid #ddd; padding: 8px;">{html.escape(scheduled_time)}</td>'
                            queue_table += f'<td style="border: 1px solid #ddd; padding: 8px;">{html.escape(queue)}</td>'
                            queue_table += f'<td style="border: 1px solid #ddd; padding: 8px;">{html.escape(user)}</td>'
                            queue_table += '</tr>'
                    queue_table += '</table>'
                else:
                    queue_count = 0
                    queue_table = '<p style="color: #666; font-style: italic;">No jobs in queue</p>'
            except Exception as e:
                queue_count = 'Error'
                queue_table = f'<p style="color: red;">Error reading queue: {html.escape(str(e))}</p>'

            current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

            return f"""<!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="refresh" content="30">
        <title>ATD Status - vulcan.lan</title>
        <style>
            body {{
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
                max-width: 1400px;
                margin: 0 auto;
                padding: 20px;
                background-color: #f5f5f5;
            }}
            .header {{
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 30px;
                border-radius: 10px;
                margin-bottom: 30px;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            }}
            .header h1 {{
                margin: 0 0 10px 0;
                font-size: 2.5em;
            }}
            .header p {{
                margin: 0;
                opacity: 0.9;
            }}
            .status-card {{
                background: white;
                padding: 25px;
                border-radius: 10px;
                margin-bottom: 20px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }}
            .status-grid {{
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 20px;
                margin-bottom: 20px;
            }}
            .metric {{
                background: #f8f9fa;
                padding: 20px;
                border-radius: 8px;
                border-left: 4px solid #667eea;
            }}
            .metric-label {{
                font-size: 0.9em;
                color: #666;
                margin-bottom: 5px;
            }}
            .metric-value {{
                font-size: 2em;
                font-weight: bold;
                color: #333;
            }}
            .status-badge {{
                display: inline-block;
                padding: 5px 15px;
                border-radius: 20px;
                font-weight: bold;
                font-size: 0.9em;
            }}
            .footer {{
                text-align: center;
                color: #666;
                margin-top: 30px;
                padding: 20px;
                font-size: 0.9em;
            }}
            table {{
                width: 100%;
                border-collapse: collapse;
            }}
            th, td {{
                border: 1px solid #ddd;
                padding: 12px;
                text-align: left;
            }}
            th {{
                background-color: #f0f0f0;
                font-weight: 600;
            }}
            a {{
                color: #667eea;
                text-decoration: none;
            }}
            a:hover {{
                text-decoration: underline;
            }}
        </style>
    </head>
    <body>
        <div class="header">
            <h1>⏰ ATD Status</h1>
            <p>Job Scheduling Daemon - vulcan.lan</p>
        </div>

        <div class="status-grid">
            <div class="metric">
                <div class="metric-label">Service Status</div>
                <div class="metric-value">
                    <span class="status-badge" style="background-color: {service_color}; color: white;">
                        {service_status.upper()}
                    </span>
                </div>
            </div>

            <div class="metric">
                <div class="metric-label">Jobs in Queue</div>
                <div class="metric-value">{queue_count}</div>
            </div>

            <div class="metric">
                <div class="metric-label">Last Updated</div>
                <div class="metric-value" style="font-size: 1.2em;">{current_time}</div>
            </div>
        </div>

        <div class="status-card">
            <h2 style="margin-top: 0; color: #333;">Current Queue</h2>
            {queue_table}
        </div>

        <div class="footer">
            <p>Auto-refreshes every 30 seconds | Monitored by Prometheus & Nagios</p>
            <p><a href="https://grafana.vulcan.lan">View Metrics in Grafana</a> |
               <a href="https://prometheus.vulcan.lan">Prometheus</a> |
               <a href="https://nagios.vulcan.lan">Nagios</a></p>
        </div>
    </body>
    </html>"""

        def log_message(self, format, *args):
            # Suppress logging
            pass

    with socketserver.TCPServer(("127.0.0.1", PORT), AtdStatusHandler) as httpd:
        print(f"ATD web interface serving at http://127.0.0.1:{PORT}")
        httpd.serve_forever()
  '';
in
{
  # ============================================================================
  # ATD Web Status Interface
  # Simple web UI to display atd queue status and job history
  # ============================================================================

  systemd.services."atd-web" = {
    description = "ATD Web Status Interface";
    after = [
      "network.target"
      "atd.service"
    ];
    wants = [ "atd.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe atd-web-server}";
      Restart = "always";
      RestartSec = 10;

      # Security hardening
      User = "root"; # Needs to run atq and read history
      Group = "root";
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ReadWritePaths = [ ];
      # Allow reading job history
      ReadOnlyPaths = [ "/var/lib/atd-history" ];
    };
  };
}
