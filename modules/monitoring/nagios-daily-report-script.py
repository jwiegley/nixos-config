#!/usr/bin/env python3
import re
import sys
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict, Counter

# Configuration will be set via environment variables or command-line args
import os

STATUS_FILE = Path(os.getenv("STATUS_FILE", "/var/lib/nagios/status.dat"))
LOG_FILE = Path(os.getenv("LOG_FILE", "/var/log/nagios/nagios.log"))
SMTP_HOST = os.getenv("SMTP_HOST", "localhost")
SMTP_PORT = int(os.getenv("SMTP_PORT", "25"))
FROM_EMAIL = os.getenv("FROM_EMAIL", "nagios@vulcan.lan")
TO_EMAIL = os.getenv("TO_EMAIL", "johnw@newartisans.com")

def parse_status_file():
    """Parse Nagios status.dat file to get current service states."""
    services = []

    if not STATUS_FILE.exists():
        print(f"Error: Status file not found: {STATUS_FILE}", file=sys.stderr)
        return services

    with open(STATUS_FILE, 'r') as f:
        content = f.read()

    # Parse servicestatus blocks
    service_pattern = re.compile(
        r'servicestatus\s*\{(.*?)\}',
        re.DOTALL
    )

    for match in service_pattern.finditer(content):
        block = match.group(1)
        service = {}

        for line in block.split('\n'):
            line = line.strip()
            if '=' in line:
                key, value = line.split('=', 1)
                service[key.strip()] = value.strip()

        if 'host_name' in service and 'service_description' in service:
            services.append(service)

    return services

def parse_log_file_for_changes():
    """Parse Nagios log for service state changes in last 24 hours."""
    changes = []
    cutoff_time = datetime.now() - timedelta(hours=24)

    if not LOG_FILE.exists():
        print(f"Warning: Log file not found: {LOG_FILE}", file=sys.stderr)
        return changes

    # Pattern: [TIMESTAMP] SERVICE ALERT: hostname;service;STATE;SOFT/HARD;attempts;output
    alert_pattern = re.compile(
        r'\[(\d+)\] SERVICE ALERT: ([^;]+);([^;]+);(OK|WARNING|CRITICAL|UNKNOWN);(SOFT|HARD);(\d+);(.+)'
    )

    try:
        with open(LOG_FILE, 'r') as f:
            for line in f:
                match = alert_pattern.search(line)
                if match:
                    timestamp = int(match.group(1))
                    event_time = datetime.fromtimestamp(timestamp)

                    if event_time >= cutoff_time:
                        changes.append({
                            'time': event_time,
                            'host': match.group(2),
                            'service': match.group(3),
                            'state': match.group(4),
                            'type': match.group(5),
                            'attempts': match.group(6),
                            'output': match.group(7)
                        })
    except Exception as e:
        print(f"Error reading log file: {e}", file=sys.stderr)

    # Sort by time (most recent first)
    changes.sort(key=lambda x: x['time'], reverse=True)
    return changes

def generate_html_report(services, changes):
    """Generate HTML email report."""
    # Count services by state
    state_counts = Counter()
    services_by_state = defaultdict(list)

    for service in services:
        state = service.get('current_state', '0')
        state_name = {
            '0': 'OK',
            '1': 'WARNING',
            '2': 'CRITICAL',
            '3': 'UNKNOWN'
        }.get(state, 'UNKNOWN')

        state_counts[state_name] += 1
        services_by_state[state_name].append({
            'host': service.get('host_name', 'unknown'),
            'description': service.get('service_description', 'unknown'),
            'output': service.get('plugin_output', ''),
            'last_check': service.get('last_check', '0'),
            'duration': service.get('last_state_change', '0')
        })

    total = sum(state_counts.values())

    # Calculate percentages
    ok_pct = (state_counts['OK'] / total * 100) if total > 0 else 0

    # Generate report timestamp
    report_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Build HTML
    html = f'''
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        body {{
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
            background-color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        h1 {{
            color: #333;
            border-bottom: 3px solid #4CAF50;
            padding-bottom: 10px;
        }}
        h2 {{
            color: #555;
            margin-top: 30px;
            border-bottom: 2px solid #ddd;
            padding-bottom: 5px;
        }}
        .summary {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }}
        .summary-card {{
            padding: 20px;
            border-radius: 5px;
            text-align: center;
            color: white;
            font-weight: bold;
        }}
        .summary-card.ok {{ background-color: #4CAF50; }}
        .summary-card.warning {{ background-color: #FF9800; }}
        .summary-card.critical {{ background-color: #F44336; }}
        .summary-card.unknown {{ background-color: #9E9E9E; }}
        .summary-card .count {{ font-size: 36px; display: block; }}
        .summary-card .label {{ font-size: 14px; margin-top: 5px; }}
        table {{
            width: 100%;
            border-collapse: collapse;
            margin: 15px 0;
        }}
        th {{
            background-color: #333;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: bold;
        }}
        td {{
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }}
        tr:hover {{
            background-color: #f5f5f5;
        }}
        .state-ok {{ color: #4CAF50; font-weight: bold; }}
        .state-warning {{ color: #FF9800; font-weight: bold; }}
        .state-critical {{ color: #F44336; font-weight: bold; }}
        .state-unknown {{ color: #9E9E9E; font-weight: bold; }}
        .timestamp {{
            color: #666;
            font-size: 12px;
        }}
        .footer {{
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
            text-align: center;
            color: #666;
            font-size: 12px;
        }}
        .health-indicator {{
            font-size: 24px;
            font-weight: bold;
            margin: 20px 0;
            padding: 15px;
            border-radius: 5px;
            text-align: center;
        }}
        .health-good {{ background-color: #E8F5E9; color: #2E7D32; }}
        .health-degraded {{ background-color: #FFF3E0; color: #E65100; }}
        .health-poor {{ background-color: #FFEBEE; color: #C62828; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Nagios Daily Health Report</h1>
        <p class="timestamp">Generated: {report_time} | Period: Last 24 hours</p>

        <div class="health-indicator {'health-good' if ok_pct >= 95 else 'health-degraded' if ok_pct >= 85 else 'health-poor'}">
            Overall Health: {ok_pct:.1f}% Services OK
        </div>

        <h2>Summary Statistics</h2>
        <div class="summary">
            <div class="summary-card ok">
                <span class="count">{state_counts['OK']}</span>
                <span class="label">OK</span>
            </div>
            <div class="summary-card warning">
                <span class="count">{state_counts['WARNING']}</span>
                <span class="label">WARNING</span>
            </div>
            <div class="summary-card critical">
                <span class="count">{state_counts['CRITICAL']}</span>
                <span class="label">CRITICAL</span>
            </div>
            <div class="summary-card unknown">
                <span class="count">{state_counts['UNKNOWN']}</span>
                <span class="label">UNKNOWN</span>
            </div>
        </div>

        <p style="text-align: center; color: #666;">
            Total Services Monitored: <strong>{total}</strong>
        </p>
'''

    # Add non-OK services section
    if state_counts['CRITICAL'] > 0 or state_counts['WARNING'] > 0 or state_counts['UNKNOWN'] > 0:
        html += '<h2>Services Requiring Attention</h2>\n'

        for state in ['CRITICAL', 'WARNING', 'UNKNOWN']:
            if services_by_state[state]:
                html += f'<h3 class="state-{state.lower()}">{state} ({len(services_by_state[state])})</h3>\n'
                html += '<table>\n'
                html += '<tr><th>Host</th><th>Service</th><th>Output</th></tr>\n'

                for svc in sorted(services_by_state[state], key=lambda x: (x['host'], x['description'])):
                    html += f'''<tr>
                        <td>{svc['host']}</td>
                        <td>{svc['description']}</td>
                        <td>{svc['output'][:100]}</td>
                    </tr>\n'''

                html += '</table>\n'
    else:
        html += '<h2>✓ All Services Healthy</h2>\n'
        html += '<p style="color: #4CAF50; font-size: 18px;">No services require attention at this time.</p>\n'

    # Add state changes section
    if changes:
        html += f'<h2>State Changes (Last 24 Hours) - {len(changes)} events</h2>\n'
        html += '<table>\n'
        html += '<tr><th>Time</th><th>Host</th><th>Service</th><th>State</th><th>Type</th><th>Output</th></tr>\n'

        # Limit to most recent 50 changes
        for change in changes[:50]:
            state_class = f"state-{change['state'].lower()}"
            time_str = change['time'].strftime("%Y-%m-%d %H:%M:%S")
            html += f'''<tr>
                <td class="timestamp">{time_str}</td>
                <td>{change['host']}</td>
                <td>{change['service']}</td>
                <td class="{state_class}">{change['state']}</td>
                <td>{change['type']}</td>
                <td>{change['output'][:80]}</td>
            </tr>\n'''

        html += '</table>\n'

        if len(changes) > 50:
            html += f'<p style="color: #666; font-style: italic;">Showing most recent 50 of {len(changes)} total changes</p>\n'
    else:
        html += '<h2>State Changes (Last 24 Hours)</h2>\n'
        html += '<p style="color: #666;">No state changes in the last 24 hours.</p>\n'

    # Footer
    html += f'''
        <div class="footer">
            <p>This is an automated report from Nagios on vulcan.lan</p>
            <p>Web Interface: <a href="https://nagios.vulcan.lan">https://nagios.vulcan.lan</a></p>
        </div>
    </div>
</body>
</html>
'''

    return html

def send_email(html_content):
    """Send the HTML report via email."""
    try:
        # Create message
        msg = MIMEMultipart('alternative')
        msg['Subject'] = f"Nagios Daily Health Report - {datetime.now().strftime('%Y-%m-%d')}"
        msg['From'] = FROM_EMAIL
        msg['To'] = TO_EMAIL

        # Attach HTML content
        html_part = MIMEText(html_content, 'html')
        msg.attach(html_part)

        # Send via localhost SMTP
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.send_message(msg)

        print(f"Report sent successfully to {TO_EMAIL}")
        return True

    except Exception as e:
        print(f"Error sending email: {e}", file=sys.stderr)
        return False

def main():
    """Main execution."""
    print("Generating Nagios daily health report...")

    # Parse current status
    services = parse_status_file()
    if not services:
        print("Error: No services found in status file", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(services)} services")

    # Parse log for changes
    changes = parse_log_file_for_changes()
    print(f"Found {len(changes)} state changes in last 24 hours")

    # Generate report
    html = generate_html_report(services, changes)

    # Send email
    if send_email(html):
        print("Daily report completed successfully")
        sys.exit(0)
    else:
        print("Failed to send daily report", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
