{ ... }:

# Scheduled SMART self-tests for the four tank disks.
#
# WHY THIS EXISTS
# ---------------
# SMART *collection* has been in place since 2026-06-09 (smartctl-exporter.nix), but
# nothing ever TESTED the disks. Before this module, all four Exos X18s had run exactly one
# self-test each -- the factory 'Short offline' at LifeTime 2 hours -- and had then gone
# 31,000+ power-on hours (3.5 years) untested.
#
# That gap matters because the attributes smart.yaml alerts on are REACTIVE.
# Reallocated_Sector_Ct and Current_Pending_Sector only move once the drive has already
# tripped over a bad sector during normal I/O. An extended self-test reads the whole
# platter, so it surfaces latent bad sectors in COLD data -- the hundreds of GB of
# tank/Archives nobody has read in a year -- before a scrub, or far worse a resilver
# running with degraded redundancy, has to read it.
#
# SCHEDULING -- WHY IT IS THIS SPARSE
# -----------------------------------
# Extended self-test polling time on these drives is 1412 minutes, i.e. ~23.5 HOURS each
# (`smartctl -c /dev/sda`). So tests must be spaced days apart, not hours, and only one
# drive may be under test at a time. The schedule is one drive per week, each drive tested
# monthly:
#
#   sda  day 08 02:00      sdc  day 22 02:00
#   sdb  day 15 02:00      sdd  day 28 02:00
#
# Each run finishes around 01:30 the following day, leaving ~6 days of clear air before the
# next drive starts, and clearing zfs-scrub.timer (monthly, 1st ~01:20) by several days at
# both ends.
#
# THE UAS ENCLOSURE. Per project_tank_uas_enclosure_failure the OWC USB bridge hangs under
# load, and smartctl-exporter.nix already keeps its poll deliberately gentle for that
# reason. A self-test is executed by the drive's own firmware rather than driven over the
# bus, so it is not the load shape that has taken tank down before -- but it does make the
# drive slower to answer, which is how bridge timeouts start. Hence one drive at a time
# with days of margin, rather than the weekly-all-disks pattern the smartd manpage suggests.
#
# SHORT TESTS ARE DELIBERATELY OMITTED. Running short tests alongside long ones would make
# smart_selftest_age_hours (see smart-selftest-exporter.nix) reflect the most recent test of
# ANY type, so a silently-stopped long-test schedule would hide behind fresh short-test
# timestamps -- reintroducing the exact invisibility this work exists to remove. Long tests
# only keeps that metric an unambiguous measure of full-surface coverage.
#
# The boot NVMe is NOT monitored here. autodetect is off precisely to keep DEVICESCAN from
# picking it up: Apple ANS NVMe is the device that already had to be removed from
# smartctl_exporter (see the comment there), and its self-test support is not established.
# It is covered for health by nvme-smart-exporter.nix.

{
  services.smartd = {
    enable = true;

    # Explicit device list only. The default (true) would DEVICESCAN every block device,
    # including the Apple ANS NVMe this host has already had trouble with.
    autodetect = false;

    # Notifications go through Prometheus and Alertmanager, never smartd's own channels.
    # Both of these default to ON here -- wall unconditionally, and mail because postfix
    # provides a sendmail setuid wrapper -- which would put disk alerts on a second,
    # unsilenceable path outside Alertmanager. Results reach Prometheus instead via
    # smart-selftest-exporter.nix, and are alerted on in alerts/smart-selftest.yaml.
    notifications = {
      mail.enable = false;
      wall.enable = false;
    };

    # Device lines inherit `-a` from services.smartd.defaults.monitored (the module
    # default), which enables health, error-log and self-test-log monitoring. Only the
    # schedule is set per device.
    #
    # smartd schedule syntax is T/MM/DD/d/HH: test type, month, day-of-month, day-of-week,
    # hour. `.` matches anything. `L/../08/./02` is therefore "long test, any month, on the
    # 8th, any weekday, at 02:00".
    #
    # NOT setting `-o on` (automatic offline data collection) is deliberate: the extended
    # test already covers the full surface, and adding background firmware activity on a
    # bridge with this host's history buys nothing.
    devices = [
      {
        device = "/dev/sda";
        options = "-s L/../08/./02";
      }
      {
        device = "/dev/sdb";
        options = "-s L/../15/./02";
      }
      {
        device = "/dev/sdc";
        options = "-s L/../22/./02";
      }
      {
        device = "/dev/sdd";
        options = "-s L/../28/./02";
      }
    ];
  };
}
