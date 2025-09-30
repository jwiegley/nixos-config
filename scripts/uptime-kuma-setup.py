#!/usr/bin/env python3
"""
Uptime Kuma Monitor Setup Script
Automatically adds monitors for all services on vulcan.lan
"""

import json
import time
import sys
import getpass
import urllib3
from typing import Dict, List, Optional
import requests
from socketio import Client

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
UPTIME_KUMA_URL = "https://uptime.vulcan.lan"
API_BASE = f"{UPTIME_KUMA_URL}/api"

# Monitor configurations
MONITORS = [
    # Web Services (HTTPS)
    {
        "type": "http",
        "name": "Jellyfin Media Server",
        "url": "https://jellyfin.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "ignoreTls": True,
        "tags": ["web", "media"]
    },
    {
        "type": "http",
        "name": "Smokeping Network Monitor",
        "url": "https://smokeping.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "ignoreTls": True,
        "tags": ["web", "monitoring"]
    },
    {
        "type": "http",
        "name": "pgAdmin Database UI",
        "url": "https://postgres.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299", "302"],
        "ignoreTls": True,
        "tags": ["web", "database"]
    },
    {
        "type": "http",
        "name": "Technitium DNS Admin",
        "url": "https://dns.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "ignoreTls": True,
        "tags": ["web", "dns", "infrastructure"]
    },
    {
        "type": "http",
        "name": "Organizr Dashboard",
        "url": "https://organizr.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "ignoreTls": True,
        "tags": ["web", "dashboard"]
    },
    {
        "type": "http",
        "name": "Wallabag Read-it-later",
        "url": "https://wallabag.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299", "302"],
        "ignoreTls": True,
        "tags": ["web", "productivity"]
    },
    {
        "type": "http",
        "name": "Grafana Metrics",
        "url": "https://grafana.vulcan.lan",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299", "302"],
        "ignoreTls": True,
        "tags": ["web", "monitoring"]
    },

    # TCP Port Monitors
    {
        "type": "port",
        "name": "PostgreSQL Database",
        "hostname": "192.168.1.2",
        "port": 5432,
        "interval": 60,
        "retryInterval": 30,
        "maxretries": 3,
        "tags": ["database", "critical"]
    },
    {
        "type": "port",
        "name": "Redis (LiteLLM)",
        "hostname": "10.88.0.1",
        "port": 8085,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["database", "ai"]
    },
    {
        "type": "port",
        "name": "Step-CA Certificate Authority",
        "hostname": "127.0.0.1",
        "port": 8443,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["security", "infrastructure", "critical"]
    },
    {
        "type": "dns",
        "name": "DNS Server",
        "hostname": "vulcan.lan",
        "dns_resolve_server": "192.168.1.2",
        "port": 53,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["dns", "infrastructure", "critical"]
    },
    {
        "type": "port",
        "name": "Postfix SMTP",
        "hostname": "192.168.1.2",
        "port": 25,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["mail", "smtp"]
    },
    {
        "type": "port",
        "name": "Postfix Submission",
        "hostname": "192.168.1.2",
        "port": 587,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["mail", "smtp"]
    },
    {
        "type": "port",
        "name": "Dovecot IMAP",
        "hostname": "192.168.1.2",
        "port": 143,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["mail", "imap"]
    },
    {
        "type": "port",
        "name": "Dovecot IMAPS",
        "hostname": "192.168.1.2",
        "port": 993,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["mail", "imap", "secure"]
    },
    {
        "type": "port",
        "name": "SSH Service",
        "hostname": "192.168.1.2",
        "port": 22,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["infrastructure", "critical"]
    },

    # Container Services
    {
        "type": "http",
        "name": "LiteLLM API",
        "url": "http://10.88.0.1:4000/health",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "tags": ["container", "ai", "api"]
    },
    {
        "type": "http",
        "name": "Home Site (External)",
        "url": "https://home.newartisans.com",
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "tags": ["web", "external"]
    },

    # Monitoring Stack
    {
        "type": "port",
        "name": "Prometheus Metrics",
        "hostname": "127.0.0.1",
        "port": 9090,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["monitoring", "metrics"]
    },
    {
        "type": "port",
        "name": "Prometheus Node Exporter",
        "hostname": "127.0.0.1",
        "port": 9100,
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "tags": ["monitoring", "metrics"]
    },

    # Certificate Expiry Monitors
    {
        "type": "http",
        "name": "Certificate Check - Jellyfin",
        "url": "https://jellyfin.vulcan.lan",
        "interval": 86400,  # Daily
        "retryInterval": 3600,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "ignoreTls": False,
        "expiryNotification": True,
        "tags": ["certificate", "security"]
    },
    {
        "type": "http",
        "name": "Certificate Check - Let's Encrypt",
        "url": "https://home.newartisans.com",
        "interval": 86400,  # Daily
        "retryInterval": 3600,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299"],
        "ignoreTls": False,
        "expiryNotification": True,
        "tags": ["certificate", "security", "external"]
    }
]

# Status page configuration
STATUS_PAGES = [
    {
        "title": "Vulcan Services Status",
        "slug": "vulcan-status",
        "description": "Public status page for all Vulcan services",
        "theme": "light",
        "published": True,
        "showTags": True,
        "groups": [
            {
                "name": "Web Services",
                "monitorTags": ["web"]
            },
            {
                "name": "Infrastructure",
                "monitorTags": ["infrastructure"]
            },
            {
                "name": "Databases",
                "monitorTags": ["database"]
            },
            {
                "name": "Mail Services",
                "monitorTags": ["mail"]
            },
            {
                "name": "Monitoring",
                "monitorTags": ["monitoring"]
            },
            {
                "name": "Security & Certificates",
                "monitorTags": ["security", "certificate"]
            }
        ]
    }
]

class UptimeKumaAPI:
    def __init__(self, url: str):
        self.url = url
        self.session = requests.Session()
        self.session.verify = False  # For self-signed certificates
        self.token = None
        self.socket = None

    def login(self, username: str, password: str) -> bool:
        """Login to Uptime Kuma"""
        try:
            # First, check if we need to set up an account
            response = self.session.get(f"{self.url}/api/need-setup", verify=False)
            if response.json().get("needSetup"):
                print("Initial setup required. Creating admin account...")
                setup_data = {
                    "username": username,
                    "password": password
                }
                response = self.session.post(
                    f"{self.url}/api/setup",
                    json=setup_data,
                    verify=False
                )
                if response.status_code != 200:
                    print(f"Setup failed: {response.text}")
                    return False
                print("Admin account created successfully!")

            # Now login
            login_data = {
                "username": username,
                "password": password
            }
            response = self.session.post(
                f"{self.url}/api/login",
                json=login_data,
                verify=False
            )

            if response.status_code == 200:
                self.token = response.json().get("token")
                print("Login successful!")
                return True
            else:
                print(f"Login failed: {response.text}")
                return False

        except Exception as e:
            print(f"Login error: {e}")
            return False

    def setup_socketio(self, username: str, password: str):
        """Setup Socket.IO connection for adding monitors"""
        self.socket = Client()
        self.socket.connect(
            self.url,
            transports=['websocket'],
            verify=False
        )

        # Wait for connection
        time.sleep(2)

        # Login via socket
        login_response = {}

        def on_login(data):
            nonlocal login_response
            login_response = data

        self.socket.on("login", on_login)
        self.socket.emit("login", {
            "username": username,
            "password": password
        })

        time.sleep(2)
        return login_response.get("ok", False)

    def add_monitor(self, monitor_config: Dict) -> bool:
        """Add a monitor via Socket.IO"""
        if not self.socket:
            print("Socket.IO not connected")
            return False

        response = {}

        def on_monitor_add(data):
            nonlocal response
            response = data

        self.socket.on("monitorAdded", on_monitor_add)

        # Prepare monitor data
        monitor_data = {
            "type": monitor_config["type"],
            "name": monitor_config["name"],
            "interval": monitor_config.get("interval", 60),
            "retryInterval": monitor_config.get("retryInterval", 60),
            "maxretries": monitor_config.get("maxretries", 3),
            "notificationIDList": []
        }

        # Add type-specific fields
        if monitor_config["type"] == "http":
            monitor_data.update({
                "url": monitor_config["url"],
                "accepted_statuscodes": monitor_config.get("accepted_statuscodes", ["200-299"]),
                "ignoreTls": monitor_config.get("ignoreTls", True),
                "expiryNotification": monitor_config.get("expiryNotification", False)
            })
        elif monitor_config["type"] == "port":
            monitor_data.update({
                "hostname": monitor_config["hostname"],
                "port": monitor_config["port"]
            })
        elif monitor_config["type"] == "dns":
            monitor_data.update({
                "hostname": monitor_config["hostname"],
                "dns_resolve_server": monitor_config.get("dns_resolve_server", "1.1.1.1"),
                "port": monitor_config.get("port", 53)
            })

        self.socket.emit("add", monitor_data)
        time.sleep(1)

        return bool(response)

    def disconnect(self):
        """Disconnect from Socket.IO"""
        if self.socket:
            self.socket.disconnect()

def main():
    print("=== Uptime Kuma Monitor Setup Script ===")
    print(f"Target: {UPTIME_KUMA_URL}")
    print("")

    # Get credentials
    print("Please enter your Uptime Kuma credentials.")
    print("If this is the first run, these will become your admin credentials.")
    username = input("Username: ")
    password = getpass.getpass("Password: ")

    # Initialize API
    api = UptimeKumaAPI(UPTIME_KUMA_URL)

    # Login
    if not api.login(username, password):
        print("Failed to login. Exiting.")
        sys.exit(1)

    # Setup Socket.IO for adding monitors
    print("\nConnecting via Socket.IO...")
    if not api.setup_socketio(username, password):
        print("Failed to setup Socket.IO connection.")
        sys.exit(1)

    print("\nAdding monitors...")
    success_count = 0
    failed_count = 0

    for monitor in MONITORS:
        print(f"Adding: {monitor['name']}...", end="")
        if api.add_monitor(monitor):
            print(" ✓")
            success_count += 1
        else:
            print(" ✗")
            failed_count += 1
        time.sleep(0.5)  # Rate limiting

    # Disconnect
    api.disconnect()

    # Summary
    print("\n=== Setup Complete ===")
    print(f"Successfully added: {success_count} monitors")
    if failed_count > 0:
        print(f"Failed: {failed_count} monitors")

    print(f"\nAccess your dashboard at: {UPTIME_KUMA_URL}")
    print("\nNote: You may need to:")
    print("1. Configure notification channels (Settings → Notifications)")
    print("2. Create status pages (Status Pages → New Status Page)")
    print("3. Adjust monitor intervals based on your needs")
    print("4. Set up maintenance windows for planned downtime")

if __name__ == "__main__":
    main()
