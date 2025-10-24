#!/usr/bin/env python3
"""
Home Assistant Device Discovery for Nagios

This script queries the Home Assistant API to discover all network devices
and generates Nagios host definitions with proper parent relationships for
network reachability monitoring.

Usage:
    nagios-ha-discovery.py --token TOKEN [--output FILE]
"""

import argparse
import json
import subprocess
import sys
from typing import Dict, List, Optional
from urllib.request import Request, urlopen
from urllib.error import URLError


class HomeAssistantDiscovery:
    """Query Home Assistant API for network devices."""

    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip('/')
        self.token = token
        self.headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json',
        }

    def get_all_states(self) -> List[Dict]:
        """Fetch all entity states from Home Assistant."""
        url = f"{self.base_url}/api/states"
        req = Request(url, headers=self.headers)

        try:
            with urlopen(req, timeout=10) as response:
                return json.loads(response.read().decode())
        except URLError as e:
            print(f"Error connecting to Home Assistant: {e}", file=sys.stderr)
            return []

    def get_device_trackers(self) -> List[Dict]:
        """Get all device_tracker entities."""
        states = self.get_all_states()
        return [s for s in states if s['entity_id'].startswith('device_tracker.')]

    @staticmethod
    def reverse_dns_lookup(ip: str) -> Optional[str]:
        """
        Perform reverse PTR lookup for an IP address using dig.
        Returns the hostname without trailing dot, or None if lookup fails.
        """
        try:
            result = subprocess.run(
                ['dig', '-x', ip, '+short'],
                capture_output=True,
                text=True,
                timeout=2
            )
            if result.returncode == 0 and result.stdout.strip():
                # dig returns hostname with trailing dot, remove it
                hostname = result.stdout.strip().rstrip('.')
                return hostname if hostname else None
            return None
        except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
            return None

    def get_network_devices(self) -> List[Dict]:
        """
        Extract network devices with IP addresses.
        Returns list of dicts with: name, hostname, ip, mac, state
        """
        devices = []
        trackers = self.get_device_trackers()

        for tracker in trackers:
            entity_id = tracker['entity_id']
            attributes = tracker.get('attributes', {})

            # Extract device information
            ip = attributes.get('ip')
            mac = attributes.get('mac')
            hostname = attributes.get('host_name') or attributes.get('hostname')
            friendly_name = attributes.get('friendly_name', entity_id)
            source_type = attributes.get('source_type', 'unknown')

            # Only include devices with IP addresses (actual network devices)
            if ip and source_type in ['router', 'dhcp', 'integration']:
                # Try reverse DNS lookup first, fall back to HA hostname, then IP
                ptr_hostname = self.reverse_dns_lookup(ip)
                resolved_hostname = ptr_hostname or hostname or ip

                device = {
                    'entity_id': entity_id,
                    'name': friendly_name,
                    'hostname': resolved_hostname,
                    'ip': ip,
                    'mac': mac,
                    'state': tracker.get('state', 'unknown'),
                    'source': source_type,
                }
                devices.append(device)

        return devices

    @staticmethod
    def categorize_device(device: Dict) -> str:
        """
        Categorize device type based on name and attributes.
        Returns: 'router', 'switch', 'server', 'ap', 'iot', 'computer', 'mobile', 'unknown'
        """
        name = device['name'].lower()
        hostname = device.get('hostname', '').lower()
        combined = f"{name} {hostname}"

        # Routers and gateways
        if any(x in combined for x in ['router', 'gateway', 'opnsense', 'firewall']):
            return 'router'

        # Switches
        if any(x in combined for x in ['switch', 'unifi']):
            return 'switch'

        # Access points
        if any(x in combined for x in ['ap-', 'access point', 'wap']):
            return 'ap'

        # Servers
        if any(x in combined for x in ['server', 'nas', 'storage', 'vulcan', 'synology']):
            return 'server'

        # IoT devices
        if any(x in combined for x in ['lock', 'thermostat', 'camera', 'doorbell',
                                        'sensor', 'bulb', 'switch', 'plug', 'vacuum']):
            return 'iot'

        # Mobile devices
        if any(x in combined for x in ['iphone', 'ipad', 'android', 'phone', 'tablet']):
            return 'mobile'

        # Computers
        if any(x in combined for x in ['mac', 'imac', 'macbook', 'pc', 'laptop', 'desktop']):
            return 'computer'

        return 'unknown'


def generate_nagios_host_definitions(devices: List[Dict], parent_host: str = 'router') -> str:
    """
    Generate Nagios host definitions from device list.

    Args:
        devices: List of device dictionaries
        parent_host: Default parent host for network hierarchy

    Returns:
        String containing Nagios host definitions
    """
    output = []
    output.append("###############################################################################")
    output.append("# AUTO-GENERATED HOST DEFINITIONS FROM HOME ASSISTANT")
    output.append("# Generated by nagios-ha-discovery.py")
    output.append("# DO NOT EDIT MANUALLY - Changes will be overwritten")
    output.append("###############################################################################")
    output.append("")

    # Categorize devices
    categorized = {}
    for device in devices:
        category = HomeAssistantDiscovery.categorize_device(device)
        if category not in categorized:
            categorized[category] = []
        categorized[category].append(device)

    # Generate host definitions by category
    category_order = ['router', 'switch', 'ap', 'server', 'computer', 'iot', 'mobile', 'unknown']

    for category in category_order:
        if category not in categorized:
            continue

        devices_in_category = categorized[category]
        output.append(f"# {category.upper()} DEVICES ({len(devices_in_category)})")
        output.append("")

        for device in devices_in_category:
            # Determine parent based on category
            if category == 'router':
                parents = None  # No parent for root devices
            elif category in ['switch', 'ap']:
                parents = parent_host
            else:
                parents = parent_host  # All other devices depend on router

            # Use resolved hostname or IP for Nagios host_name
            # Sanitize: remove spaces, convert to lowercase
            # Keep dots for FQDN hostnames (e.g., john-iphone.lan)
            # IMPORTANT: Replace colons with underscores (MAC addresses cause Nagios segfault)
            # If hostname looks like a MAC address (has colons), use IP instead
            hostname_str = device['hostname']
            if ':' in hostname_str and hostname_str.count(':') >= 2:
                # Looks like a MAC address, use IP instead
                host_name = address.replace('.', '-')
            else:
                # Normal hostname: sanitize spaces and colons
                host_name = hostname_str.replace(' ', '_').replace(':', '_').lower()
            alias = device['name']
            address = device['ip']

            output.append("define host {")
            output.append(f"  use                     network-device")
            output.append(f"  host_name               {host_name}")
            output.append(f"  alias                   {alias}")
            output.append(f"  address                 {address}")
            if parents:
                output.append(f"  parents                 {parents}")
            output.append(f"  # Category: {category}")
            output.append(f"  # MAC: {device.get('mac', 'unknown')}")
            output.append(f"  # Source: {device.get('source', 'unknown')}")
            output.append("}")
            output.append("")

    return "\n".join(output)


def main():
    parser = argparse.ArgumentParser(
        description='Discover network devices from Home Assistant for Nagios monitoring'
    )
    parser.add_argument(
        '--url',
        default='http://localhost:8123',
        help='Home Assistant base URL (default: http://localhost:8123)'
    )
    parser.add_argument(
        '--token',
        required=True,
        help='Home Assistant long-lived access token'
    )
    parser.add_argument(
        '--parent',
        default='router',
        help='Default parent host for network hierarchy (default: router)'
    )
    parser.add_argument(
        '--output',
        help='Output file for Nagios host definitions (default: stdout)'
    )
    parser.add_argument(
        '--list',
        action='store_true',
        help='List discovered devices in JSON format'
    )

    args = parser.parse_args()

    # Initialize Home Assistant discovery
    ha = HomeAssistantDiscovery(args.url, args.token)

    # Discover devices
    devices = ha.get_network_devices()

    if not devices:
        print("No network devices found", file=sys.stderr)
        return 1

    # List mode: output JSON
    if args.list:
        print(json.dumps(devices, indent=2))
        return 0

    # Generate Nagios configuration
    config = generate_nagios_host_definitions(devices, args.parent)

    # Output to file or stdout
    if args.output:
        with open(args.output, 'w') as f:
            f.write(config)
        print(f"Generated {len(devices)} host definitions to {args.output}", file=sys.stderr)
    else:
        print(config)

    return 0


if __name__ == '__main__':
    sys.exit(main())
