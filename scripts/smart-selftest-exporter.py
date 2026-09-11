"""Export SMART self-test log results as node-exporter textfile metrics.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add one
here or flake8 flags it as E265.

WHY THIS EXISTS
---------------
smartctl_exporter collects SMART *attributes* for the four Exos X18s, but it emits NO
self-test family at all -- verified against the live /metrics endpoint on 2026-09-11, where
the closest thing is smartctl_device_error_log_count. So once services.smartd began running
scheduled self-tests (modules/monitoring/services/smartd.nix), both a test FAILURE and,
worse, the silent ABSENCE of tests would have been invisible to Prometheus.

That absence is not hypothetical. Before smartd was enabled, all four drives had run
exactly one self-test each -- the factory 'Short offline' at LifeTime 2 hours -- and had
then gone 31,000+ power-on hours untested, with nothing anywhere reporting that fact. The
staleness metric below exists specifically so that cannot recur quietly.

WHY AGE IS MEASURED IN DRIVE HOURS, NOT WALL CLOCK
--------------------------------------------------
The self-test log does not record a timestamp. It records the drive's own power-on hour
counter at the time of the test (`lifetime_hours`). Subtracting that from the current
Power_On_Hours attribute gives the age of the last test in DRIVE hours, which is both the
only figure derivable from the log and the more meaningful one: a powered-off drive is not
accumulating untested wear. These disks run 24/7, so drive hours and wall hours track
closely here anyway.

A drive that has never been tested reports age = its full Power_On_Hours, which is the
honest answer and lets one alert cover both "never tested" and "stopped being tested".

Metrics emitted (labelled device="sdX"):
  smart_selftest_last_passed          1 = last completed test finished without error
  smart_selftest_last_failed          1 = last test hit a disk fault (status 3-8)
  smart_selftest_running              1 = a self-test is in progress right now
  smart_selftest_last_status          ATA execution status code, byte >> 4 (0 = clean)
  smart_selftest_remaining_percent    percent of an in-progress test still to run
  smart_selftest_last_lifetime_hours  drive power-on hour at which the last test ran
  smart_selftest_power_on_hours       drive power-on hours now
  smart_selftest_age_hours            drive hours since the last test (the staleness signal)
  smart_selftest_log_entries          entries currently in the self-test log
  smart_selftest_error_count_total    tests in the log that ended in error
  smart_selftest_collector_success    0 if this script could not read ANY device
  smart_selftest_collector_timestamp_seconds
"""

import json
import os
import subprocess
import sys
import time

DEVICES = os.environ.get("SMART_DEVICES", "/dev/sda,/dev/sdb,/dev/sdc,/dev/sdd").split(",")
OUT = os.environ.get(
    "TEXTFILE_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/smart_selftest.prom",
)

# ATA packs the self-test log status byte as TWO nibbles: bits 7:4 are the execution status
# code, bits 3:0 are the percent remaining in 10% units. So the raw byte must be shifted
# before it means anything. A completed clean test is 0x00, but a test with 90% remaining is
# 0xF9 = 249 -- NOT 15. Comparing the raw byte against the status code silently misreported
# a running test as "not running" until a real extended test was started on 2026-09-11 and
# the collector reported status 249 with running=0.
#
# Status codes after shifting: 0 is clean; 1-2 mean a host aborted or reset the test, which
# is an operational event and NOT a disk fault (a reboot mid-test lands here); 3-8 are real
# drive faults; 15 means still running. Treating 1-2 as failure would page on every reboot
# that interrupts a 23.5-hour extended test, so they are deliberately neither passed nor
# failed -- they simply leave the previous verdict standing and let age_hours climb.
#
# smartctl's own `passed` field is NOT usable here: it reports true for an in-progress test,
# which has not passed anything yet.
STATUS_IN_PROGRESS = 15
STATUS_FAULT_RANGE = range(3, 9)


def status_code(raw: int) -> int:
    """Decode the ATA self-test status byte to its execution status code."""
    return raw >> 4 if raw >= 0 else -1


HELP = {
    "smart_selftest_last_passed": ("1 if the last self-test completed without error", "gauge"),
    "smart_selftest_last_failed": ("1 if the last self-test ended in a drive fault", "gauge"),
    "smart_selftest_running": ("1 if a self-test is currently in progress", "gauge"),
    "smart_selftest_last_status": ("ATA self-test execution status code (byte >> 4); 0 is clean", "gauge"),
    "smart_selftest_remaining_percent": ("Percent of the in-progress self-test still remaining", "gauge"),
    "smart_selftest_last_lifetime_hours": ("Drive power-on hour at which the last test ran", "gauge"),
    "smart_selftest_power_on_hours": ("Drive power-on hours now", "gauge"),
    "smart_selftest_age_hours": ("Drive hours elapsed since the last self-test", "gauge"),
    "smart_selftest_log_entries": ("Entries currently held in the self-test log", "gauge"),
    "smart_selftest_error_count_total": ("Self-tests in the log that ended in error", "gauge"),
}


def collect(device: str) -> dict:
    """Return metric name -> value for one device. Raises on unreadable device."""
    proc = subprocess.run(
        ["smartctl", "-j", "-l", "selftest", "-A", device],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    data = json.loads(proc.stdout)

    # smartctl's exit status is a BITFIELD, not a simple code. Bits 0-2 are hard failures
    # (command line / device open / SMART command failed); bit 3 means DISK FAILING, which
    # is an advisory we must REPORT rather than swallow. This mirrors the reasoning in
    # scripts/nvme-smart-exporter.py, where bailing on any low bit once made the critical
    # alert unable to fire in exactly the case it existed for.
    status = data.get("smartctl", {}).get("exit_status", 0)
    if (status & 0b111) and not (status & 0b1000):
        raise RuntimeError(f"smartctl hard failure on {device}, exit bits {status & 0b111}")

    rows: dict = {}

    poh = None
    for attr in data.get("ata_smart_attributes", {}).get("table", []):
        if attr.get("name") == "Power_On_Hours":
            poh = attr.get("raw", {}).get("value")
            break
    if poh is not None:
        rows["smart_selftest_power_on_hours"] = poh

    log = data.get("ata_smart_self_test_log", {}).get("standard", {}) or {}
    table = log.get("table", []) or []
    rows["smart_selftest_log_entries"] = log.get("count", len(table))
    rows["smart_selftest_error_count_total"] = log.get("error_count_total", 0)

    if not table:
        # Never tested. Emit an explicit verdict rather than omitting the series: an ABSENT
        # metric is indistinguishable from a healthy one, which is the whole failure mode
        # this collector exists to remove. Age is the drive's entire service life.
        rows["smart_selftest_last_passed"] = 0
        rows["smart_selftest_last_failed"] = 0
        rows["smart_selftest_running"] = 0
        if poh is not None:
            rows["smart_selftest_age_hours"] = poh
        return rows

    # The table is ordered newest first.
    last = table[0]
    status = last.get("status", {})
    code = status_code(status.get("value", -1))
    rows["smart_selftest_last_status"] = code
    rows["smart_selftest_running"] = 1 if code == STATUS_IN_PROGRESS else 0
    rows["smart_selftest_last_passed"] = 1 if code == 0 else 0
    rows["smart_selftest_last_failed"] = 1 if code in STATUS_FAULT_RANGE else 0
    if code == STATUS_IN_PROGRESS:
        rows["smart_selftest_remaining_percent"] = status.get("remaining_percent", 0)

    lifetime = last.get("lifetime_hours")
    if lifetime is not None:
        rows["smart_selftest_last_lifetime_hours"] = lifetime

    # Age is measured from the most recent CONCLUDED test, not merely the most recent log
    # entry. A test that was aborted, interrupted or is still running did not read the
    # surface, so it must not reset the staleness clock.
    #
    # Keying off the newest entry regardless of outcome would leave a real hole: if every
    # monthly test were aborted -- by a reboot landing on the scheduled day, say -- each
    # abort would push the reference forward and SmartSelfTestStale could never fire, even
    # though no test had actually completed in years. That is precisely the silent-absence
    # failure this collector exists to prevent, so it is worth the extra scan.
    #
    # An in-flight test is handled by the alert instead (it excludes running devices),
    # which keeps a legitimate 23.5-hour run from tripping staleness without pretending the
    # surface has already been read.
    if poh is not None:
        concluded = None
        for entry in table:
            entry_code = status_code(entry.get("status", {}).get("value", -1))
            if entry_code in (1, 2, STATUS_IN_PROGRESS):
                continue  # aborted, interrupted or still running: did not read the surface
            if entry.get("lifetime_hours") is not None:
                concluded = entry["lifetime_hours"]
                break
        # Clamp at zero: a test logged in the current hour can read one hour ahead of the
        # attribute, and a negative age would look like a clock fault downstream. With no
        # concluded test at all, the honest age is the drive's entire service life.
        rows["smart_selftest_age_hours"] = max(0, poh - concluded) if concluded is not None else poh

    return rows


def main() -> int:
    lines = []
    collected: dict = {}
    any_ok = False

    for device in DEVICES:
        device = device.strip()
        if not device:
            continue
        label = os.path.basename(device)
        try:
            collected[label] = collect(device)
            any_ok = True
        except Exception as exc:  # noqa: BLE001
            # Skip this device but keep going: one unreadable disk must not suppress the
            # other three. Report the type only -- smartctl messages can carry the device
            # serial, which does not belong in a world-readable .prom file.
            print(f"smart-selftest-exporter: {label}: {type(exc).__name__}", file=sys.stderr)

    for name, (help_text, kind) in HELP.items():
        emitted = False
        for label, rows in collected.items():
            if name not in rows:
                continue
            if not emitted:
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} {kind}")
                emitted = True
            lines.append(f'{name}{{device="{label}"}} {rows[name]}')

    lines.append("# HELP smart_selftest_collector_success 1 if this collector read at least one device")
    lines.append("# TYPE smart_selftest_collector_success gauge")
    lines.append(f"smart_selftest_collector_success {1 if any_ok else 0}")
    lines.append("# HELP smart_selftest_collector_timestamp_seconds Unix time of the last collector run")
    lines.append("# TYPE smart_selftest_collector_timestamp_seconds gauge")
    lines.append(f"smart_selftest_collector_timestamp_seconds {time.time():.0f}")

    tmp = f"{OUT}.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)  # atomic; avoids half-written .prom files
    os.chmod(OUT, 0o644)  # health metrics only, no secrets

    return 0 if any_ok else 1


if __name__ == "__main__":
    sys.exit(main())
