# Mac Studio Power Monitoring on Asahi Linux

> **Status (2026-07-27):** still accurate in substance — the sensors, the
> node-exporter metrics and the `mac-studio-power` Grafana dashboard are all
> live. Three corrections were folded in on that date: the SMC hwmon device is
> **`hwmon0`** on the current boot (not `hwmon1`, which is the NVMe controller)
> and its index is assigned at boot, so the shell examples now discover it;
> `temp1` is the **NAND Flash Temperature**, not a generic "system"
> temperature; and the module paths for node-exporter / Prometheus were wrong.
> The numeric power readings below are the original 2025-10-26 measurements.

## Overview

This document describes the comprehensive power monitoring solution for the Mac Studio running Asahi Linux. The system leverages native Apple Silicon hardware sensors exposed through the Linux hwmon subsystem to provide real-time power consumption, current draw, and temperature monitoring.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Apple Silicon Hardware (Mac Studio)            │
│  - System Management Controller (SMC)           │
│  - Power sensors (system, AC, 3.8V rail)        │
│  - Current sensors                              │
│  - Temperature sensors (NVMe, PCIe, SMC)        │
└───────────────────┬─────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  macsmc_hwmon Kernel Driver (Asahi Linux)       │
│  /sys/class/hwmon/hwmon0/  (index varies)       │
│  - power1_input: Total System Power             │
│  - power2_input: AC Input Power                 │
│  - power3_input: 3.8V Rail Power                │
│  - curr1_input: AC Input Current                │
│  - temp1_input: NAND Flash Temperature          │
│  - fan1/fan2_input: Fan 1 / Fan 2 RPM           │
└───────────────────┬─────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  Node Exporter (:9100)                          │
│  Exposes hwmon metrics as Prometheus metrics:   │
│  - node_hwmon_power_watt{sensor="power1"}       │
│  - node_hwmon_power_watt{sensor="power2"}       │
│  - node_hwmon_power_watt{sensor="power3"}       │
│  - node_hwmon_curr_amps{sensor="curr1"}         │
│  - node_hwmon_temp_celsius                      │
└───────────────────┬─────────────────────────────┘
                    │
                    ▼ (scrape every 15s)
┌─────────────────────────────────────────────────┐
│  Prometheus (:9090)                             │
│  Stores time-series metrics data                │
└───────────────────┬─────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  Grafana (:3000 / grafana.vulcan.lan)          │
│  Dashboard: "Mac Studio Power Monitoring"       │
│  - Real-time power consumption gauges           │
│  - Historical power trends                      │
│  - Energy consumption calculations              │
│  - Temperature monitoring                       │
└─────────────────────────────────────────────────┘
```

## Available Metrics

### Power Metrics

| Metric | Sensor | Description | Typical Range |
|--------|--------|-------------|---------------|
| `node_hwmon_power_watt{sensor="power1"}` | Total System Power | Complete system power draw | 15-60W |
| `node_hwmon_power_watt{sensor="power2"}` | AC Input Power | AC power input from wall | 15-55W |
| `node_hwmon_power_watt{sensor="power3"}` | 3.8V Rail Power | Power consumption on 3.8V rail | 8-25W |

**Readings at idle, measured 2025-10-26**:
- Total System Power: ~16.8W
- AC Input Power: ~15.8W
- 3.8V Rail Power: ~9.7W

### Current Metrics

| Metric | Sensor | Description | Typical Range |
|--------|--------|-------------|---------------|
| `node_hwmon_curr_amps{sensor="curr1"}` | AC Input Current (`ID0R`) | Current drawn from the wall supply | 1.0-3.0A |

**Reading (2025-10-26)**: ~1.3A

### Fan Metrics

The same chip also exposes both Mac Studio fans (no separate configuration
needed): `node_hwmon_fan_rpm`, `node_hwmon_fan_target_rpm`,
`node_hwmon_fan_min_rpm` (1100) and `node_hwmon_fan_max_rpm` (3500) for
`sensor="fan1"` and `sensor="fan2"`.

### Temperature Metrics

| Metric | Description | Typical Range |
|--------|-------------|---------------|
| `node_hwmon_temp_celsius{chip="290400000_smc_macsmc_hwmon"}` | NAND Flash Temperature (`TH0x`, the only SMC temperature in the device tree) | 25-45°C |
| `node_hwmon_temp_celsius{chip="nvme_nvme0"}` | NVMe SSD "Composite" temperature | 25-65°C |
| `node_hwmon_temp_celsius{chip="0000:00:02_0_0000:03:00_0"}` | 10GbE NIC — `temp1` = PHY, `temp2` = MAC | 45-80°C |

**Readings (2025-10-26)**:
- SMC (NAND flash) sensor: ~27.8°C
- NVMe SSD: ~26.9°C
- NIC: ~56°C

## Grafana Dashboard

### Dashboard Access

- **URL**: `https://grafana.vulcan.lan`
- **Dashboard Name**: Mac Studio Power Monitoring
- **UID**: `mac-studio-power`
- **File**: `/etc/nixos/modules/monitoring/dashboards/mac-studio-power.json`

### Dashboard Panels

(Panels 1, 2, 3, 5, 6 and 7 are Grafana `stat` panels with thresholds, not
`gauge` panels; 4 and 8 are time series.)

1. **Total System Power** (Stat)
   - Query: `node_hwmon_power_watt{sensor="power1"}`
   - Thresholds: Green (<20W), Yellow (20-40W), Orange (40-60W), Red (>60W)
   - Unit: Watts

2. **AC Input Power** (Stat)
   - Query: `node_hwmon_power_watt{sensor="power2"}`
   - Thresholds: Green (<20W), Yellow (20-40W), Red (>40W)
   - Unit: Watts

3. **3.8V Rail Power** (Stat)
   - Query: `node_hwmon_power_watt{sensor="power3"}`
   - Thresholds: Green (<15W), Yellow (15-25W), Red (>25W)
   - Unit: Watts

4. **Power Consumption Over Time** (Time Series)
   - Displays all three power sensors on one graph
   - Smooth line interpolation
   - Shows mean, last, max, and min values in legend
   - Time range: Last 6 hours (configurable)

5. **Current Draw** (Stat)
   - Query: `node_hwmon_curr_amps{sensor="curr1"}`
   - Thresholds: Green (<2A), Yellow (2-3A), Red (>3A)
   - Unit: Amps

6. **System Temperature** (Stat)
   - Query: `node_hwmon_temp_celsius{chip="290400000_smc_macsmc_hwmon"}`
   - Thresholds: Green (<60°C), Yellow (60-80°C), Red (>80°C)
   - Unit: Celsius
   - The panel title is a misnomer: the only SMC temperature exposed is
     `TH0x`, **NAND Flash Temperature**

7. **Energy Consumed (24h)** (Stat)
   - Query: `sum(increase(node_hwmon_power_watt{sensor="power1"}[24h])) / 3600`
   - Labelled kWh over the last 24 hours, but `increase()` is a counter function
     applied to a gauge — the number it prints is **not** energy (see the
     caution under "Advanced Queries"). Unfixed as of 2026-07-27.
   - Unit: kWh

8. **All Temperature Sensors** (Time Series)
   - Query: `node_hwmon_temp_celsius`
   - Displays all available temperature sensors
   - Shows mean, last, and max values in legend
   - Useful for identifying hot components

### Dashboard Tags

- `power`
- `energy`
- `mac-studio`
- `apple-silicon`
- `asahi-linux`

## Prometheus Queries

### Basic Queries

```promql
# Current total system power
node_hwmon_power_watt{sensor="power1"}

# Current AC input power
node_hwmon_power_watt{sensor="power2"}

# Current 3.8V rail power
node_hwmon_power_watt{sensor="power3"}

# AC input current in amps
node_hwmon_curr_amps{sensor="curr1"}

# SMC temperature (NAND flash)
node_hwmon_temp_celsius{chip="290400000_smc_macsmc_hwmon"}

# Fan speeds
node_hwmon_fan_rpm{chip="290400000_smc_macsmc_hwmon"}
```

### Advanced Queries

```promql
# Average power consumption over last hour
avg_over_time(node_hwmon_power_watt{sensor="power1"}[1h])

# Peak power consumption over last 24 hours
max_over_time(node_hwmon_power_watt{sensor="power1"}[24h])

# Total energy consumed in last 24 hours (kWh)
# CAUTION: this is the expression the dashboard's "Energy Consumed (24h)" panel
# uses, but `increase()` is a counter function and power1 is a GAUGE, so the
# result is not actually energy. The dimensionally correct form is:
#   avg_over_time(node_hwmon_power_watt{sensor="power1"}[24h]) * 24 / 1000
sum(increase(node_hwmon_power_watt{sensor="power1"}[24h])) / 3600

# Rate of power change (watts per second)
rate(node_hwmon_power_watt{sensor="power1"}[5m])

# Temperature correlation with power
node_hwmon_temp_celsius and on() node_hwmon_power_watt{sensor="power1"}
```

## CLI Monitoring

### Finding the SMC hwmon device

The hwmon index is assigned at boot and is **not** stable: on 2026-07-27 the SMC
chip is `hwmon0` and `hwmon1` is the NVMe controller. Discover it instead of
hard-coding an index:

```bash
SMC=$(dirname "$(grep -l macsmc_hwmon /sys/class/hwmon/*/name)")
echo "$SMC"          # e.g. /sys/class/hwmon/hwmon0
```

All examples below assume `$SMC` is set that way.

### Real-time Power Monitoring

```bash
# Watch power consumption in real-time
watch -n 1 "awk '{print \$1/1000000 \" watts\"}' $SMC/power1_input"

# All power sensors
watch -n 1 "
  echo \"Total System: \$(awk '{print \$1/1000000}' $SMC/power1_input) W\"
  echo \"AC Input:     \$(awk '{print \$1/1000000}' $SMC/power2_input) W\"
  echo \"3.8V Rail:    \$(awk '{print \$1/1000000}' $SMC/power3_input) W\"
  echo \"AC Current:   \$(awk '{print \$1/1000}' $SMC/curr1_input) A\"   # mA, not µA
"
```

### Sensor Information

```bash
# List all hwmon devices with their names
for d in /sys/class/hwmon/hwmon*; do echo "$d: $(cat $d/name)"; done

# Show sensor labels (power1/2/3, curr1, temp1, fan1, fan2)
for f in "$SMC"/*_label; do echo "$(basename "$f"): $(cat "$f")"; done

# Read raw sensor values (power in microwatts, current in MILLIamps)
cat "$SMC/power1_input"
cat "$SMC/curr1_input"
```

### Prometheus API Queries

```bash
# Query current power metrics
curl -s 'http://localhost:9090/api/v1/query?query=node_hwmon_power_watt' | jq -r '.data.result[] | "\(.metric.sensor): \(.value[1]) watts"'

# Query current draw
curl -s 'http://localhost:9090/api/v1/query?query=node_hwmon_curr_amps' | jq -r '.data.result[] | "\(.metric.sensor): \(.value[1]) amps"'

# Query temperature sensors
curl -s 'http://localhost:9090/api/v1/query?query=node_hwmon_temp_celsius' | jq -r '.data.result[] | "\(.metric.chip) - \(.metric.sensor): \(.value[1])°C"'

# Query 24-hour energy consumption
curl -s 'http://localhost:9090/api/v1/query?query=sum(increase(node_hwmon_power_watt{sensor="power1"}[24h]))/3600' | jq -r '.data.result[0].value[1] + " kWh"'
```

## Service Configuration

### Node Exporter

- **Service**: `prometheus-node-exporter.service`
- **Port**: 9100
- **Config**: `/etc/nixos/modules/monitoring/services/system-exporters.nix`
  (there is no `node-exporter.nix`; that file also defines the `node` scrape job)

```bash
# Check node exporter status
sudo systemctl status prometheus-node-exporter

# View logs
sudo journalctl -u prometheus-node-exporter -f

# Test metrics endpoint
curl http://localhost:9100/metrics | grep node_hwmon
```

### Prometheus

- **Service**: `prometheus.service`
- **Port**: 9090
- **Config**: `/etc/nixos/modules/monitoring/services/prometheus-server.nix`
  (there is no `prometheus.nix`)
- **Scrape Interval**: 15 seconds (`globalConfig.scrape_interval`)
- **Listen address**: 127.0.0.1 only; the external URL is
  `https://prometheus.vulcan.lan` via nginx

```bash
# Check Prometheus status
sudo systemctl status prometheus

# View scrape targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="node")'

# Check Prometheus logs
sudo journalctl -u prometheus -f
```

### Grafana

- **Service**: `grafana.service`
- **Port**: 3000 (localhost), 443 (HTTPS via nginx)
- **Config**: `/etc/nixos/modules/services/grafana.nix`
- **Dashboard Dir**: `/var/lib/grafana/dashboards/`

```bash
# Check Grafana status
sudo systemctl status grafana

# View logs
sudo journalctl -u grafana -f

# Test health endpoint
curl http://localhost:3000/api/health

# List deployed dashboards
sudo ls -la /var/lib/grafana/dashboards/mac-studio-power.json
```

## Power Consumption Analysis

### Idle Power Consumption

Based on current measurements at system idle:

- **Total System Power**: ~16.8W
- **AC Input Power**: ~15.8W (efficiency ~94%)
- **3.8V Rail**: ~9.7W (~58% of total power)
- **Current Draw**: ~1.3A

### Expected Power Ranges

| Workload | Total System Power | Notes |
|----------|-------------------|-------|
| Idle (this measurement) | 15-18W | Base system idle |
| Light browsing | 20-30W | Single Chrome/Firefox tab |
| Video playback | 25-35W | 1080p/4K video |
| Development work | 30-45W | Code editing, compilation |
| Heavy compilation | 40-60W | Multi-threaded builds |
| ML/AI workloads | 50-80W | GPU-intensive tasks |
| Sustained load | 60-100W | All cores + GPU maxed |

### Energy Cost Estimation

Assuming residential electricity at $0.15/kWh:

| Usage Pattern | Daily Power | Monthly Cost | Annual Cost |
|---------------|-------------|--------------|-------------|
| Always idle (16.8W) | 0.40 kWh | $1.82 | $21.89 |
| 8h idle + 16h off | 0.13 kWh | $0.61 | $7.30 |
| 8h work (35W) + 16h idle | 0.55 kWh | $2.48 | $29.78 |
| 24/7 server (25W) | 0.60 kWh | $2.74 | $32.85 |

## Technical Details

### macsmc_hwmon Driver

The `macsmc_hwmon` driver is part of the Asahi Linux kernel and provides access to Apple's System Management Controller (SMC) sensors through the standard Linux hwmon interface.

**Kernel Module**: `macsmc_hwmon.ko`

**sysfs Path**: `/sys/class/hwmon/hwmon<N>/` — `hwmon0` on the 2026-07-27 boot,
but the index is not stable (see "Finding the SMC hwmon device"). The `name`
file reads **`macsmc_hwmon`**; the *device* path is
`/sys/devices/platform/soc/290400000.smc/macsmc-hwmon/hwmon/hwmon<N>`, which is
what node-exporter turns into the `chip="290400000_smc_macsmc_hwmon"` label.

**Available Sensors** (labels straight from the device tree):
- `power1`: Total System Power (`PSTR`)
- `power2`: AC Input Power (`PDTR`, wall power)
- `power3`: 3.8 V Rail Power (`PMVR`)
- `curr1`: AC Input Current (`ID0R`)
- `temp1`: NAND Flash Temperature (`TH0x`)
- `fan1`, `fan2`: Fan 1 / Fan 2 (`F0Ac` / `F1Ac`, with min/max/target attributes)

**Units** (standard Linux hwmon scaling):
- Power: microwatts (divide by 1,000,000 for watts)
- Current: **milliamps** (divide by 1,000 for amps)
- Temperature: millidegrees Celsius (divide by 1,000 for °C)
- Fan speed: RPM (no scaling)

### Why Zeus Doesn't Work

**Zeus ML** is a popular power monitoring library for ML workloads, but it does NOT work on Asahi Linux because:

1. **macOS Dependency**: Zeus relies on Apple's proprietary IOKit framework and powermetrics tool
2. **No Linux Support**: Apple Silicon power telemetry is only available through macOS kernel drivers
3. **Asahi Limitations**: While Asahi Linux provides basic hwmon sensors, it doesn't expose the detailed per-component power data that Zeus requires

**Alternatives Considered**:
- ✗ Zeus ML: Requires macOS
- ✗ Intel RAPL: Intel-specific, not available on ARM
- ✗ powertop: Limited ARM support, no Apple Silicon specifics
- ✓ **macsmc_hwmon + node_exporter**: Native Asahi Linux solution (CHOSEN)

## Alerting (Future Enhancement)

Still unimplemented as of 2026-07-27 — there is no `mac_studio_power` group in
`modules/monitoring/alerts/`. Sketch of the rules that could be added (note that
`temp1` on this chip is NAND flash temperature, so the temperature threshold
below is not a CPU/SoC guard):

```yaml
groups:
  - name: mac_studio_power
    interval: 30s
    rules:
      # Alert on sustained high power consumption
      - alert: MacStudioHighPower
        expr: node_hwmon_power_watt{sensor="power1"} > 60
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Mac Studio high power consumption"
          description: "System power draw is {{ $value }}W (threshold: 60W)"

      # Alert on abnormally low power (system may be sleeping)
      - alert: MacStudioLowPower
        expr: node_hwmon_power_watt{sensor="power1"} < 10
        for: 2m
        labels:
          severity: info
        annotations:
          summary: "Mac Studio very low power consumption"
          description: "System power draw is {{ $value }}W (may be sleeping)"

      # Alert on high temperature
      - alert: MacStudioHighTemperature
        expr: node_hwmon_temp_celsius{chip="290400000_smc_macsmc_hwmon"} > 70
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "Mac Studio high temperature"
          description: "System temperature is {{ $value }}°C (threshold: 70°C)"
```

## Maintenance

### Dashboard Updates

```bash
# Edit dashboard JSON
vim /etc/nixos/modules/monitoring/dashboards/mac-studio-power.json

# Rebuild to deploy changes
sudo nixos-rebuild switch --flake '.#vulcan'

# Verify deployment
sudo ls -la /var/lib/grafana/dashboards/mac-studio-power.json
```

### Adding New Metrics

1. Verify sensor is exposed by hwmon:
   ```bash
   SMC=$(dirname "$(grep -l macsmc_hwmon /sys/class/hwmon/*/name)")
   ls "$SMC"
   cat "$SMC/<sensor>_label"
   ```

2. Confirm node_exporter exposes it:
   ```bash
   curl http://localhost:9100/metrics | grep <sensor>
   ```

3. Add to Grafana dashboard JSON

4. Rebuild configuration

## Troubleshooting

### No Power Metrics Available

```bash
# Locate the SMC hwmon device (its index changes between boots)
SMC=$(dirname "$(grep -l macsmc_hwmon /sys/class/hwmon/*/name)")
ls "$SMC"

# Verify it's the SMC device
cat "$SMC/name"   # shows: macsmc_hwmon

# Check if sensors are readable
cat "$SMC/power1_input"

# Is the driver loaded at all?
lsmod | grep macsmc_hwmon
```

### Metrics Not Appearing in Prometheus

```bash
# Check node_exporter is running
sudo systemctl status prometheus-node-exporter

# Verify metrics endpoint
curl http://localhost:9100/metrics | grep node_hwmon_power

# Check Prometheus scrape targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="node")'

# Check Prometheus logs for scrape errors
sudo journalctl -u prometheus -f
```

### Dashboard Not Loading in Grafana

```bash
# Verify dashboard file exists
sudo ls -la /var/lib/grafana/dashboards/mac-studio-power.json

# Check Grafana logs
sudo journalctl -u grafana -f

# Restart Grafana to force reload
sudo systemctl restart grafana

# Check Grafana health
curl http://localhost:3000/api/health
```

### Incorrect Power Readings

```bash
# Compare raw sensor value with Prometheus
SMC=$(dirname "$(grep -l macsmc_hwmon /sys/class/hwmon/*/name)")
RAW=$(cat "$SMC/power1_input")
WATTS=$(echo "scale=2; $RAW / 1000000" | bc)
echo "Raw: $RAW microwatts = $WATTS watts"

# Query Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=node_hwmon_power_watt{sensor="power1"}' | jq -r '.data.result[0].value[1]'
```

## References

- **Asahi Linux Wiki**: https://github.com/AsahiLinux/docs/wiki
- **macsmc Driver**: https://github.com/AsahiLinux/linux/tree/asahi/drivers/platform/apple
- **Linux hwmon**: https://www.kernel.org/doc/html/latest/hwmon/
- **Prometheus Node Exporter**: https://github.com/prometheus/node_exporter
- **Grafana Documentation**: https://grafana.com/docs/grafana/latest/

## Summary

This Mac Studio power monitoring solution provides comprehensive, real-time visibility into system power consumption without requiring any external tools or proprietary software. By leveraging Asahi Linux's native `macsmc_hwmon` driver and the existing Prometheus + Grafana monitoring stack, we achieve:

✅ **Real-time power monitoring** (15-second granularity)
✅ **Historical trending and analysis** (effectively unlimited — Prometheus
`retentionTime` is set to `100y` in `modules/options/default.nix`)
✅ **Visual dashboards** with Grafana
✅ **Energy consumption calculations** (daily/weekly/monthly)
✅ **Temperature correlation** with power draw
✅ **No external dependencies** (all components native to Asahi Linux)
✅ **Production-ready** infrastructure with TLS encryption

**Key Advantages over Zeus**:
- Works natively on Asahi Linux (Zeus requires macOS)
- Integrated with existing monitoring infrastructure
- No additional software installation required
- Historical data retention and trending
- Customizable alerts and dashboards

## CPU/GPU/ANE Separate Power Monitoring

### Question: Can we measure CPU, GPU, and ANE power separately like macmon does on macOS?

**Short Answer:** ❌ **No — still not available on Asahi Linux as of 2026-07-27**
(kernel 6.17.12; the device tree exposes only the three power keys below).

While tools like **macmon** and **powermetrics** on macOS can show separate power measurements for CPU, GPU, and ANE (Apple Neural Engine), this capability is **not yet available** on Asahi Linux for Mac Studio.

### How macOS Achieves Separate Component Power

On macOS, separate component power monitoring works through:

1. **IOReport Framework** (private, undocumented API)
   - Provides per-component power domain telemetry
   - Accesses internal SoC power sensors
   - Reports separate values for CPU cores, GPU, ANE

2. **SMC FourCC Keys** (undocumented)
   - `pACC` - Likely CPU power (ACC = Application Processor Cluster)
   - `pAGX` - Likely GPU power (AGX = Apple Graphics)
   - Unknown keys for ANE and other components

3. **Tools that use these APIs:**
   - **powermetrics**: Apple's built-in tool (`sudo powermetrics --samplers cpu_power,gpu_power`)
   - **macmon**: Community tool (https://github.com/vladkens/macmon)
   - **asitop**: Python-based monitor (https://github.com/tlkh/asitop)

### Current Asahi Linux Limitations

**Device Tree Configuration:**

Sensor nodes live directly under
`/sys/firmware/devicetree/base/soc/smc@290400000/hwmon/` (there is no
`apple,power-keys/` sub-node). Verified 2026-07-27:

```
power-PSTR        → Total System Power     (power1)
power-PDTR        → AC Input Power         (power2)
power-PMVR        → 3.8 V Rail Power       (power3)
current-ID0R      → AC Input Current       (curr1)
temperature-TH0x  → NAND Flash Temperature (temp1)
fan-F0Ac/fan-F1Ac → Fan 1 / Fan 2          (fan1/fan2)
```

**What's Missing:**
- ❌ No CPU-specific power sensor
- ❌ No GPU-specific power sensor
- ❌ No ANE-specific power sensor
- ❌ No per-core power breakdown
- ❌ No per-cluster power (E-cores vs P-cores)

### Why This Limitation Exists

1. **Undocumented SMC Keys**
   - Apple does not publicly document the FourCC keys for per-component power
   - Keys must be discovered through reverse engineering
   - Keys may vary between different Mac models

2. **Device Tree Configuration**
   - Asahi Linux uses device tree to specify which SMC sensors to expose
   - Only three *power* sensors are configured for Mac Studio (plus one
     current, one temperature and two fan nodes)
   - Adding new sensors requires knowing the correct SMC keys

3. **Driver Already Supports It**
   - The `macsmc_hwmon` driver framework CAN read arbitrary SMC keys
   - Adding CPU/GPU sensors would only require updating the device tree
   - No driver code changes needed if we knew the keys

### Investigation Results

**SMC Keys Analysis:**

Known SMC key format from Asahi Linux documentation:
- `P???` - Generic power meters (watts)
- `PSTR` - Total system power (watts) ✅ **Currently exposed**
- `PDTR` - AC input power (watts) ✅ **Currently exposed**
- `PMVR` - 3.8V rail power (watts) ✅ **Currently exposed**
- `a???` - Volatile power measurements (possibly current to subsystems)

Suspected (but unconfirmed) keys:
- `pACC` - Possible CPU power (based on macOS naming patterns)
- `pAGX` - Possible GPU power (AGX = Apple Graphics Architecture)
- Unknown - ANE power key

**Hardware Capability:**
- ✅ Hardware DOES support separate measurements (proven by macOS)
- ✅ SMC likely exposes these sensors
- ❌ SMC keys are not publicly documented
- ❌ Keys not included in Asahi Linux device tree (yet)

### Workarounds and Alternatives

While waiting for per-component power sensors:

**1. Use Temperature as Proxy**
```bash
# Monitor CPU/GPU temperature trends
curl -s 'http://localhost:9090/api/v1/query?query=node_hwmon_temp_celsius' | jq
```
Higher temperature generally correlates with higher power consumption for that component.

**2. Monitor Frequency**
CPU and GPU frequency scaling can indicate which component is active:
- High CPU frequency → CPU-intensive workload
- High GPU frequency → GPU-intensive workload

**3. Dual-Boot for Detailed Analysis**
```bash
# On macOS:
sudo powermetrics --samplers cpu_power,gpu_power -i 1000

# Or use macmon:
brew install macmon
macmon
```

**4. Use Total System Power**
The `power1` sensor (PSTR) accurately reports total system power:
- Idle baseline: ~16W
- CPU spike: +10-30W increase = CPU power
- GPU spike: +15-40W increase = GPU power
- Both: +30-60W increase = combined load

### Future Possibilities

**Option 1: Wait for Asahi Linux Updates**

The Asahi Linux community is actively developing SMC support:
- SMC hwmon driver merged in Linux 6.17
- More sensors being added in each release
- Per-component power may be added if keys are discovered

**Option 2: Community Reverse Engineering**

Someone with expertise could:
1. Boot macOS and use `ioreg` to dump SMC keys
2. Cross-reference with `powermetrics` output
3. Test candidate keys on Asahi Linux
4. Add validated keys to device tree
5. Submit patches to Asahi Linux kernel

Required skills:
- SMC protocol knowledge
- IOKit/IOReport reverse engineering
- Device tree editing
- Kernel driver development

**Option 3: Request Feature from Asahi Developers**

File feature request with Asahi Linux project:
- Link to macmon showing it's possible
- Explain use case for per-component monitoring
- Offer to test patches if developed

### Technical Details

**Device Tree Format for Power Sensors:**

```
/sys/firmware/devicetree/base/soc/smc@290400000/hwmon/
├── power-PSTR/
│   ├── apple,key-id: "PSTR"
│   ├── label: "Total System Power"
│   └── name: "power-PSTR"
├── power-PDTR/
│   ├── apple,key-id: "PDTR"
│   ├── label: "AC Input Power"
│   └── name: "power-PDTR"
├── power-PMVR/
│   ├── apple,key-id: "PMVR"
│   ├── label: "3.8 V Rail Power"
│   └── name: "power-PMVR"
├── current-ID0R/        (label "AC Input Current")
├── temperature-TH0x/    (label "NAND Flash Temperature")
├── fan-F0Ac/            (label "Fan 1"; also apple,fan-{minimum,maximum,target,mode})
└── fan-F1Ac/            (label "Fan 2")
```

**To add CPU power sensor (if key was known):**
```
power-pACC/   # Example - actual key unknown
├── apple,key-id: "pACC"
├── label: "CPU Power"
└── name: "power-pACC"
```

This would automatically create:
- `$SMC/power4_input`
- `$SMC/power4_label` → "CPU Power"
- Prometheus metric: `node_hwmon_power_watt{sensor="power4"}`

### Recommendation

**For now:**
1. ✅ Use total system power (PSTR) for overall monitoring
2. ✅ Use temperature sensors as component activity indicator
3. ✅ Monitor power deltas during specific workloads:
   - Run CPU benchmark → measure power increase = CPU power
   - Run GPU benchmark → measure power increase = GPU power
4. ⏳ Wait for Asahi Linux community to add per-component sensors

**If you need detailed component power now:**
- Dual-boot to macOS
- Use `powermetrics` or `macmon`
- Record data for analysis

**Long-term:**
The hardware capability exists, and the driver framework supports it. Once the SMC keys are discovered and added to the device tree, per-component power monitoring will "just work" on Asahi Linux without any additional infrastructure changes.

### References

- **macmon source**: https://github.com/vladkens/macmon
- **macmon blog**: https://medium.com/@vladkens/how-to-get-macos-power-metrics-with-rust-d42b0ad53967
- **Asahi Linux SMC docs**: https://asahilinux.org/docs/hw/soc/smc/
- **IOReport reverse engineering**: Community knowledge (not officially documented)
- **macsmc_hwmon driver**: Linux kernel patch v4 (October 2025)
