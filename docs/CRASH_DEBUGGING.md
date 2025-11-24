# Crash Debugging and Reboot Investigation Guide

This document describes the debugging infrastructure configured on vulcan to help diagnose spontaneous reboots and system crashes.

**Configuration Module:** `/etc/nixos/modules/core/crash-debug.nix`
**Date Implemented:** 2024-11-24

---

## Quick Reference: After a Spontaneous Reboot

When the system reboots unexpectedly, check these sources in order:

```bash
# 1. Check journal for the previous boot (most useful)
journalctl -b -1 -p err    # Errors from previous boot
journalctl -b -1 -k        # Kernel messages from previous boot
journalctl -b -1 | tail -200  # Last 200 lines before reboot

# 2. Check kernel log file
cat /var/log/kern.log | tail -100

# 3. Check for OOM killer activity
journalctl -b -1 | grep -i "out of memory\|oom\|killed process"

# 4. Check for kernel panics/oops
journalctl -b -1 | grep -i "panic\|oops\|bug:\|call trace"

# 5. Check system resource trends (sar)
sar -r -f /var/log/sa/sa$(date -d yesterday +%d)  # Memory from yesterday
sar -u -f /var/log/sa/sa$(date -d yesterday +%d)  # CPU from yesterday

# 6. Check atop historical data
atop -r /var/log/atop/atop_$(date -d yesterday +%Y%m%d)

# 7. Check for crash dumps (if kdump triggered)
ls -la /var/crash/
```

---

## Configured Components

### 1. Persistent Journald Logging

Journals are stored persistently in `/var/log/journal/` and survive reboots.

**Configuration:**
- Storage: persistent (in `/var/log/journal/`)
- Max usage: 2GB
- Retention: 30 days
- Compression: enabled
- Forward to syslog: enabled

**Useful Commands:**
```bash
# List available boots
journalctl --list-boots

# View specific boot (use boot ID from above)
journalctl -b -1              # Previous boot
journalctl -b -2              # Two boots ago
journalctl -b <boot-id>       # Specific boot

# Filter by priority
journalctl -b -1 -p crit      # Critical and above
journalctl -b -1 -p err       # Errors and above
journalctl -b -1 -p warning   # Warnings and above

# Kernel messages only
journalctl -b -1 -k

# Time-based queries
journalctl -b -1 --since "2024-11-24 10:00" --until "2024-11-24 11:00"

# Check disk usage
journalctl --disk-usage
```

### 2. Kernel Log Monitoring (rsyslogd)

Traditional syslog files for kernel and system messages.

**Log Files:**
- `/var/log/kern.log` - Kernel messages
- `/var/log/syslog` - All messages
- `/var/log/auth.log` - Authentication/security
- `/var/log/daemon.log` - Daemon messages

**Log Rotation:**
- Weekly rotation
- 7 generations kept
- Compressed after rotation

### 3. Crash Dump (kdump)

Captures kernel memory dump on panic for post-mortem analysis.

**Configuration:**
- Reserved memory: 512MB
- NMI watchdog: enabled (panics on hard lockup)
- Soft lockup panic: enabled

**Verification (after reboot):**
```bash
# Check if crash kernel memory was reserved
dmesg | grep -i crashkernel

# Check if kexec is loaded
cat /sys/kernel/kexec_crash_loaded   # Should be 1

# Crash dumps location (if any)
ls -la /var/crash/
```

**Note:** kdump requires a reboot to activate the crash kernel memory reservation.

### 4. systemd-coredump

Captures core dumps from crashing userspace processes.

**Configuration:** (in `/etc/nixos/modules/core/system.nix`)
- Storage: external (`/var/lib/systemd/coredump/`)
- Compression: zstd
- Max single dump: 500MB
- Total max usage: 3GB

**Useful Commands:**
```bash
# List core dumps
coredumpctl list

# Show info about a specific dump
coredumpctl info <PID or pattern>

# Debug a core dump with gdb
coredumpctl debug <PID>

# Export a core dump
coredumpctl dump <PID> -o /tmp/core.dump
```

### 5. System Activity Reporting (sar/sysstat)

Historical CPU, memory, I/O, and network statistics.

**Configuration:**
- Collection interval: every 5 minutes
- Statistics collected: ALL (`-S ALL`)
- Data location: `/var/log/sa/`

**Useful Commands:**
```bash
# Today's CPU usage
sar -u

# Today's memory usage
sar -r

# Today's I/O activity
sar -b

# Today's load average
sar -q

# Specific day's data
sar -r -f /var/log/sa/sa24    # Day 24 of current month

# All stats for a specific time range
sar -A -s 10:00:00 -e 11:00:00

# Real-time monitoring
sar 1 10    # Every 1 second, 10 iterations
```

### 6. atop Historical Monitoring

Detailed system and per-process resource monitoring.

**Configuration:**
- Interval: 10 seconds
- Process accounting: enabled
- Log location: `/var/log/atop/`
- Retention: 7 days

**Useful Commands:**
```bash
# View today's atop log
atop -r /var/log/atop/atop_$(date +%Y%m%d)

# View specific day
atop -r /var/log/atop/atop_20241124

# Navigation in atop reader:
#   t/T - forward/backward 10 minutes
#   b   - go to specific time
#   m   - memory view
#   d   - disk view
#   n   - network view
#   c   - command line view
#   p   - process view
```

### 7. Kernel Panic Settings

Sysctls configured for crash debugging:

| Setting | Value | Effect |
|---------|-------|--------|
| `kernel.panic` | 60 | Wait 60 seconds before reboot after panic |
| `kernel.panic_on_oops` | 1 | Convert kernel oops to full panic |
| `kernel.panic_on_warn` | 0 | Don't panic on WARN (too aggressive) |
| `kernel.softlockup_panic` | 1 | Panic when CPU is held >20 seconds |
| `kernel.hung_task_panic` | 1 | Panic when task stuck in D state >5 min |
| `kernel.hung_task_timeout_secs` | 300 | 5 minute timeout for hung tasks |
| `kernel.nmi_watchdog` | 1 | NMI watchdog for hard lockup detection |
| `kernel.watchdog_thresh` | 20 | 20 second threshold for lockup detection |
| `vm.panic_on_oom` | 0 | Don't panic on OOM (let OOM killer run) |
| `vm.oom_dump_tasks` | 1 | Dump task info when OOM occurs |
| `kernel.sysrq` | 1 | Enable all SysRq functions |

**Verify settings:**
```bash
sysctl kernel.panic kernel.panic_on_oops kernel.softlockup_panic \
       kernel.hung_task_panic vm.panic_on_oom kernel.nmi_watchdog
```

### 8. Kernel Boot Parameters

Parameters added to kernel command line:

- `loglevel=7` - Verbose kernel logging
- `oops=panic` - Convert oops to panic
- `crashkernel=512M` - Reserve memory for crash kernel (after reboot)
- `nmi_watchdog=panic` - Panic on NMI watchdog timeout
- `softlockup_panic=1` - Panic on soft lockup

**Verify:**
```bash
cat /proc/cmdline
```

---

## Common Crash Scenarios and What to Look For

### OOM (Out of Memory) Kill

```bash
# Check for OOM messages
journalctl -b -1 | grep -i "out of memory"
journalctl -b -1 | grep -i "killed process"

# Check memory trends before crash
sar -r -f /var/log/sa/sa$(date -d yesterday +%d) | tail -20
```

**Signs:** `Out of memory: Killed process` messages, high memory usage in sar

### Kernel Panic

```bash
# Check for panic messages
journalctl -b -1 | grep -i "kernel panic"
journalctl -b -1 | grep -i "call trace" -A 20

# Check if crash dump was saved
ls -la /var/crash/
```

**Signs:** `Kernel panic` message, call trace, crash dump file

### Soft Lockup (CPU stuck)

```bash
# Check for soft lockup messages
journalctl -b -1 | grep -i "soft lockup"
journalctl -b -1 | grep -i "BUG: soft lockup"
```

**Signs:** `BUG: soft lockup - CPU#N stuck` messages

### Hard Lockup (complete freeze)

```bash
# Check for NMI watchdog messages
journalctl -b -1 | grep -i "nmi watchdog"
journalctl -b -1 | grep -i "hard lockup"
```

**Signs:** `NMI watchdog: Watchdog detected hard LOCKUP` messages

### Hung Task (I/O deadlock)

```bash
# Check for hung task messages
journalctl -b -1 | grep -i "hung_task"
journalctl -b -1 | grep -i "blocked for more than"
```

**Signs:** `INFO: task xyz:1234 blocked for more than 300 seconds`

### Hardware Issues

```bash
# Check for MCE (Machine Check Exception)
journalctl -b -1 | grep -i "mce\|machine check"

# Check for hardware errors
journalctl -b -1 | grep -i "hardware error"

# Check dmesg for any errors
dmesg | grep -i error
```

---

## Installed Diagnostic Tools

The following tools are available for debugging:

| Tool | Purpose |
|------|---------|
| `atop` | Advanced system monitor with history |
| `htop` | Interactive process viewer |
| `iotop` | I/O monitoring by process |
| `sar` | System activity reporter |
| `iostat` | I/O statistics |
| `mpstat` | CPU statistics |
| `pidstat` | Per-process statistics |
| `vmstat` | Virtual memory statistics |
| `lsof` | List open files |
| `strace` | System call tracer |
| `lshw` | Hardware lister |
| `lspci` | PCI device lister |
| `lsusb` | USB device lister |
| `numactl` | NUMA policy control |

---

## SysRq Emergency Commands

With `kernel.sysrq=1`, you can use magic SysRq keys for emergency debugging:

```bash
# Trigger manually via /proc
echo <key> > /proc/sysrq-trigger

# Or via keyboard: Alt+SysRq+<key>
```

| Key | Action |
|-----|--------|
| `b` | Immediate reboot (no sync) |
| `c` | Trigger crash dump (if kdump configured) |
| `e` | Send SIGTERM to all processes |
| `f` | Call OOM killer |
| `i` | Send SIGKILL to all processes |
| `k` | Kill all processes on current console |
| `m` | Dump memory info to console |
| `o` | Power off |
| `p` | Dump registers and flags |
| `r` | Turn off keyboard raw mode |
| `s` | Sync all filesystems |
| `t` | Dump task list |
| `u` | Remount all filesystems read-only |
| `w` | Dump blocked (D state) tasks |

**Safe reboot sequence:** `r`, `e`, `i`, `s`, `u`, `b` (REISUB)

---

## Asahi Linux / Apple Silicon Specific Notes

This system runs on Apple Silicon (aarch64) via Asahi Linux. Some considerations:

1. **WiFi Driver Stability:** The `brcmfmac` driver can be unstable under high load. Check for WiFi-related panics:
   ```bash
   journalctl -b -1 | grep -i "brcmfmac\|wifi\|wlan"
   ```

2. **GPU Issues:** Mesa/GPU driver issues can cause crashes:
   ```bash
   journalctl -b -1 | grep -i "gpu\|drm\|mesa"
   ```

3. **Power Management:** Check for power-related issues:
   ```bash
   journalctl -b -1 | grep -i "power\|suspend\|resume"
   ```

---

## Related Configuration Files

- `/etc/nixos/modules/core/crash-debug.nix` - Main crash debugging config
- `/etc/nixos/modules/core/system.nix` - systemd-coredump config (lines 104-136)
- `/etc/nixos/modules/core/memory-limits.nix` - Memory management settings
- `/etc/systemd/journald.conf` - Journald runtime config
- `/etc/atoprc` - atop configuration
