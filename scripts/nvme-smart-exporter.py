"""Export boot-NVMe SMART health as node-exporter textfile metrics.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add one
here or flake8 flags it as E265.

WHY THIS EXISTS RATHER THAN USING smartctl_exporter
---------------------------------------------------
/dev/nvme0n1 backs / and /nix/store and had NO automated SMART coverage at all. It was
listed in smartctl_exporter once and REMOVED on 2026-07-03 (see
modules/monitoring/services/smartctl-exporter.nix) because that exporter hardcodes
`--log=error`, which hits an unsupported log page (0x109) on this Apple ANS NVMe; smartctl
exits 4 and exporter 0.14.0 then DISCARDS the device entirely, so it never appeared in
smartctl_devices despite being configured and SmartDeviceMissing fired on every boot.

Re-adding it to that exporter would reintroduce a known-broken state. This collector is the
follow-up the module comment describes, and it works because it avoids the failing log page:
`smartctl -j -H -A` returns exit_status 0 on this device and yields the full NVMe health log.
Verified 2026-07-29.

Metrics emitted (all labelled device="nvme0n1"):
  nvme_smart_healthy                 1 = SMART overall-health PASSED
  nvme_smart_critical_warning        NVMe critical warning bitfield (0 = clear)
  nvme_smart_media_errors            cumulative unrecoverable data-integrity errors
  nvme_smart_error_log_entries       cumulative controller error-log entries
  nvme_smart_percentage_used         vendor wear estimate, 0-100+ (100 = rated life)
  nvme_smart_available_spare         percent of spare capacity remaining
  nvme_smart_available_spare_threshold  vendor floor below which spare is critical
  nvme_smart_temperature_celsius
  nvme_smart_data_units_written      512,000-byte units, for endurance trending
  nvme_smart_collector_success       0 if this script could not read the device
  nvme_smart_collector_timestamp_seconds
"""

import json
import os
import subprocess
import sys
import time

DEVICE = os.environ.get("NVME_DEVICE", "/dev/nvme0n1")
LABEL = os.path.basename(DEVICE)
OUT = os.environ.get(
    "TEXTFILE_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/nvme_smart.prom",
)

# Deliberately NOT passing --log=error or -x: those hit log page 0x109 on Apple ANS NVMe
# and make smartctl exit 4. -H (health) plus -A (attributes) is the combination proven to
# return exit_status 0 here.
CMD = ["smartctl", "-j", "-H", "-A", DEVICE]

HELP = {
    "nvme_smart_healthy": ("1 if SMART overall-health self-assessment is PASSED", "gauge"),
    "nvme_smart_critical_warning": ("NVMe critical warning bitfield; 0 is clear", "gauge"),
    "nvme_smart_media_errors": ("Cumulative unrecoverable data-integrity errors", "counter"),
    "nvme_smart_error_log_entries": ("Cumulative controller error-log entries", "counter"),
    "nvme_smart_percentage_used": ("Vendor wear estimate; 100 means rated life reached", "gauge"),
    "nvme_smart_available_spare": ("Percent of spare capacity remaining", "gauge"),
    "nvme_smart_available_spare_threshold": ("Vendor floor below which spare is critical", "gauge"),
    "nvme_smart_temperature_celsius": ("Composite temperature", "gauge"),
    "nvme_smart_data_units_written": ("Data units written (512 KiB each)", "counter"),
    "nvme_smart_collector_success": ("1 if this collector read the device successfully", "gauge"),
    "nvme_smart_collector_timestamp_seconds": ("Unix time of the last collector run", "gauge"),
}


def _emit(rows: dict, ok: int) -> None:
    lines = []
    for name, (help_text, kind) in HELP.items():
        if name not in rows and name not in (
            "nvme_smart_collector_success",
            "nvme_smart_collector_timestamp_seconds",
        ):
            continue
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {kind}")
        if name == "nvme_smart_collector_success":
            lines.append(f"{name} {ok}")
        elif name == "nvme_smart_collector_timestamp_seconds":
            lines.append(f"{name} {time.time():.0f}")
        else:
            lines.append(f'{name}{{device="{LABEL}"}} {rows[name]}')
    tmp = f"{OUT}.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)  # atomic; avoids half-written .prom files
    os.chmod(OUT, 0o644)  # health metrics only, no secrets


def main() -> int:
    rows: dict = {}
    try:
        proc = subprocess.run(CMD, capture_output=True, text=True, timeout=60, check=False)
        data = json.loads(proc.stdout)
        # smartctl's exit status is a BITFIELD, not a simple code: bits 0-2 are hard
        # failures (command line / device open / SMART command failed) while higher bits
        # are advisory (e.g. bit 3 = disk failing, which is exactly what we want to
        # REPORT rather than treat as a collector error). Only bail on the low bits.
        status = data.get("smartctl", {}).get("exit_status", 0)
        hard = status & 0b111
        # Bit 3 means "DISK FAILING" -- an advisory we must REPORT, not swallow. But a real
        # failing disk often sets bit 3 TOGETHER with a low bit (e.g. exit_status 12 = bits
        # 3+2), and the first version of this code bailed on any low bit, dropping every
        # device metric. That made NVMeSmartFailed (critical) unable to fire in exactly the
        # case it exists for, leaving only NVMeSmartCollectorFailing (warning). So when bit 3
        # is set we continue and publish, even if a low bit is also set.
        disk_failing = bool(status & 0b1000)
        if hard and not disk_failing:
            print(f"smartctl hard failure, exit_status bits {hard}", file=sys.stderr)
            _emit({}, 0)
            return 1
        log = data.get("nvme_smart_health_information_log", {}) or {}
        # Only trust smart_status if it is actually PRESENT. Assigning unconditionally (as the
        # first version did) turned malformed or truncated smartctl JSON into healthy=0 with
        # collector_success=1 -- i.e. NVMeSmartFailed CRITICAL on a perfectly healthy disk,
        # the exact inverse of this collector's purpose. It also made the later
        # "not in rows" guard unreachable.
        smart_status = data.get("smart_status") or {}
        if "passed" not in smart_status:
            print("smartctl output has no smart_status.passed field", file=sys.stderr)
            _emit({}, 0)
            return 1
        rows["nvme_smart_healthy"] = 1 if smart_status.get("passed") else 0
        if disk_failing:
            print("smartctl reports DISK FAILING (exit_status bit 3)", file=sys.stderr)
            rows["nvme_smart_healthy"] = 0
        for key, metric in (
            ("critical_warning", "nvme_smart_critical_warning"),
            ("media_errors", "nvme_smart_media_errors"),
            ("num_err_log_entries", "nvme_smart_error_log_entries"),
            ("percentage_used", "nvme_smart_percentage_used"),
            ("available_spare", "nvme_smart_available_spare"),
            ("available_spare_threshold", "nvme_smart_available_spare_threshold"),
            ("data_units_written", "nvme_smart_data_units_written"),  # 512,000-byte units
        ):
            if key in log:
                rows[metric] = log[key]
        temp = log.get("temperature", data.get("temperature", {}).get("current"))
        if temp is not None:
            rows["nvme_smart_temperature_celsius"] = temp
    except Exception as exc:  # noqa: BLE001
        # Emit collector_success=0 rather than nothing: an ABSENT metric set is
        # indistinguishable from a healthy disk, which is the failure mode this whole
        # effort exists to remove.
        print(f"nvme-smart-exporter: {type(exc).__name__}", file=sys.stderr)
        _emit({}, 0)
        return 1

    _emit(rows, 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
