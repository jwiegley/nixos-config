# AI-Powered Log Summarizer

**Location**: `/etc/nixos/scripts/log-summarizer.py`

## Overview

Intelligent log analysis tool that collects system logs from journalctl and uses AI (via LiteLLM) to provide actionable summaries. Designed for integration with logwatch or standalone use.

## Features

- **Comprehensive Log Collection**: Gathers logs from all critical services:
  - Mail: dovecot2, postfix, rspamd
  - Databases: postgresql, redis
  - Web: nginx
  - IoT: home-assistant, mosquitto
  - Monitoring: prometheus, alertmanager, grafana
  - Certificates: step-ca
  - Containers: podman
  - File sharing: samba, nfs
  - System: systemd core, kernel messages

- **Intelligent Filtering**: Automatically filters out routine noise (health checks, metrics scraping, session management)

- **AI-Powered Analysis**: Uses LiteLLM API for intelligent summarization with fallback to manual grouping

- **Organized Output**: Groups logs by severity (critical → errors → warnings → notable events)

## Usage

### Basic Usage

```bash
# Run with AI analysis (requires LITELLM_API_KEY)
export LITELLM_API_KEY="your-api-key"
sudo /etc/nixos/scripts/log-summarizer.py

# Run without AI (uses fallback summary)
sudo /etc/nixos/scripts/log-summarizer.py
```

### Integration with LogWatch

Add to logwatch configuration:

```bash
# /etc/logwatch/conf/services/ai-summary.conf
Title = "AI System Log Summary"
LogFile = NONE

# /etc/logwatch/scripts/services/ai-summary
#!/bin/bash
export LITELLM_API_KEY=$(cat /run/secrets/litellm-api-key)
/etc/nixos/scripts/log-summarizer.py
```

### As a Systemd Service/Timer

Example configuration:

```nix
systemd.services.log-summarizer = {
  description = "AI-Powered Log Summarizer";
  script = ''
    export LITELLM_API_KEY=$(cat /run/secrets/litellm-api-key)
    ${pkgs.python3}/bin/python3 /etc/nixos/scripts/log-summarizer.py
  '';
  serviceConfig = {
    Type = "oneshot";
    User = "root";
  };
};

systemd.timers.log-summarizer = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "daily";
    Persistent = true;
  };
};
```

## Configuration

### Environment Variables

- `LITELLM_API_KEY`: API key for LiteLLM authentication (optional, script works without it)

### LiteLLM API Settings

Default configuration (modify in script if needed):
- **API URL**: `http://127.0.0.1:4000/v1/chat/completions`
- **Model**: `hera/gpt-oss-120b`
- **Timeout**: 45 seconds
- **Max Tokens**: 1000

### Noise Filtering

The script filters common routine patterns. To customize, edit `NOISE_PATTERNS` in the script:

```python
NOISE_PATTERNS = [
    r"Started Session \d+ of User",
    r"Health check",
    # Add your patterns here
]
```

### Severity Detection

Logs are categorized by:
- **Critical**: syslog priority 0-2, or emergency/alert/critical keywords
- **Error**: syslog priority 3, or error/failed/exception keywords
- **Warning**: syslog priority 4, or warning/timeout/refused keywords
- **Info**: Everything else that passes noise filtering

## Output Format

### With AI Analysis

```
======================================================================
AI-Powered Log Summary - 2025-11-27 13:37:42
======================================================================

CRITICAL ISSUES:
  • [timestamp] service: issue description
  → Recommended action

WARNINGS & CONCERNS:
  • [timestamp] service: warning description
  Context and impact

NOTABLE EVENTS:
  • Service started/stopped
  • Configuration changes
  • Backup completions

SYSTEM STATUS: HEALTHY/WARNING/DEGRADED/CRITICAL

Statistics: X total logs, Y filtered, Z errors, W warnings
```

### Fallback Summary (no AI)

```
System Log Summary - 2025-11-27
============================================================

ERRORS (409 total):
  hass (210 errors):
    [2025-11-26 15:39:19] Error message...
  nginx (16 errors):
    [2025-11-27 11:34:36] Error message...

WARNINGS (11682 total):
  service: N warnings
    Recent: Latest warning message

SYSTEM STATUS: DEGRADED

STATISTICS:
  Total log entries: 79,102
  Filtered (routine): 1,201
  Critical: 0
  Errors: 409
  Warnings: 11682
  Notable events: 65809
```

## Performance

- **Typical runtime**: 5-15 seconds (depending on log volume)
- **Maximum timeout**: 60 seconds (30s journalctl + 45s AI API)
- **Memory usage**: ~50-100MB (depending on log volume)
- **Log collection**: Processes 50,000-100,000 entries typical

## Troubleshooting

### "API connection error: HTTP Error 401: Unauthorized"

- Set `LITELLM_API_KEY` environment variable
- Verify LiteLLM service is running: `systemctl status litellm`
- Script will fall back to manual summary automatically

### "Timeout collecting logs for service"

- Normal for services with very large log volumes
- Script continues with other services
- Increase timeout in `_collect_service_logs()` if needed

### "No logs collected"

- Check journalctl works: `journalctl --since "24 hours ago" -n 10`
- Ensure script runs as root (needs journalctl access)
- Verify services are actually running

### High memory usage

- Reduce log collection window (change "24 hours ago" to "12 hours ago")
- Increase noise filtering patterns
- Limit logs per severity in `_prepare_log_context()`

## Dependencies

- Python 3 (standard library only)
- `journalctl` (systemd)
- Optional: LiteLLM API service

**No pip packages required** - uses only Python standard library + urllib.

## Exit Codes

- `0`: Success
- `1`: General error (log collection failed)
- `130`: Interrupted by user (Ctrl+C)

## Security Considerations

- Runs as root to access journalctl
- Sends log excerpts to LiteLLM API (review privacy requirements)
- API key passed via environment variable (not command line)
- Logs may contain sensitive information (review before sharing output)

## Future Enhancements

Potential improvements:
- Configuration file for service groups and noise patterns
- Support for custom log sources beyond journalctl
- Email delivery integration
- Persistent summary storage and trend analysis
- Custom AI prompts per service type
- Multi-day comparison analysis
