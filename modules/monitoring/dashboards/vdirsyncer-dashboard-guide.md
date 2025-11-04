# vdirsyncer Grafana Dashboard Guide

## Overview
This guide helps you create a Grafana dashboard for monitoring vdirsyncer synchronization metrics.

## Available Metrics
vdirsyncer exposes the following Prometheus metrics:

- `vdirsyncer_last_sync_timestamp` - Unix timestamp of last successful sync
- `vdirsyncer_sync_healthy` - Sync health status (0=unhealthy, 1=healthy)
- `vdirsyncer_collections_total` - Total number of collections being synced
- `vdirsyncer_sync_pairs_total` - Total number of sync pairs configured
- `vdirsyncer_last_sync_duration_seconds` - Duration of last sync in seconds

## Quick Setup

1. Open Grafana: https://grafana.vulcan.lan
2. Click "+" → "Dashboard" → "Add visualization"
3. Select "Prometheus" as data source
4. Add the panels below

## Recommended Panels

### Panel 1: Sync Status
- **Type:** Stat
- **Query:** `vdirsyncer_sync_healthy`
- **Title:** Sync Status
- **Value mappings:**
  - 0 → "Unhealthy" (red)
  - 1 → "Healthy" (green)

### Panel 2: Time Since Last Sync
- **Type:** Stat
- **Query:** `(time() - vdirsyncer_last_sync_timestamp) / 60`
- **Title:** Minutes Since Last Sync
- **Unit:** minutes
- **Thresholds:**
  - Green: < 15
  - Yellow: 15-30
  - Red: > 30

### Panel 3: Collections Synced
- **Type:** Stat
- **Query:** `vdirsyncer_collections_total`
- **Title:** Collections
- **Description:** Number of collections being synchronized

### Panel 4: Last Sync Duration
- **Type:** Stat
- **Query:** `vdirsyncer_last_sync_duration_seconds`
- **Title:** Last Sync Duration
- **Unit:** seconds
- **Thresholds:**
  - Green: < 30
  - Yellow: 30-60
  - Red: > 60

### Panel 5: Sync Health Over Time
- **Type:** Time series
- **Query:** `vdirsyncer_sync_healthy`
- **Title:** Sync Health History
- **Y-axis:** 0-1

### Panel 6: Sync Duration Trend
- **Type:** Time series
- **Query:** `vdirsyncer_last_sync_duration_seconds`
- **Title:** Sync Duration Over Time
- **Unit:** seconds

## Alert Rules

The following Prometheus alerts are already configured:

1. **VdirsyncerNotSyncing** - Triggers after 30 minutes without sync (warning)
2. **VdirsyncerNotSyncingCritical** - Triggers after 1 hour without sync (critical)
3. **VdirsyncerSyncUnhealthy** - Triggers when health check fails (warning)
4. **VdirsyncerNoCollections** - Triggers when no collections are configured (critical)
5. **VdirsyncerSlowSync** - Triggers when sync takes over 5 minutes (warning)
6. **VdirsyncerStatusServiceDown** - Triggers when metrics endpoint is down (warning)

## Useful PromQL Queries

```promql
# Time since last successful sync (in minutes)
(time() - vdirsyncer_last_sync_timestamp) / 60

# Sync rate (syncs per hour)
rate(vdirsyncer_last_sync_timestamp[1h]) * 3600

# Is sync currently healthy?
vdirsyncer_sync_healthy

# Average sync duration (last hour)
avg_over_time(vdirsyncer_last_sync_duration_seconds[1h])

# Number of collections
vdirsyncer_collections_total
```

## Dashboard Layout Recommendation

```
+-------------------+-------------------+-------------------+
|   Sync Status     | Time Since Sync  |   Collections     |
|   (green/red)     |   (15 min)       |   (2)             |
+-------------------+-------------------+-------------------+
| Last Sync Duration|                                       |
|   (5.2s)          |                                       |
+-------------------+---------------------------------------+
|                                                           |
|           Sync Health Over Time (Graph)                   |
|                                                           |
+-----------------------------------------------------------+
|                                                           |
|           Sync Duration Trend (Graph)                     |
|                                                           |
+-----------------------------------------------------------+
```

## Troubleshooting

If metrics are not showing:

1. **Check Prometheus is scraping:**
   ```bash
   curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="vdirsyncer")'
   ```

2. **Check metrics endpoint:**
   ```bash
   curl http://localhost:8089/metrics
   ```

3. **Check vdirsyncer-status service:**
   ```bash
   sudo systemctl status vdirsyncer-status.service
   sudo journalctl -u vdirsyncer-status.service -f
   ```

4. **Check Grafana data source:**
   - Go to Configuration → Data Sources
   - Verify Prometheus is connected
   - Test the connection

## Advanced: Exporting/Importing Dashboard

Once you've created your dashboard:

1. Click the share icon → "Export" → "Save to file"
2. Save to `/etc/nixos/modules/monitoring/dashboards/vdirsyncer.json`
3. The dashboard will be automatically loaded on next Grafana restart

## Related Documentation

- Metrics documentation: `/etc/vdirsyncer/metrics-monitoring.md`
- Service status dashboard: https://vdirsyncer.vulcan.lan
- Prometheus: https://prometheus.vulcan.lan
- Alertmanager: https://alertmanager.vulcan.lan
