#!/usr/bin/env python3
"""
Technitium DNS Query Log Exporter for Loki and Prometheus
Polls Technitium DNS query logs API and pushes to Loki for visualization in Grafana.
Also exposes Prometheus metrics on port 9101.
"""

import json
import os
import sys
import time
import requests
import socket
import threading
from datetime import datetime
from pathlib import Path
from prometheus_client import Counter, Gauge, start_http_server

# Configuration
TECHNITIUM_URL = os.getenv('TECHNITIUM_URL', 'http://10.88.0.1:5380')
TECHNITIUM_TOKEN = os.getenv('TECHNITIUM_TOKEN', '')
LOKI_URL = os.getenv('LOKI_URL', 'http://localhost:3100')
POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '15'))  # seconds
STATE_FILE = os.getenv('STATE_FILE', '/var/lib/dns-query-exporter/last_row.txt')
BATCH_SIZE = int(os.getenv('BATCH_SIZE', '100'))  # entries per API call
METRICS_PORT = int(os.getenv('METRICS_PORT', '9275'))  # Prometheus metrics port

APP_NAME = 'Query Logs (Sqlite)'
CLASS_PATH = 'QueryLogsSqlite.App'

# Cache for IP to hostname lookups (avoid excessive DNS queries)
hostname_cache = {}

# Prometheus metrics
# NOTE: The 'domain' label can result in high cardinality if many unique domains are queried.
# Consider monitoring metric cardinality and adding limits if needed.
dns_queries_total = Counter(
    'dns_queries_total',
    'Total number of DNS queries processed',
    ['client_hostname', 'rcode', 'qtype', 'protocol', 'domain']
)

dns_query_log_last_row = Gauge(
    'dns_query_log_last_row',
    'Last row number processed from DNS query logs'
)


def get_hostname(ip_address):
    """Get hostname for IP address via reverse DNS lookup."""
    if ip_address in hostname_cache:
        return hostname_cache[ip_address]

    try:
        # Try reverse DNS lookup
        hostname, _, _ = socket.gethostbyaddr(ip_address)
        # Remove trailing dot if present
        hostname = hostname.rstrip('.')
        hostname_cache[ip_address] = hostname
        return hostname
    except (socket.herror, socket.gaierror, socket.timeout):
        # If reverse lookup fails, use IP as hostname
        hostname_cache[ip_address] = ip_address
        return ip_address


def get_last_row_number():
    """Get the last processed row number from state file."""
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        pass
    return 0


def save_last_row_number(row_number):
    """Save the last processed row number to state file."""
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, 'w') as f:
        f.write(str(row_number))
    # Update Prometheus gauge
    dns_query_log_last_row.set(row_number)


def fetch_query_logs(page_number=1, entries_per_page=BATCH_SIZE):
    """Fetch query logs from Technitium DNS API."""
    try:
        url = f"{TECHNITIUM_URL}/api/logs/query"
        params = {
            'token': TECHNITIUM_TOKEN,
            'name': APP_NAME,
            'classPath': CLASS_PATH,
            'pageNumber': page_number,
            'entriesPerPage': entries_per_page,
        }

        response = requests.get(url, params=params, timeout=10)
        response.raise_for_status()
        data = response.json()

        if data.get('status') != 'ok':
            print(f"API error: {data.get('errorMessage', 'Unknown error')}", file=sys.stderr)
            return None

        return data.get('response', {})
    except requests.exceptions.RequestException as e:
        print(f"Failed to fetch logs: {e}", file=sys.stderr)
        return None


def format_loki_push(entries):
    """
    Format log entries for Loki push API.
    Returns dict in Loki push API format with streams grouped by labels.
    Also updates Prometheus metrics for each entry.
    """
    # Group entries by label set
    streams = {}

    for entry in entries:
        # Get hostname for client IP
        client_ip = entry['clientIpAddress']
        client_hostname = get_hostname(client_ip)

        # Extract metrics labels
        protocol = entry['protocol'].lower()
        rcode = entry['rcode'].lower()
        qtype = entry['qtype'].upper()
        domain = entry['qname'].rstrip('.')  # Remove trailing dot if present

        # Update Prometheus counter
        dns_queries_total.labels(
            client_hostname=client_hostname,
            rcode=rcode,
            qtype=qtype,
            protocol=protocol,
            domain=domain
        ).inc()

        # Create label set for this entry
        labels = {
            'job': 'dns_query_logs',
            'client_ip': client_ip,
            'client_hostname': client_hostname,
            'protocol': protocol,
            'rcode': rcode,
            'qtype': qtype,
            'response_type': entry['responseType'].lower(),
        }

        # Create label string (sorted for consistency)
        label_str = '{' + ','.join(f'{k}="{v}"' for k, v in sorted(labels.items())) + '}'

        # Convert timestamp to nanoseconds since epoch
        ts = datetime.fromisoformat(entry['timestamp'].replace('Z', '+00:00'))
        ts_ns = str(int(ts.timestamp() * 1_000_000_000))

        # Create log line with query details
        log_line = json.dumps({
            'domain': entry['qname'],
            'answer': entry.get('answer'),
            'qclass': entry['qclass'],
        })

        # Add to appropriate stream
        if label_str not in streams:
            streams[label_str] = []
        streams[label_str].append([ts_ns, log_line])

    # Convert to Loki format
    loki_streams = []
    for label_str, values in streams.items():
        # Parse label string back to dict
        # label_str looks like: {client_ip="...",job="..."}
        labels_dict = {}
        # Remove braces and split by comma
        label_pairs = label_str.strip('{}').split(',')
        for pair in label_pairs:
            key, val = pair.split('=', 1)
            labels_dict[key] = val.strip('"')

        loki_streams.append({'stream': labels_dict, 'values': values})

    return {'streams': loki_streams}


def push_to_loki(loki_data):
    """Push formatted data to Loki."""
    try:
        url = f"{LOKI_URL}/loki/api/v1/push"
        headers = {'Content-Type': 'application/json'}

        response = requests.post(url, json=loki_data, headers=headers, timeout=10)
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        print(f"Failed to push to Loki: {e}", file=sys.stderr)
        return False


def process_new_logs():
    """Fetch and process new logs since last run."""
    last_row = get_last_row_number()

    # Fetch first page to get total count
    data = fetch_query_logs(page_number=1, entries_per_page=1)
    if not data or not data.get('entries'):
        return

    total_entries = data.get('totalEntries', 0)
    latest_row = data['entries'][0]['rowNumber']

    # Check if row numbers have reset (database was cleared or rows wrapped)
    if latest_row < last_row:
        print(f"WARNING: Row numbers decreased (latest={latest_row}, last={last_row}). Database may have been reset.")
        print(f"Resetting state to process from row 0")
        last_row = 0
        save_last_row_number(0)

    if latest_row <= last_row:
        # No new logs
        return

    # Calculate how many new entries we have
    new_entries_count = latest_row - last_row
    print(f"Found {new_entries_count} new log entries (rows {last_row + 1} to {latest_row})")

    # Fetch new entries in batches
    # Note: API returns newest first, we need to fetch from page 1
    new_entries = []
    pages_to_fetch = min((new_entries_count // BATCH_SIZE) + 1, 10)  # Limit to 10 pages max

    for page in range(1, pages_to_fetch + 1):
        data = fetch_query_logs(page_number=page, entries_per_page=BATCH_SIZE)
        if not data or not data.get('entries'):
            break

        for entry in data['entries']:
            if entry['rowNumber'] > last_row:
                new_entries.append(entry)
            else:
                break  # Stop when we reach old entries

        if len(new_entries) >= new_entries_count:
            break

    if new_entries:
        # Sort entries oldest first for proper Loki ingestion
        new_entries.sort(key=lambda x: x['rowNumber'])

        # Push to Loki in batches of 100
        for i in range(0, len(new_entries), 100):
            batch = new_entries[i:i+100]
            loki_data = format_loki_push(batch)

            if push_to_loki(loki_data):
                print(f"Pushed {len(batch)} entries to Loki")
            else:
                print(f"Failed to push batch {i//100 + 1}", file=sys.stderr)
                return  # Don't update state if push failed

        # Update state with latest row
        save_last_row_number(new_entries[-1]['rowNumber'])
        print(f"Updated state to row {new_entries[-1]['rowNumber']}")


def main():
    """Main loop."""
    if not TECHNITIUM_TOKEN:
        print("ERROR: TECHNITIUM_TOKEN environment variable not set", file=sys.stderr)
        sys.exit(1)

    print(f"DNS Query Log Exporter starting...")
    print(f"Technitium URL: {TECHNITIUM_URL}")
    print(f"Loki URL: {LOKI_URL}")
    print(f"Poll interval: {POLL_INTERVAL}s")
    print(f"State file: {STATE_FILE}")
    print(f"Metrics port: {METRICS_PORT}")

    # Start Prometheus metrics HTTP server in a separate thread
    try:
        start_http_server(METRICS_PORT)
        print(f"Prometheus metrics server started on port {METRICS_PORT}")
    except Exception as e:
        print(f"Failed to start metrics server: {e}", file=sys.stderr)
        sys.exit(1)

    # Initialize the last row gauge on startup
    last_row = get_last_row_number()
    dns_query_log_last_row.set(last_row)
    print(f"Starting from row {last_row}")

    while True:
        try:
            process_new_logs()
        except Exception as e:
            print(f"Error processing logs: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc()

        time.sleep(POLL_INTERVAL)


if __name__ == '__main__':
    main()
