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

- **Persistent History / Deduplication**: keeps prior analyses under
  `/var/log/logwatch-ai` (14-day retention) and loads an accumulated
  `known-conditions.prompt` "wisdom" file so recurring conditions are not
  re-reported every day. Disable with `--no-history`.

## Usage

### Basic Usage

```bash
# Preferred: the analyze-logs wrapper reads the API key from SOPS for you
sudo analyze-logs
sudo analyze-logs --since 2h --no-history

# Direct invocation, supplying the key yourself
export LITELLM_API_KEY="your-api-key"
sudo /etc/nixos/scripts/log-summarizer.py

# Without a key it still runs, falling back to the non-AI grouped summary
sudo /etc/nixos/scripts/log-summarizer.py
```

### Integration with LogWatch — already done (verified 2026-07-27)

You do **not** need to hand-write logwatch config files for this; the integration is
declarative in `modules/services/monitoring.nix`:

- `analyzeLogsScript` (`:91`) is a `writeShellApplication` named **`analyze-logs`**
  that exports `LITELLM_API_KEY` from `/run/secrets/litellm-vulcan-lan-logwatch`
  and execs the summarizer. It is installed into `environment.systemPackages`, so
  **`sudo analyze-logs` is the normal way to run this tool.**
- `logwatchAiScript` (`:112`) wraps it as `analyze-logs --quiet` and is registered
  as the logwatch custom service `ai-log-summary`
  ("AI-Powered System Log Analysis") under `services.logwatch.customServices`.
- Logwatch itself runs from `logwatch.timer` with
  `range = "since 24 hours ago for those hours"`, mailing `johnw@vulcan.lan`.

Note the secret name: the key is `litellm-vulcan-lan` deployed as
`/run/secrets/litellm-vulcan-lan-logwatch`. There is no `/run/secrets/litellm-api-key`.

### As a Systemd Service/Timer

Not currently used — the daily run happens via logwatch (above). Illustrative
configuration if you ever want a dedicated timer:

```nix
systemd.services.log-summarizer = {
  description = "AI-Powered Log Summarizer";
  script = ''
    export LITELLM_API_KEY=$(cat /run/secrets/litellm-vulcan-lan-logwatch)
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

### Command-Line Options

- `--since` / `-s` — time range to analyze (default `"24 hours ago"`; accepts
  `"2 hours"`, `"30m"`, `"1d"`, `"2024-12-08 10:00"`)
- `--quiet` / `-q` — suppress progress messages on stderr (what the logwatch
  wrapper uses)
- `--model` / `-m` — bypass the model cascade and use exactly this model
- `--models-config` — path to the models JSON (default `/etc/models.json`; also
  settable via the `MODELS_CONFIG` env var)
- `--history-dir` — where analysis history is kept (default `/var/log/logwatch-ai`)
- `--no-history` — disable history save/load, for one-off runs

### Environment Variables

- `LITELLM_API_KEY`: API key for LiteLLM authentication (optional, script works without it)
- `MODELS_CONFIG`: override the models JSON path (same as `--models-config`)

### LiteLLM API Settings

Verified against the script 2026-07-27:
- **API URL**: `http://127.0.0.1:4000/v1/chat/completions`
- **Model**: not hardcoded. The script loads a **model cascade** from
  `/etc/models.json` (generated from `/etc/nixos/models.nix` by
  `modules/services/model-config.nix`) and walks it with exponential backoff,
  falling through to the next model when one fails. `--model` overrides the cascade.
  If `/etc/models.json` is missing the script exits 1 and tells you to rebuild.
- **Per-request timeout**: 7200 seconds / 2 hours (`self.timeout`) — deliberately
  large because the primary model is a local LLM
- **Max Tokens**: 1500

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

- **Typical runtime**: dominated by the AI call, not log collection. Log gathering
  is seconds; a local-LLM analysis can take minutes.
- **Timeouts**: 30 s per `journalctl` invocation (per service), and up to 7200 s
  (2 h) for a single AI request, retried across the model cascade. The old
  "60 seconds total" figure predates the cascade and is no longer true.
- **Memory usage**: ~50-100MB (depending on log volume)
- **Log collection**: Processes 50,000-100,000 entries typical

## Troubleshooting

### "API connection error: HTTP Error 401: Unauthorized"

- Set `LITELLM_API_KEY` environment variable
- Verify LiteLLM is running. It is a **rootless** container owned by the `litellm`
  user, so `systemctl status litellm` (system scope) finds nothing; use
  `sudo -u litellm env XDG_RUNTIME_DIR=/run/user/$(id -u litellm) systemctl --user status litellm.service`
  or simply check that the port answers: `curl -s -o /dev/null -w '%{http_code}\n'
  http://127.0.0.1:4000/health` (a `401` still proves LiteLLM is up — the endpoint
  requires a key)
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
- Custom AI prompts per service type
- Multi-day comparison analysis

Already implemented since this list was written (as of 2026-07-27):
- ~~Email delivery integration~~ — delivered via the logwatch `ai-log-summary`
  custom service, which mails `johnw@vulcan.lan`
- ~~Persistent summary storage and trend analysis~~ — `/var/log/logwatch-ai`
  history plus the `known-conditions.prompt` wisdom file (14-day retention)
