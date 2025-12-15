#!/usr/bin/env python3
"""
AI-Powered Log Summarization for LogWatch
Collects logs from journalctl and uses LiteLLM for intelligent summarization.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error
from collections import defaultdict
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Optional


# Service groups to monitor
SERVICE_GROUPS = {
    "mail": ["dovecot2", "postfix", "rspamd"],
    "databases": ["postgresql", "redis"],
    "web": ["nginx"],
    "iot": ["home-assistant", "hass", "mosquitto"],
    "monitoring": ["prometheus", "alertmanager", "grafana"],
    "certificates": ["step-ca"],
    "containers": ["podman"],
    "file_sharing": ["smbd", "nmbd", "nfs-server"],
}

# Patterns to filter out routine noise
NOISE_PATTERNS = [
    r"Started Session \d+ of User",
    r"Removed slice .+\.slice",
    r"Created slice .+\.slice",
    r"Stopping user-.+\.slice",
    r"Starting user-.+\.slice",
    r"session-\d+\.scope: Deactivated successfully",
    r"session-\d+\.scope: Consumed",
    r"New session \d+ of user",
    r"Finished Clean up.+",
    r"Started Clean up.+",
    r"daily update check",
    r"Got automount request",
    r"Mounted \/run\/user",
    r"Unmounted \/run\/user",
    r"prometheus.+: GET \/metrics",
    r"node_exporter.+: GET \/metrics",
    r"nginx.+: \d+\.\d+\.\d+\.\d+.+GET \/metrics",
    r"TICK: \d+",
    r"Health check",
    r"health_check",
    r"heartbeat",
    r"PING",
    r"PONG",
]

# Severity keywords
ERROR_KEYWORDS = [
    "error", "failed", "failure", "critical", "fatal", "panic",
    "exception", "died", "killed", "segfault", "crash"
]

WARNING_KEYWORDS = [
    "warn", "warning", "deprecated", "timeout", "refused",
    "rejected", "denied", "unauthorized", "invalid"
]


class LogEntry:
    """Represents a single log entry"""

    def __init__(self, timestamp: str, service: str, message: str, priority: int):
        self.timestamp = timestamp
        self.service = service
        self.message = message
        self.priority = priority
        self.severity = self._determine_severity()

    def _determine_severity(self) -> str:
        """Determine severity based on priority and message content"""
        msg_lower = self.message.lower()

        # Priority-based (syslog levels: 0=emerg, 1=alert, 2=crit, 3=err, 4=warn, 5=notice, 6=info, 7=debug)
        if self.priority <= 2:
            return "critical"
        elif self.priority == 3 or any(kw in msg_lower for kw in ERROR_KEYWORDS):
            return "error"
        elif self.priority == 4 or any(kw in msg_lower for kw in WARNING_KEYWORDS):
            return "warning"
        else:
            return "info"

    def is_noise(self) -> bool:
        """Check if this entry matches noise patterns"""
        for pattern in NOISE_PATTERNS:
            if re.search(pattern, self.message, re.IGNORECASE):
                return True
        return False


class LogCollector:
    """Collects and filters logs from journalctl"""

    def __init__(self):
        self.logs: List[LogEntry] = []
        self.stats = {
            "total": 0,
            "filtered": 0,
            "critical": 0,
            "error": 0,
            "warning": 0,
            "info": 0,
        }

    def collect_logs(self, since: str = "24 hours ago") -> bool:
        """Collect logs from journalctl"""
        try:
            # Collect all service logs
            for group, services in SERVICE_GROUPS.items():
                for service in services:
                    self._collect_service_logs(service, since)

            # Collect systemd core logs
            self._collect_systemd_logs(since)

            # Collect kernel logs
            self._collect_kernel_logs(since)

            return True
        except Exception as e:
            print(f"Error collecting logs: {e}", file=sys.stderr)
            return False

    def _collect_service_logs(self, service: str, since: str):
        """Collect logs for a specific service"""
        try:
            cmd = [
                "journalctl",
                "-u", f"{service}.service",
                "--since", since,
                "--output=json",
                "--no-pager",
            ]

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                self._parse_json_logs(result.stdout)
        except subprocess.TimeoutExpired:
            print(f"Warning: Timeout collecting logs for {service}", file=sys.stderr)
        except Exception as e:
            # Service might not exist, silently continue
            pass

    def _collect_systemd_logs(self, since: str):
        """Collect systemd core logs (boot, failed services)"""
        try:
            cmd = [
                "journalctl",
                "-t", "systemd",
                "--since", since,
                "--output=json",
                "--no-pager",
            ]

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                self._parse_json_logs(result.stdout)
        except Exception as e:
            print(f"Warning: Error collecting systemd logs: {e}", file=sys.stderr)

    def _collect_kernel_logs(self, since: str):
        """Collect kernel logs"""
        try:
            cmd = [
                "journalctl",
                "-k",
                "--since", since,
                "--output=json",
                "--no-pager",
            ]

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                self._parse_json_logs(result.stdout)
        except Exception as e:
            print(f"Warning: Error collecting kernel logs: {e}", file=sys.stderr)

    def _parse_json_logs(self, json_output: str):
        """Parse JSON log output from journalctl"""
        for line in json_output.strip().split('\n'):
            if not line:
                continue

            try:
                entry = json.loads(line)

                # Extract relevant fields
                timestamp = entry.get("__REALTIME_TIMESTAMP", "")
                if timestamp:
                    # Convert microseconds to datetime
                    dt = datetime.fromtimestamp(int(timestamp) / 1000000)
                    timestamp = dt.strftime("%Y-%m-%d %H:%M:%S")

                service = entry.get("SYSLOG_IDENTIFIER", entry.get("_SYSTEMD_UNIT", "system"))
                message = entry.get("MESSAGE", "")
                priority = int(entry.get("PRIORITY", "6"))

                if message:
                    self.stats["total"] += 1
                    log_entry = LogEntry(timestamp, service, message, priority)

                    if not log_entry.is_noise():
                        self.logs.append(log_entry)
                        self.stats[log_entry.severity] += 1
                    else:
                        self.stats["filtered"] += 1

            except (json.JSONDecodeError, ValueError, KeyError):
                continue

    def get_grouped_logs(self) -> Dict[str, List[LogEntry]]:
        """Group logs by severity"""
        grouped = defaultdict(list)
        for log in self.logs:
            grouped[log.severity].append(log)
        return grouped


class AIAnalyzer:
    """AI-powered log analysis using LiteLLM"""

    def __init__(self, api_url: str = "http://127.0.0.1:4000/v1/chat/completions"):
        self.api_url = api_url
        self.model = "hera/gpt-oss-120b"
        self.api_key = os.environ.get("LITELLM_API_KEY", "")
        self.timeout = 7200  # 2 hours (local LLM can be slow)

    def analyze_logs(self, grouped_logs: Dict[str, List[LogEntry]], stats: Dict,
                     time_range: str = "24 hours") -> str:
        """Analyze logs using AI and generate summary"""

        self.time_range = time_range

        # Prepare log context for AI
        log_context = self._prepare_log_context(grouped_logs, stats)

        # If no significant logs, return simple summary
        if not log_context.strip():
            return self._generate_simple_summary(stats)

        # Try AI analysis
        try:
            ai_summary = self._call_ai_api(log_context, stats)
            if ai_summary:
                return ai_summary
        except Exception as e:
            print(f"AI analysis failed: {e}", file=sys.stderr)

        # Fallback to manual summary
        return self._generate_fallback_summary(grouped_logs, stats)

    def _prepare_log_context(self, grouped_logs: Dict[str, List[LogEntry]], stats: Dict) -> str:
        """Prepare log context for AI analysis"""
        context_parts = []

        # Include critical and error logs (limit to prevent token overflow)
        for severity in ["critical", "error", "warning"]:
            if severity in grouped_logs:
                logs = grouped_logs[severity][:50]  # Limit per severity
                if logs:
                    context_parts.append(f"\n=== {severity.upper()} LOGS ===")
                    for log in logs:
                        context_parts.append(f"[{log.timestamp}] {log.service}: {log.message[:200]}")

        # Add sample of info logs if there are interesting ones
        if "info" in grouped_logs and stats["critical"] == 0 and stats["error"] == 0:
            info_logs = [log for log in grouped_logs["info"][:20]
                        if any(kw in log.message.lower() for kw in
                              ["started", "stopped", "configured", "updated", "backup", "connected", "disconnected"])]
            if info_logs:
                context_parts.append("\n=== NOTABLE EVENTS ===")
                for log in info_logs:
                    context_parts.append(f"[{log.timestamp}] {log.service}: {log.message[:200]}")

        return "\n".join(context_parts)

    def _call_ai_api(self, log_context: str, stats: Dict) -> Optional[str]:
        """Call LiteLLM API for analysis"""

        system_prompt = """You are an expert system administrator analyzing server logs.
Provide a concise, factual summary organized by:
1. Critical issues (if any) - with recommended actions
2. Warnings (if any) - with context
3. Notable events (if any) - brief mention
4. System status - overall health assessment

Output plain ASCII text only. Do NOT use:
- Markdown formatting (no asterisks, underscores, or backticks)
- Emojis or special Unicode characters
- Uppercase for emphasis

Use simple dashes (-) for bullet points. Be factual and concise.
Report what happened and what to do about it, without dramatization."""

        user_prompt = f"""Analyze these system logs from the past {self.time_range}:

{log_context}

Statistics:
- Total logs: {stats['total']}
- Filtered noise: {stats['filtered']}
- Critical: {stats['critical']}
- Errors: {stats['error']}
- Warnings: {stats['warning']}

Provide a clear, actionable summary."""

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ],
            "temperature": 0.3,
            "max_tokens": 1000,
        }

        headers = {
            "Content-Type": "application/json",
        }

        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        try:
            req = urllib.request.Request(
                self.api_url,
                data=json.dumps(payload).encode('utf-8'),
                headers=headers,
                method='POST'
            )

            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                result = json.loads(response.read().decode('utf-8'))

                if "choices" in result and len(result["choices"]) > 0:
                    return result["choices"][0]["message"]["content"]

        except urllib.error.URLError as e:
            print(f"API connection error: {e}", file=sys.stderr)
        except Exception as e:
            print(f"API call error: {e}", file=sys.stderr)

        return None

    def _generate_simple_summary(self, stats: Dict) -> str:
        """Generate simple summary when no significant logs"""
        return f"""System Log Summary - {datetime.now().strftime('%Y-%m-%d %H:%M')}
{'=' * 60}

Time Range: {self.time_range}

SYSTEM STATUS: All systems operating normally

No critical issues, errors, or warnings detected in this time period.

STATISTICS:
- Total log entries processed: {stats['total']:,}
- Routine entries filtered: {stats['filtered']:,}
- Significant entries: {stats['critical'] + stats['error'] + stats['warning'] + stats['info']}

All monitored services (mail, databases, web, IoT, monitoring, certificates,
containers, and file sharing) are functioning within normal parameters.
"""

    def _generate_fallback_summary(self, grouped_logs: Dict[str, List[LogEntry]], stats: Dict) -> str:
        """Generate fallback summary without AI"""
        lines = [
            f"System Log Summary - {datetime.now().strftime('%Y-%m-%d %H:%M')}",
            "=" * 60,
            f"Time Range: {self.time_range}",
            ""
        ]

        # Critical issues
        if "critical" in grouped_logs and grouped_logs["critical"]:
            lines.append("CRITICAL ISSUES:")
            for log in grouped_logs["critical"][:10]:
                lines.append(f"  [{log.timestamp}] {log.service}: {log.message[:150]}")
            lines.append("")

        # Errors
        if "error" in grouped_logs and grouped_logs["error"]:
            lines.append(f"ERRORS ({len(grouped_logs['error'])} total):")

            # Group by service
            by_service = defaultdict(list)
            for log in grouped_logs["error"]:
                by_service[log.service].append(log)

            for service, logs in sorted(by_service.items()):
                lines.append(f"  {service} ({len(logs)} errors):")
                for log in logs[:3]:
                    lines.append(f"    [{log.timestamp}] {log.message[:120]}")
            lines.append("")

        # Warnings
        if "warning" in grouped_logs and grouped_logs["warning"]:
            lines.append(f"WARNINGS ({len(grouped_logs['warning'])} total):")

            # Group by service
            by_service = defaultdict(list)
            for log in grouped_logs["warning"]:
                by_service[log.service].append(log)

            for service, logs in sorted(by_service.items()):
                if len(logs) >= 3:  # Only show services with multiple warnings
                    lines.append(f"  {service}: {len(logs)} warnings")
                    lines.append(f"    Recent: {logs[-1].message[:120]}")
            lines.append("")

        # System status
        status = "HEALTHY"
        if stats["critical"] > 0:
            status = "CRITICAL"
        elif stats["error"] > 10:
            status = "DEGRADED"
        elif stats["warning"] > 20:
            status = "WARNING"

        lines.append(f"SYSTEM STATUS: {status}")
        lines.append("")

        # Statistics
        lines.append("STATISTICS:")
        lines.append(f"  Total log entries: {stats['total']:,}")
        lines.append(f"  Filtered (routine): {stats['filtered']:,}")
        lines.append(f"  Critical: {stats['critical']}")
        lines.append(f"  Errors: {stats['error']}")
        lines.append(f"  Warnings: {stats['warning']}")
        lines.append(f"  Notable events: {stats['info']}")

        return "\n".join(lines)


def parse_time_range(time_str: str) -> Tuple[str, str]:
    """
    Parse user-friendly time range into journalctl --since format.

    Args:
        time_str: User input like "2h", "30m", "1d", "2 hours", "last 2 hours"

    Returns:
        Tuple of (journalctl_since_format, human_readable_description)
    """
    import re

    # Clean up input
    time_str = time_str.lower().strip()

    # Remove common prefixes
    for prefix in ["last ", "past ", "previous "]:
        if time_str.startswith(prefix):
            time_str = time_str[len(prefix):]

    # Try to parse shorthand formats like "2h", "30m", "1d"
    shorthand_match = re.match(r'^(\d+)\s*([hmds])$', time_str)
    if shorthand_match:
        value = int(shorthand_match.group(1))
        unit = shorthand_match.group(2)
        unit_map = {
            'h': ('hours', 'hour' if value == 1 else 'hours'),
            'm': ('minutes', 'minute' if value == 1 else 'minutes'),
            'd': ('days', 'day' if value == 1 else 'days'),
            's': ('seconds', 'second' if value == 1 else 'seconds'),
        }
        full_unit, display_unit = unit_map[unit]
        return (f"{value} {full_unit} ago", f"{value} {display_unit}")

    # Try to parse full formats like "2 hours", "30 minutes"
    full_match = re.match(r'^(\d+)\s*(hours?|minutes?|mins?|days?|seconds?|secs?)$', time_str)
    if full_match:
        value = int(full_match.group(1))
        unit = full_match.group(2)

        # Normalize unit names
        if unit.startswith('min'):
            unit = 'minutes'
        elif unit.startswith('sec'):
            unit = 'seconds'
        elif unit.startswith('hour'):
            unit = 'hours'
        elif unit.startswith('day'):
            unit = 'days'

        display_unit = unit[:-1] if value == 1 and unit.endswith('s') else unit
        return (f"{value} {unit} ago", f"{value} {display_unit}")

    # If it's already in journalctl format (contains "ago"), use as-is
    if "ago" in time_str:
        # Extract the descriptive part
        desc = time_str.replace(" ago", "").strip()
        return (time_str, desc)

    # Default: treat as literal journalctl --since value
    return (time_str, time_str)


def main() -> int:
    """Main execution function"""

    parser = argparse.ArgumentParser(
        description="AI-powered system log analysis",
        epilog="""
Examples:
  %(prog)s                    # Analyze last 24 hours (default)
  %(prog)s --since "2 hours"  # Analyze last 2 hours
  %(prog)s --since 30m        # Analyze last 30 minutes
  %(prog)s --since 1d         # Analyze last 1 day
  %(prog)s --since "2024-12-08 10:00" # Since specific time
        """
    )
    parser.add_argument(
        '--since', '-s',
        default="24 hours ago",
        help='Time range to analyze (e.g., "2 hours", "30m", "1d", "24 hours ago")'
    )
    parser.add_argument(
        '--quiet', '-q',
        action='store_true',
        help='Suppress progress messages to stderr'
    )

    args = parser.parse_args()

    # Parse the time range
    since_value, time_description = parse_time_range(args.since)

    # Collect logs
    if not args.quiet:
        print(f"Collecting logs from the past {time_description}...", file=sys.stderr)
    collector = LogCollector()

    if not collector.collect_logs(since=since_value):
        print("Error: Failed to collect logs", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"Collected {collector.stats['total']} log entries, filtered {collector.stats['filtered']} routine entries",
              file=sys.stderr)

    # Group logs
    grouped_logs = collector.get_grouped_logs()

    # Analyze with AI
    if not args.quiet:
        print("Analyzing logs...", file=sys.stderr)
    analyzer = AIAnalyzer()
    summary = analyzer.analyze_logs(grouped_logs, collector.stats, time_range=time_description)

    # Output summary
    print(summary)
    print()
    print("=" * 70)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        sys.exit(1)
