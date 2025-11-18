#!/usr/bin/env python3
import http.server
import socketserver
import json
import os
import time
import subprocess
from datetime import datetime
from pathlib import Path

PORT = 8089
STATUS_DIR = Path("/var/lib/vdirsyncer/status")

class StatusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.serve_html()
        elif self.path == '/metrics':
            self.serve_metrics()
        elif self.path == '/api/status':
            self.serve_api()
        else:
            self.send_response(404)
            self.end_headers()

    def serve_html(self):
        """Serve HTML status dashboard"""
        status = self.get_status()

        # Build HTML components
        sync_healthy = status['sync_healthy']
        if not sync_healthy:
            error_class = 'error'
        else:
            error_class = ''

        if sync_healthy:
            health_text = 'OK Healthy'
        else:
            health_text = 'ALERT Issues Detected'

        log_entries = ''.join(['<div class="sync-entry ' + entry["class"] + '">' + entry["message"] + '</div>' for entry in status['recent_logs']])

        html = '''<!DOCTYPE html>
<html>
<head>
    <title>vdirsyncer Status</title>
    <meta http-equiv="refresh" content="30">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
        .status-box { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; margin: 20px 0; }
        .status-card { background: #f9f9f9; padding: 15px; border-radius: 5px; border-left: 4px solid #4CAF50; }
        .status-card.error { border-left-color: #f44336; }
        .status-card h3 { margin-top: 0; color: #555; }
        .status-value { font-size: 24px; font-weight: bold; color: #333; }
        .timestamp { color: #666; font-size: 14px; }
        .sync-history { margin-top: 20px; }
        .sync-entry { padding: 10px; margin: 5px 0; background: #f9f9f9; border-radius: 3px; }
        .success { border-left: 3px solid #4CAF50; }
        .error { border-left: 3px solid #f44336; }
        pre { background: #f4f4f4; padding: 10px; border-radius: 3px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔄 vdirsyncer Status Dashboard</h1>

        <div class="status-box">
            <div class="status-card ''' + error_class + '''">
                <h3>Sync Status</h3>
                <div class="status-value">''' + health_text + '''</div>
            </div>

            <div class="status-card">
                <h3>Last Sync</h3>
                <div class="status-value">''' + status['last_sync_human'] + '''</div>
                <div class="timestamp">''' + status['last_sync_time'] + '''</div>
            </div>

            <div class="status-card">
                <h3>Sync Pairs</h3>
                <div class="status-value">''' + str(status['sync_pairs']) + '''</div>
            </div>

            <div class="status-card">
                <h3>Collections</h3>
                <div class="status-value">''' + str(status['collections_count']) + '''</div>
            </div>
        </div>

        <div class="sync-history">
            <h2>Sync Pairs Status</h2>
'''
        for pair_name, pair_data in status['pairs'].items():
            pair_healthy = pair_data['sync_healthy']
            pair_class = '' if pair_healthy else 'error'
            pair_health_text = 'Healthy' if pair_healthy else 'Issues'

            html += '''
            <div class="status-card ''' + pair_class + '''" style="margin: 10px 0;">
                <h3>''' + pair_name + '''</h3>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
                    <div>
                        <strong>Status:</strong> ''' + pair_health_text + '''<br>
                        <strong>Last Sync:</strong> ''' + pair_data['last_sync_human'] + '''<br>
                        <strong>Collections:</strong> ''' + str(pair_data['collections_count']) + '''
                    </div>
                    <div class="timestamp">''' + pair_data['last_sync_time'] + '''</div>
                </div>
            </div>
'''

        html += '''
        </div>

        <div class="sync-history">
            <h2>Recent Sync History</h2>
            ''' + log_entries + '''
        </div>

        <div style="margin-top: 20px;">
            <h2>Configuration</h2>
            <pre>Radicale: http://127.0.0.1:5232/
Fastmail: https://carddav.fastmail.com/
iCloud: https://contacts.icloud.com/
Sync Interval: 15 minutes
Status Directory: /var/lib/vdirsyncer/status/</pre>
        </div>
    </div>
</body>
</html>'''

        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(html.encode())

    def serve_metrics(self):
        """Serve Prometheus metrics"""
        status = self.get_status()

        metrics = '''# HELP vdirsyncer_last_sync_timestamp Unix timestamp of last successful sync per pair
# TYPE vdirsyncer_last_sync_timestamp gauge
'''
        for pair_name, pair_data in status['pairs'].items():
            metrics += 'vdirsyncer_last_sync_timestamp{pair="' + pair_name + '"} ' + str(pair_data['last_sync_timestamp']) + '\n'

        metrics += '''
# HELP vdirsyncer_sync_healthy Whether the sync is healthy (1) or has issues (0) per pair
# TYPE vdirsyncer_sync_healthy gauge
'''
        for pair_name, pair_data in status['pairs'].items():
            healthy_value = 1 if pair_data['sync_healthy'] else 0
            metrics += 'vdirsyncer_sync_healthy{pair="' + pair_name + '"} ' + str(healthy_value) + '\n'

        metrics += '''
# HELP vdirsyncer_collections_total Total number of collections being synced per pair
# TYPE vdirsyncer_collections_total gauge
'''
        for pair_name, pair_data in status['pairs'].items():
            metrics += 'vdirsyncer_collections_total{pair="' + pair_name + '"} ' + str(pair_data['collections_count']) + '\n'

        metrics += '''
# HELP vdirsyncer_sync_pairs_total Total number of sync pairs configured
# TYPE vdirsyncer_sync_pairs_total gauge
vdirsyncer_sync_pairs_total ''' + str(status['sync_pairs']) + '''
'''

        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.end_headers()
        self.wfile.write(metrics.encode())

    def serve_api(self):
        """Serve JSON API"""
        status = self.get_status()

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(status, indent=2).encode())

    def get_status(self):
        """Collect status information"""
        status = {
            'last_sync_timestamp': 0,
            'last_sync_time': 'Never',
            'last_sync_human': 'Never',
            'sync_healthy': False,
            'sync_pairs': 0,
            'collections_count': 0,
            'recent_logs': [],
            'pairs': {}
        }

        # Check status directory for sync pairs
        if STATUS_DIR.exists():
            # Find all pair directories (exclude .collections files)
            pair_dirs = [d for d in STATUS_DIR.iterdir() if d.is_dir()]
            status['sync_pairs'] = len(pair_dirs)

            global_latest_mtime = 0

            for pair_dir in pair_dirs:
                pair_name = pair_dir.name
                pair_files = list(pair_dir.glob('*'))
                pair_collections = len(pair_files)

                pair_data = {
                    'last_sync_timestamp': 0,
                    'last_sync_time': 'Never',
                    'last_sync_human': 'Never',
                    'sync_healthy': False,
                    'collections_count': pair_collections
                }

                if pair_files:
                    latest_mtime = max(f.stat().st_mtime for f in pair_files)
                    pair_data['last_sync_timestamp'] = int(latest_mtime)
                    pair_data['last_sync_time'] = datetime.fromtimestamp(latest_mtime).strftime('%Y-%m-%d %H:%M:%S')

                    # Calculate human-readable time difference
                    diff_seconds = time.time() - latest_mtime
                    if diff_seconds < 60:
                        pair_data['last_sync_human'] = 'Just now'
                    elif diff_seconds < 3600:
                        pair_data['last_sync_human'] = str(int(diff_seconds / 60)) + ' min ago'
                    elif diff_seconds < 86400:
                        pair_data['last_sync_human'] = str(int(diff_seconds / 3600)) + ' hours ago'
                    else:
                        pair_data['last_sync_human'] = str(int(diff_seconds / 86400)) + ' days ago'

                    # Sync is healthy if last sync was within 30 minutes
                    pair_data['sync_healthy'] = diff_seconds < 1800

                    # Track global latest sync time
                    if latest_mtime > global_latest_mtime:
                        global_latest_mtime = latest_mtime

                status['pairs'][pair_name] = pair_data
                status['collections_count'] += pair_collections

            # Set global status based on most recent sync
            if global_latest_mtime > 0:
                status['last_sync_timestamp'] = int(global_latest_mtime)
                status['last_sync_time'] = datetime.fromtimestamp(global_latest_mtime).strftime('%Y-%m-%d %H:%M:%S')

                diff_seconds = time.time() - global_latest_mtime
                if diff_seconds < 60:
                    status['last_sync_human'] = 'Just now'
                elif diff_seconds < 3600:
                    status['last_sync_human'] = str(int(diff_seconds / 60)) + ' min ago'
                elif diff_seconds < 86400:
                    status['last_sync_human'] = str(int(diff_seconds / 3600)) + ' hours ago'
                else:
                    status['last_sync_human'] = str(int(diff_seconds / 86400)) + ' days ago'

                status['sync_healthy'] = diff_seconds < 1800

        # Get recent logs from journalctl
        try:
            result = subprocess.run(
                ['journalctl', '-u', 'vdirsyncer.service', '-n', '10', '--no-pager'],
                capture_output=True,
                text=True,
                timeout=5
            )

            for line in result.stdout.split('\n')[-10:]:
                if line.strip():
                    if 'error' not in line.lower():
                        entry_class = 'success'
                    else:
                        entry_class = 'error'
                    status['recent_logs'].append({
                        'message': line,
                        'class': entry_class
                    })
        except Exception as e:
            status['recent_logs'].append({
                'message': 'Error fetching logs: ' + str(e),
                'class': 'error'
            })

        return status

    def log_message(self, format, *args):
        pass  # Suppress request logging

with socketserver.TCPServer(('127.0.0.1', PORT), StatusHandler) as httpd:
    print('vdirsyncer status dashboard running on port ' + str(PORT))
    httpd.serve_forever()
