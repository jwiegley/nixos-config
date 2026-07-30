# vdirsyncer Grafana Dashboard Guide

## Overview
This guide helps you create a Grafana dashboard for monitoring vdirsyncer synchronization metrics.

## Available Metrics
`vdirsyncer-status.service` (`scripts/vdirsyncer-status.py`, serving
`http://127.0.0.1:8089/metrics`, Prometheus job `vdirsyncer`) exposes exactly
four metrics. The first three are emitted **once per sync pair**, carrying a
`pair="<name>"` label — a bare Stat panel on them returns one series per pair,
so wrap them in `min()` / `sum()` or add a `pair` repeat if you want a single
tile:

- `vdirsyncer_last_sync_timestamp{pair}` - Unix timestamp of last successful sync
- `vdirsyncer_sync_healthy{pair}` - Sync health status (0=unhealthy, 1=healthy)
- `vdirsyncer_collections_total{pair}` - Number of collections being synced
- `vdirsyncer_sync_pairs_total` - Total number of sync pairs configured (unlabelled)

> **`vdirsyncer_last_sync_duration_seconds` DOES NOT EXIST** (verified
> 2026-07-27 against both the live `/metrics` output and
> `scripts/vdirsyncer-status.py:140-170`, which emits only the four metrics
> above). Panels 4 and 6 below, the "Average sync duration" query, and the
> `VdirsyncerSlowSync` alert in `modules/services/vdirsyncer-alerts.nix:61` all
> reference it and will never return data. Either add the metric to the
> exporter or drop those panels.

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

### Panel 4: Last Sync Duration — NOT AVAILABLE
> The metric this panel needs is not exported (see *Available Metrics*).
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

### Panel 6: Sync Duration Trend — NOT AVAILABLE
> The metric this panel needs is not exported (see *Available Metrics*).
- **Type:** Time series
- **Query:** `vdirsyncer_last_sync_duration_seconds`
- **Title:** Sync Duration Over Time
- **Unit:** seconds

## Alert Rules

All vdirsyncer alerts live in ONE place: `modules/monitoring/alerts/application-services.yaml`.

They were consolidated there on 2026-07-29. Previously they were split across that file and
`modules/services/vdirsyncer-alerts.nix`, which has been deleted — it defined the same
conditions again at different severities, so a single failure notified twice and reached both
the iPhone and the email path.

1. **VdirsyncerSyncStale** (warning) — no successful sync in over 1 hour, per sync pair.
2. **VdirsyncerSyncUnhealthy** (warning) — health check failing for over 10 minutes, per pair.
3. **VdirsyncerNoCollections** (critical) — nothing configured to sync at all. Critical, unlike
   the two above, because it does not self-heal and usually means discovery or authentication
   broke rather than a sync merely falling behind.
4. **VdirsyncerStatusServiceDown** (warning) — the metrics endpoint on localhost:8089 is not
   responding. Uses `up{job="vdirsyncer"}` rather than the unit state, so it also catches a
   process that is active but hung.

Removed in the same consolidation, so do not go looking for them: `VdirsyncerNotSyncing` (a
same-severity 30-minute duplicate of `VdirsyncerSyncStale`), `VdirsyncerNotSyncingCritical`
(identical expression and dwell to `VdirsyncerSyncStale`), `VdirsyncerStatusDashboardDown`
(weaker unit-state form of `VdirsyncerStatusServiceDown`), and `VdirsyncerSlowSync` (deleted
earlier — it selected `vdirsyncer_last_sync_duration_seconds`, which the exporter never emits).


## Useful PromQL Queries

```promql
# Time since last successful sync (in minutes)
(time() - vdirsyncer_last_sync_timestamp) / 60

# Sync rate (syncs per hour) -- SUSPECT: this rate()s a Unix-timestamp gauge,
# so a continuously-advancing clock yields ~3600, not a count of syncs. Left
# here as-written pending a replacement; do not trust the number.
rate(vdirsyncer_last_sync_timestamp[1h]) * 3600

# Is sync currently healthy? (one series per pair; min() collapses to a
# single "all pairs healthy" tile)
vdirsyncer_sync_healthy
min(vdirsyncer_sync_healthy)

# Average sync duration (last hour) -- DEAD: metric not exported, see above
avg_over_time(vdirsyncer_last_sync_duration_seconds[1h])

# Number of collections (per pair; sum() for the fleet total)
vdirsyncer_collections_total
sum(vdirsyncer_collections_total)
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

3. **Check vdirsyncer-status service** (the metrics server; the sync itself is
   the separate `vdirsyncer.service` + `vdirsyncer.timer` pair):
   ```bash
   sudo systemctl status vdirsyncer-status.service
   sudo journalctl -u vdirsyncer-status.service -f
   systemctl list-timers vdirsyncer.timer
   ```

4. **Check Grafana data source:**
   - Go to Configuration → Data Sources
   - Verify Prometheus is connected
   - Test the connection

## Advanced: Exporting/Importing Dashboard

Once you've created your dashboard:

1. Click the share icon → "Export" → "Save to file"
2. Save to `/etc/nixos/modules/monitoring/dashboards/vdirsyncer.json`
3. **Dropping a JSON file in this directory is NOT enough** — dashboards are
   hand-listed in the `localDashboards` attrset in
   `modules/services/grafana.nix` (~lines 49–59), which builds the provisioning
   derivation. Add
   `"vdirsyncer.json" = ../monitoring/dashboards/vdirsyncer.json;`
   to that attrset, then `sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'`.
   Note there are two dashboard directories (`dashboards/` and
   `grafana-dashboards/`) and both are enumerated by hand from that one list.

## Related Documentation

- Metrics documentation: `/etc/vdirsyncer/metrics-monitoring.md`
- Service status dashboard: https://vdirsyncer.vulcan.lan
- Prometheus: https://prometheus.vulcan.lan
- Alertmanager: https://alertmanager.vulcan.lan
