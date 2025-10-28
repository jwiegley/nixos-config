#!/usr/bin/env bash
#
# Nagios check plugin for local backup age monitoring
# Checks if backup timestamp files are older than specified threshold
#
# Usage: check_backup_age.sh <backup_name> [threshold_seconds]
#
# Exit codes:
#   0 = OK - Backup is recent
#   1 = WARNING - Not used in this check
#   2 = CRITICAL - Backup is too old or file missing
#   3 = UNKNOWN - Invalid arguments or execution error

set -euo pipefail

# Configuration
BACKUP_NAME="${1:-}"
THRESHOLD_SECONDS="${2:-14400}"  # Default: 4 hours
BACKUP_BASE_DIR="/tank/Backups/vulcan"
TIMESTAMP_FILE="${BACKUP_BASE_DIR}/.${BACKUP_NAME}.latest"

# Nagios exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Usage function
usage() {
  cat <<EOF
Usage: $0 <backup_name> [threshold_seconds]

Arguments:
  backup_name        Name of backup to check (e.g., 'etc', 'home', 'var-lib')
  threshold_seconds  Maximum age in seconds (default: 14400 = 4 hours)

Examples:
  $0 etc            # Check /etc backup with 4 hour threshold
  $0 home 7200      # Check /home backup with 2 hour threshold

Exit codes:
  0 = OK - Backup is recent
  2 = CRITICAL - Backup is too old or file missing
  3 = UNKNOWN - Invalid arguments or error

EOF
  exit "$STATE_UNKNOWN"
}

# Check arguments
if [[ -z "$BACKUP_NAME" ]]; then
  echo "UNKNOWN: Backup name not specified"
  usage
fi

if ! [[ "$THRESHOLD_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "UNKNOWN: Threshold must be a positive integer (got: $THRESHOLD_SECONDS)"
  exit "$STATE_UNKNOWN"
fi

# Check if /tank is mounted
if ! mountpoint -q /tank; then
  echo "CRITICAL: /tank is not mounted - backups cannot be checked"
  exit "$STATE_CRITICAL"
fi

# Check if timestamp file exists
if [[ ! -f "$TIMESTAMP_FILE" ]]; then
  echo "CRITICAL: Backup timestamp file not found: $TIMESTAMP_FILE (backup may have never run)"
  exit "$STATE_CRITICAL"
fi

# Get current time and file modification time
CURRENT_TIME=$(date +%s)
FILE_TIME=$(stat -c %Y "$TIMESTAMP_FILE" 2>/dev/null || echo 0)

if [[ "$FILE_TIME" -eq 0 ]]; then
  echo "UNKNOWN: Unable to read timestamp from $TIMESTAMP_FILE"
  exit "$STATE_UNKNOWN"
fi

# Calculate age
AGE_SECONDS=$((CURRENT_TIME - FILE_TIME))
AGE_MINUTES=$((AGE_SECONDS / 60))
AGE_HOURS=$((AGE_SECONDS / 3600))

# Check against threshold
if [[ $AGE_SECONDS -gt $THRESHOLD_SECONDS ]]; then
  THRESHOLD_HOURS=$((THRESHOLD_SECONDS / 3600))

  if [[ $AGE_HOURS -ge 1 ]]; then
    echo "CRITICAL: Backup '$BACKUP_NAME' is ${AGE_HOURS} hours old (threshold: ${THRESHOLD_HOURS} hours)"
  else
    echo "CRITICAL: Backup '$BACKUP_NAME' is ${AGE_MINUTES} minutes old (threshold: $((THRESHOLD_SECONDS / 60)) minutes)"
  fi

  exit "$STATE_CRITICAL"
fi

# All good
if [[ $AGE_HOURS -ge 1 ]]; then
  echo "OK: Backup '$BACKUP_NAME' is ${AGE_HOURS} hours ${AGE_MINUTES} minutes old (threshold: $((THRESHOLD_SECONDS / 3600)) hours)"
else
  echo "OK: Backup '$BACKUP_NAME' is ${AGE_MINUTES} minutes old (threshold: $((THRESHOLD_SECONDS / 60)) minutes)"
fi

exit "$STATE_OK"
