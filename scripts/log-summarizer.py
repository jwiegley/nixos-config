#!/usr/bin/env python3
"""
AI-Powered Log Summarization for LogWatch
Collects logs from journalctl and uses LiteLLM for intelligent summarization.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# Directory for storing AI analysis history
DEFAULT_HISTORY_DIR = "/var/log/logwatch-ai"
HISTORY_RETENTION_DAYS = 14
WISDOM_FILENAME = "known-conditions.prompt"
WISDOM_DELIMITER = "===NEW_KNOWN_CONDITIONS==="


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
    # Session/slice lifecycle (systemd-logind)
    r"Started Session \d+ of User",
    r"Removed slice .+\.slice",
    r"Created slice .+\.slice",
    r"Stopping user-.+\.slice",
    r"Starting user-.+\.slice",
    r"session-\d+\.scope: Deactivated successfully",
    r"session-\d+\.scope: Consumed",
    r"New session \d+ of user",
    r"Removed session \d+",
    r"Session \d+ logged out",
    r"Finished Clean up.+",
    r"Started Clean up.+",
    r"daily update check",
    r"Got automount request",
    r"Mounted \/run\/user",
    r"Unmounted \/run\/user",
    # Metrics scraping (Prometheus, Blackbox Exporter, VictoriaMetrics)
    r"prometheus.+: GET \/metrics",
    r"node_exporter.+: GET \/metrics",
    r"nginx.+: \d+\.\d+\.\d+\.\d+.+GET \/metrics",
    r"GET \/metrics HTTP\/",
    r"Blackbox Exporter\/",
    # Health checks and heartbeats
    r"TICK: \d+",
    r"Health check",
    r"health_check",
    r"health_status",
    r"heartbeat",
    r"PING",
    r"PONG",
    # Podman container runtime noise
    r"Started podman-\d+\.scope",
    r"container (start|die|attach|init|create|remove|cleanup)",
    # Firewall refused packets (handled at kernel level, not actionable per-entry)
    r"refused packet: IN=",
    # Redis background save (routine persistence)
    r"\d+ changes in \d+ seconds\. Saving",
    r"Background saving (started|terminated)",
    r"DB saved on disk",
    r"Fork CoW for RDB:",
    # systemd-timesyncd routine chatter
    r"Network configuration changed, trying to establish connection",
    r"Contacted time server",
    r"Timed out waiting for reply from .+:\d+",
    # ZFS pool event history (routine)
    r"class=history_event pool=",
    # Exporter service start/stop cycles (run every minute)
    r"Starting .+ Exporter",
    r"Finished .+ Exporter",
    r"exporter\.service: Deactivated successfully",
    # PAM session open/close from runuser (container management)
    r"pam_unix\(runuser:session\): session (opened|closed)",
    # systemd-run stdio-bridge
    r"Started \[systemd-run\] systemd-stdio-bridge",
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

    # Models to try in order of preference with retry budgets.
    # Each tuple: (model_name, max_seconds, initial_delay, max_delay)
    #   - max_seconds: total wall-clock budget for this model
    #   - initial_delay: seconds before first retry (doubles each attempt)
    #   - max_delay: cap on per-retry delay
    MODELS = [
        # Primary: 10 min budget with exponential backoff (lets Hera wake up / warm model)
        ("hera/Qwen3.5-122B-A10B", 600, 5, 60),
        # Secondary: 1 min budget (Hera should be awake by now)
        ("hera/Qwen3-32B", 60, 5, 30),
        # Cloud fallback: does not depend on llama-swap
        ("hera/claude-opus-4-6-thinking-32000", 60, 5, 15),
    ]

    def __init__(self, api_url: str = "http://127.0.0.1:4000/v1/chat/completions"):
        self.api_url = api_url
        self.model = self.MODELS[0][0]
        self.api_key = os.environ.get("LITELLM_API_KEY", "")
        self.timeout = 7200  # 2 hours (local LLM can be slow)

    def analyze_logs(self, grouped_logs: Dict[str, List[LogEntry]], stats: Dict,
                     time_range: str = "24 hours",
                     recent_history: str = "",
                     wisdom: str = "") -> str:
        """Analyze logs using AI and generate summary"""

        self.time_range = time_range
        self.recent_history = recent_history
        self.wisdom = wisdom
        self.new_wisdom = ""  # populated after AI call

        # Prepare log context for AI
        log_context = self._prepare_log_context(grouped_logs, stats)

        # If no significant logs, return simple summary
        if not log_context.strip():
            return self._generate_simple_summary(stats)

        # Try AI analysis with exponential backoff per model
        import time
        for model_name, max_seconds, initial_delay, max_delay in self.MODELS:
            self.model = model_name
            start_time = time.monotonic()
            delay = initial_delay
            attempt = 0

            while True:
                attempt += 1
                elapsed = time.monotonic() - start_time

                try:
                    ai_response = self._call_ai_api(log_context, stats)
                    if ai_response:
                        # Split report from new wisdom entries
                        if WISDOM_DELIMITER in ai_response:
                            parts = ai_response.split(WISDOM_DELIMITER, 1)
                            report = parts[0].strip()
                            self.new_wisdom = parts[1].strip()
                        else:
                            report = ai_response
                        return report
                except Exception as e:
                    print(f"AI analysis failed (model={model_name}, attempt {attempt}, "
                          f"{elapsed:.0f}s elapsed): {e}", file=sys.stderr)

                # Check if we have time for another retry
                remaining = max_seconds - (time.monotonic() - start_time)
                if remaining <= 0:
                    break

                sleep_time = min(delay, remaining)
                time.sleep(sleep_time)
                delay = min(delay * 2, max_delay)  # Exponential backoff with cap

            total = time.monotonic() - start_time
            print(f"Retries exhausted for {model_name} after {total:.0f}s "
                  f"({attempt} attempts), trying next model...", file=sys.stderr)

        print("All models failed, falling back to manual summary", file=sys.stderr)

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

        if self.wisdom:
            system_prompt += """

You are given a "known conditions" list describing conditions that are normal
for this system. ALWAYS omit these from the report entirely. They are known,
accepted, and do not need to be mentioned again."""

        if self.recent_history:
            system_prompt += """

You are also given analyses from previous days. If an issue has already been
reported in previous reports and appears to be a recurring, known condition
(not a new incident), omit it from today's report entirely. Only include
issues that are genuinely new or have materially changed (e.g., increased
frequency, new error messages, escalated severity). The goal is to avoid
repeating the same harmless warnings day after day."""

        system_prompt += f"""

After your report, if you identify any log items that appear to be harmless,
recurring conditions that are normal for this system and should be permanently
suppressed from future reports, output the following delimiter on its own line:

{WISDOM_DELIMITER}

Then list each new known condition as a dash-prefixed line, e.g.:
- service-name: brief description of the normal condition

Only add entries for conditions you are confident are harmless and recurring.
Do NOT repeat entries already in the known conditions list.
If there are no new conditions to add, do not output the delimiter at all."""

        wisdom_section = ""
        if self.wisdom:
            wisdom_section = f"""

Known conditions (ALWAYS omit these from the report):
{self.wisdom}
"""

        history_section = ""
        if self.recent_history:
            history_section = f"""

Previous analyses for context (omit recurring items from today's report):
{self.recent_history}
"""

        user_prompt = f"""Analyze these system logs from the past {self.time_range}:

{log_context}

Statistics:
- Total logs: {stats['total']}
- Filtered noise: {stats['filtered']}
- Critical: {stats['critical']}
- Errors: {stats['error']}
- Warnings: {stats['warning']}
{wisdom_section}{history_section}
Provide a clear, actionable summary. Omit known conditions and recurring harmless items."""

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ],
            "temperature": 0.3,
            "max_tokens": 1500,
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


class AnalysisHistory:
    """Manages saved AI analysis history for deduplication"""

    def __init__(self, history_dir: str = DEFAULT_HISTORY_DIR):
        self.history_dir = Path(history_dir)

    def save(self, analysis: str) -> None:
        """Save today's analysis to a dated log file"""
        try:
            self.history_dir.mkdir(parents=True, exist_ok=True)
            filepath = self.history_dir / f"{datetime.now().strftime('%Y-%m-%d')}.log"
            filepath.write_text(analysis)
        except Exception as e:
            print(f"Warning: Failed to save analysis history: {e}", file=sys.stderr)

    def load_recent(self, days: int = HISTORY_RETENTION_DAYS) -> str:
        """Load analyses from the last N days, excluding today"""
        if not self.history_dir.exists():
            return ""

        today = datetime.now().date()
        cutoff = today - timedelta(days=days)
        entries = []

        for filepath in sorted(self.history_dir.glob("*.log")):
            try:
                date_str = filepath.stem  # e.g. "2026-02-03"
                file_date = datetime.strptime(date_str, "%Y-%m-%d").date()
                if cutoff <= file_date < today:
                    content = filepath.read_text().strip()
                    if content:
                        entries.append(f"=== Report from {date_str} ===\n{content}")
            except (ValueError, OSError):
                continue

        return "\n\n".join(entries)

    def cleanup(self) -> None:
        """Remove analysis files older than retention period"""
        if not self.history_dir.exists():
            return

        cutoff = datetime.now().date() - timedelta(days=HISTORY_RETENTION_DAYS)
        for filepath in self.history_dir.glob("*.log"):
            try:
                file_date = datetime.strptime(filepath.stem, "%Y-%m-%d").date()
                if file_date < cutoff:
                    filepath.unlink()
            except (ValueError, OSError):
                continue

    @property
    def wisdom_path(self) -> Path:
        return self.history_dir / WISDOM_FILENAME

    def load_wisdom(self) -> str:
        """Load the accumulated known-conditions wisdom file"""
        if not self.wisdom_path.exists():
            return ""
        try:
            return self.wisdom_path.read_text().strip()
        except OSError:
            return ""

    def append_wisdom(self, new_entries: str) -> None:
        """Append newly discovered known conditions to the wisdom file"""
        new_entries = new_entries.strip()
        if not new_entries:
            return

        try:
            self.history_dir.mkdir(parents=True, exist_ok=True)

            # Read existing content to check for duplicates
            existing = ""
            if self.wisdom_path.exists():
                existing = self.wisdom_path.read_text()

            # Filter out entries that already exist (by stripping and comparing)
            existing_lines = {line.strip().lower() for line in existing.splitlines()
                             if line.strip() and not line.strip().startswith("#")}
            new_lines = []
            for line in new_entries.splitlines():
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    if stripped.lower() not in existing_lines:
                        new_lines.append(stripped)

            if not new_lines:
                return

            with open(self.wisdom_path, "a") as f:
                if not existing or not existing.endswith("\n"):
                    f.write("\n")
                for line in new_lines:
                    # Ensure dash prefix for consistency
                    if not line.startswith("- "):
                        line = f"- {line}"
                    f.write(f"{line}\n")
        except Exception as e:
            print(f"Warning: Failed to append to wisdom file: {e}", file=sys.stderr)


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
    parser.add_argument(
        '--history-dir',
        default=DEFAULT_HISTORY_DIR,
        help=f'Directory for saving/loading analysis history (default: {DEFAULT_HISTORY_DIR})'
    )
    parser.add_argument(
        '--no-history',
        action='store_true',
        help='Disable history save/load (useful for one-off runs)'
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

    # Load recent analysis history and wisdom for deduplication
    history = AnalysisHistory(args.history_dir)
    recent_history = ""
    wisdom = ""
    if not args.no_history:
        recent_history = history.load_recent()
        wisdom = history.load_wisdom()
        if recent_history and not args.quiet:
            print("Loaded recent analysis history for deduplication", file=sys.stderr)
        if wisdom and not args.quiet:
            print("Loaded known-conditions wisdom file", file=sys.stderr)

    # Analyze with AI
    if not args.quiet:
        print("Analyzing logs...", file=sys.stderr)
    analyzer = AIAnalyzer()
    summary = analyzer.analyze_logs(
        grouped_logs, collector.stats,
        time_range=time_description,
        recent_history=recent_history,
        wisdom=wisdom,
    )

    # Save today's analysis and any new wisdom
    if not args.no_history:
        history.save(summary)
        history.cleanup()
        if analyzer.new_wisdom:
            history.append_wisdom(analyzer.new_wisdom)
            if not args.quiet:
                print(f"Added new entries to {history.wisdom_path}", file=sys.stderr)
        if not args.quiet:
            print(f"Saved analysis to {args.history_dir}/", file=sys.stderr)

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
