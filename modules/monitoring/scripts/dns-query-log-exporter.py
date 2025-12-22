#!/usr/bin/env python3
"""
Technitium DNS Query Log Exporter for Loki and Prometheus
Polls Technitium DNS query logs API and pushes to Loki for visualization in Grafana.
Also exposes Prometheus metrics on port 9101.
"""

import json
import os
import socket
import sys
import time
import traceback
from datetime import datetime

import requests
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

# Health monitoring metrics
authentication_failures_total = Counter(
    'authentication_failures_total',
    'Total number of authentication failures with Technitium DNS API'
)

api_errors_total = Counter(
    'api_errors_total',
    'Total number of API errors by type',
    ['error_type']  # auth, network, timeout, other
)

last_successful_query_timestamp = Gauge(
    'last_successful_query_timestamp',
    'Unix timestamp of the last successful query fetch from Technitium DNS API'
)

consecutive_failures = Gauge(
    'consecutive_failures',
    'Number of consecutive API failures (resets to 0 on success)'
)

# Fail-fast configuration
MAX_CONSECUTIVE_FAILURES = 3
current_consecutive_failures = 0


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
    with open(STATE_FILE, 'w') as state_file:
        state_file.write(str(row_number))
    # Update Prometheus gauge
    dns_query_log_last_row.set(row_number)


def fetch_query_logs(page_number=1, entries_per_page=BATCH_SIZE):
    """Fetch query logs from Technitium DNS API."""
    global current_consecutive_failures

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
            error_msg = data.get('errorMessage', 'Unknown error')
            print(f"API error: {error_msg}", file=sys.stderr)

            # Track authentication failures specifically
            if 'token' in error_msg.lower() or 'session expired' in error_msg.lower() or 'invalid' in error_msg.lower():
                authentication_failures_total.inc()
                api_errors_total.labels(error_type='auth').inc()
                current_consecutive_failures += 1
                consecutive_failures.set(current_consecutive_failures)

                # Fail-fast: exit after MAX_CONSECUTIVE_FAILURES
                if current_consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    print(f"CRITICAL: {current_consecutive_failures} consecutive authentication failures. Exiting.", file=sys.stderr)
                    print("This usually indicates a configuration issue (wrong token, expired token, or permission error).", file=sys.stderr)
                    sys.exit(1)
            else:
                api_errors_total.labels(error_type='other').inc()
                current_consecutive_failures += 1
                consecutive_failures.set(current_consecutive_failures)

            return None

        # Success - reset consecutive failures and update timestamp
        current_consecutive_failures = 0
        consecutive_failures.set(0)
        last_successful_query_timestamp.set(time.time())

        return data.get('response', {})

    except requests.exceptions.Timeout as error:
        print(f"Timeout fetching logs: {error}", file=sys.stderr)
        api_errors_total.labels(error_type='timeout').inc()
        current_consecutive_failures += 1
        consecutive_failures.set(current_consecutive_failures)
        return None
    except requests.exceptions.ConnectionError as error:
        print(f"Connection error fetching logs: {error}", file=sys.stderr)
        api_errors_total.labels(error_type='network').inc()
        current_consecutive_failures += 1
        consecutive_failures.set(current_consecutive_failures)
        return None
    except requests.exceptions.RequestException as error:
        print(f"Failed to fetch logs: {error}", file=sys.stderr)
        api_errors_total.labels(error_type='other').inc()
        current_consecutive_failures += 1
        consecutive_failures.set(current_consecutive_failures)
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
        client_hostname = get_hostname(entry['clientIpAddress'])

        # Extract metrics labels (combined to reduce variables)
        labels = {
            'job': 'dns_query_logs',
            'client_ip': entry['clientIpAddress'],
            'client_hostname': client_hostname,
            'protocol': entry['protocol'].lower(),
            'rcode': entry['rcode'].lower(),
            'qtype': entry['qtype'].upper(),
            'response_type': entry['responseType'].lower(),
        }

        # Update Prometheus counter
        dns_queries_total.labels(
            client_hostname=client_hostname,
            rcode=labels['rcode'],
            qtype=labels['qtype'],
            protocol=labels['protocol'],
            domain=entry['qname'].rstrip('.')
        ).inc()

        # Create label string (sorted for consistency)
        label_str = '{' + ','.join(f'{k}="{v}"' for k, v in sorted(labels.items())) + '}'

        # Convert timestamp to nanoseconds since epoch and create log line
        timestamp = datetime.fromisoformat(entry['timestamp'].replace('Z', '+00:00'))
        ts_ns = str(int(timestamp.timestamp() * 1_000_000_000))
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
        # Parse label string back to dict (format: {key1="val1",key2="val2"})
        labels_dict = {
            pair.split('=', 1)[0]: pair.split('=', 1)[1].strip('"')
            for pair in label_str.strip('{}').split(',')
        }
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
    except requests.exceptions.RequestException as error:
        print(f"Failed to push to Loki: {error}", file=sys.stderr)
        return False


def process_new_logs():
    """Fetch and process new logs since last run."""
    last_row = get_last_row_number()

    # Fetch first page to get total count
    data = fetch_query_logs(page_number=1, entries_per_page=1)
    if not data or not data.get('entries'):
        return

    latest_row = data['entries'][0]['rowNumber']

    # Check if row numbers have reset (database was cleared or rows wrapped)
    if latest_row < last_row:
        warning_msg = (
            f"WARNING: Row numbers decreased (latest={latest_row}, "
            f"last={last_row}). Database may have been reset."
        )
        print(warning_msg)
        print("Resetting state to process from row 0")
        last_row = 0
        save_last_row_number(0)

    if latest_row <= last_row:
        # No new logs
        return

    # Calculate how many new entries we have
    new_entries_count = latest_row - last_row
    # Only log when processing a significant number of entries (reduces noise)
    if new_entries_count >= 100:
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

            if not push_to_loki(loki_data):
                print(f"Failed to push batch {i//100 + 1}", file=sys.stderr)
                return  # Don't update state if push failed

        # Update state with latest row (silently to reduce log noise)
        save_last_row_number(new_entries[-1]['rowNumber'])


def validate_environment():
    """Validate environment variables and file permissions on startup."""
    # Check if token is set
    if not TECHNITIUM_TOKEN:
        print("ERROR: TECHNITIUM_TOKEN environment variable not set", file=sys.stderr)
        print("This is usually loaded from the secret file via EnvironmentFile.", file=sys.stderr)
        print("Check that /run/secrets/technitium-dns-exporter-env exists and is readable.", file=sys.stderr)
        sys.exit(1)

    # Check if secret file exists and is readable (via environment variable file)
    # The systemd EnvironmentFile directive loads this, but we can check the source
    secret_file = '/run/secrets/technitium-dns-exporter-env'
    if os.path.exists(secret_file):
        try:
            # Test if we can read the file
            with open(secret_file, 'r') as f:
                content = f.read()
                if 'TECHNITIUM_API_DNS_TOKEN' not in content:
                    print(f"WARNING: {secret_file} exists but doesn't contain TECHNITIUM_API_DNS_TOKEN", file=sys.stderr)
        except PermissionError:
            print(f"ERROR: Cannot read {secret_file} - permission denied", file=sys.stderr)
            print("Check that the file has correct ownership and permissions.", file=sys.stderr)
            print("Expected: owner=dns-query-exporter, group=root, mode=0440", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"WARNING: Could not validate secret file: {e}", file=sys.stderr)
    else:
        print(f"WARNING: Secret file {secret_file} not found", file=sys.stderr)
        print("Token may be loaded from environment directly instead.", file=sys.stderr)


def main():
    """Main loop."""
    # Validate environment before starting
    validate_environment()

    print("DNS Query Log Exporter starting...")
    print(f"Technitium URL: {TECHNITIUM_URL}")
    print(f"Loki URL: {LOKI_URL}")
    print(f"Poll interval: {POLL_INTERVAL}s")
    print(f"State file: {STATE_FILE}")
    print(f"Metrics port: {METRICS_PORT}")
    print(f"Fail-fast threshold: {MAX_CONSECUTIVE_FAILURES} consecutive failures")

    # Start Prometheus metrics HTTP server in a separate thread (localhost only)
    try:
        start_http_server(METRICS_PORT, addr='127.0.0.1')
        print(f"Prometheus metrics server started on 127.0.0.1:{METRICS_PORT}")
    except Exception as exception:
        print(f"Failed to start metrics server: {exception}", file=sys.stderr)
        sys.exit(1)

    # Initialize the last row gauge on startup
    last_row = get_last_row_number()
    dns_query_log_last_row.set(last_row)
    print(f"Starting from row {last_row}")

    while True:
        try:
            process_new_logs()
        except Exception as error:
            print(f"Error processing logs: {error}", file=sys.stderr)
            traceback.print_exc()

        time.sleep(POLL_INTERVAL)


if __name__ == '__main__':
    main()
