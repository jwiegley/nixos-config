# OpenClaw gateway canary
#
# Parses /var/lib/openclaw/.openclaw/logs/gateway-vm.log for the most recent
# `[gateway] ready (N plugins: …)` line and emits Prometheus metrics via the
# node-exporter textfile collector:
#
#   openclaw_gateway_ready_plugins_total
#   openclaw_gateway_ready_timestamp_seconds
#   openclaw_gateway_ready_age_seconds
#   openclaw_plugin_init_failures_recent_total
#   openclaw_canary_parse_ok
#   openclaw_canary_last_run_timestamp_seconds
#   openclaw_channel_plugin_loaded{channel=…}
#
# The last one is the load-bearing signal: `discord`, `whatsapp`, etc.
# each get a 0/1 indicator.  Alertmanager rules in alerts/openclaw.yaml
# fire when these turn red.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  # Plugins that must be present in the most-recent `[gateway] ready` line
  # for OpenClaw to be serving its full capability surface.  Keep this in
  # sync with the auto-enabled set under `plugins:` in openclaw.json; a
  # mismatch produces a false-positive alert, not a silent failure.
  expectedChannels = [
    "discord"
    "whatsapp"
    "lobster"
    "acpx"
    "memory-qdrant"
  ];

  canaryScript = pkgs.writeScript "openclaw-canary.py" ''
    #!${pkgs.python3}/bin/python3
    """OpenClaw gateway-log parser → Prometheus textfile exporter.

    Scans the tail of gateway-vm.log for:

        <rfc3339-ts> [gateway] ready (<N> plugin[s]: <comma,list>; <T>ms)

    and scans gateway-vm.err.log for recent `plugin(s) failed to
    initialize` entries so a stale `ready` line followed by a crashed
    restart is still visible in the metrics.
    """

    import os
    import pathlib
    import re
    import subprocess
    import sys
    import time
    from datetime import datetime

    LOG_PATH = pathlib.Path("/var/lib/openclaw/.openclaw/logs/gateway-vm.log")
    ERR_PATH = pathlib.Path("/var/lib/openclaw/.openclaw/logs/gateway-vm.err.log")
    OUT_FINAL = pathlib.Path("${textfileDir}/openclaw_canary.prom")
    OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")
    EXPECTED = ${builtins.toJSON expectedChannels}
    SYSTEMCTL = "${pkgs.systemd}/bin/systemctl"
    MICROVM_UNIT = "microvm@openclaw.service"

    READY_RE = re.compile(
        r"^(?P<ts>\S+)\s+\[gateway\]\s+ready\s+"
        r"\((?P<n>\d+)\s+plugin[s]?:\s*(?P<list>[^;]+);"
    )
    FAIL_RE = re.compile(
        r"^(?P<ts>\S+)\s+\[plugins\]\s+(?P<n>\d+)\s+"
        r"plugin\(s\)\s+failed\s+to\s+initialize"
    )


    def iso_to_epoch(s: str) -> float:
        try:
            return datetime.fromisoformat(s).timestamp()
        except ValueError:
            try:
                return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").timestamp()
            except Exception:
                return 0.0


    def tail(path: pathlib.Path, lines: int = 800) -> list[str]:
        if not path.exists():
            return []
        try:
            out = subprocess.check_output(
                ["${pkgs.coreutils}/bin/tail", "-n", str(lines), str(path)],
                text=True,
                errors="replace",
            )
            return out.splitlines()
        except subprocess.CalledProcessError:
            return []


    def find_last(regex: re.Pattern[str], lines: list[str]) -> re.Match | None:
        for line in reversed(lines):
            m = regex.search(line)
            if m:
                return m
        return None


    def microvm_active_enter_ts() -> float:
        """Unix timestamp of when microvm@openclaw.service last entered active
        state, or 0.0 if unavailable.  Used to distinguish "ready line is old
        but this boot's ready was emitted" from "VM is up but never reached
        ready this boot"."""
        try:
            out = subprocess.check_output(
                [SYSTEMCTL, "show", "-p", "ActiveEnterTimestamp",
                 "--value", "--timestamp=unix", MICROVM_UNIT],
                text=True,
            ).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            return 0.0
        if not out or not out.startswith("@"):
            return 0.0
        try:
            return float(out[1:])
        except ValueError:
            return 0.0


    def write_metrics(payload: dict[str, float], channel_loaded: dict[str, float]) -> None:
        OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
        with OUT_TMP.open("w") as f:
            f.write(
                "# HELP openclaw_gateway_ready_plugins_total Plugin count from the most recent [gateway] ready line\n"
                "# TYPE openclaw_gateway_ready_plugins_total gauge\n"
                f"openclaw_gateway_ready_plugins_total {payload['plugins_total']}\n"
                "# HELP openclaw_gateway_ready_timestamp_seconds Unix timestamp of the most recent [gateway] ready line\n"
                "# TYPE openclaw_gateway_ready_timestamp_seconds gauge\n"
                f"openclaw_gateway_ready_timestamp_seconds {payload['ready_ts']}\n"
                "# HELP openclaw_gateway_ready_age_seconds Seconds since the most recent [gateway] ready line\n"
                "# TYPE openclaw_gateway_ready_age_seconds gauge\n"
                f"openclaw_gateway_ready_age_seconds {payload['ready_age']}\n"
                "# HELP openclaw_plugin_init_failures_recent_total Plugin init failures seen in the log tail\n"
                "# TYPE openclaw_plugin_init_failures_recent_total gauge\n"
                f"openclaw_plugin_init_failures_recent_total {payload['init_failures']}\n"
                "# HELP openclaw_canary_parse_ok 1 if the canary successfully parsed a recent ready line\n"
                "# TYPE openclaw_canary_parse_ok gauge\n"
                f"openclaw_canary_parse_ok {payload['parse_ok']}\n"
                "# HELP openclaw_canary_last_run_timestamp_seconds When the canary last ran\n"
                "# TYPE openclaw_canary_last_run_timestamp_seconds gauge\n"
                f"openclaw_canary_last_run_timestamp_seconds {time.time()}\n"
                "# HELP openclaw_microvm_active_enter_timestamp_seconds Unix timestamp when microvm@openclaw.service last entered active state\n"
                "# TYPE openclaw_microvm_active_enter_timestamp_seconds gauge\n"
                f"openclaw_microvm_active_enter_timestamp_seconds {payload['vm_start_ts']}\n"
                "# HELP openclaw_channel_plugin_loaded 1 if the plugin is present in the most recent [gateway] ready list\n"
                "# TYPE openclaw_channel_plugin_loaded gauge\n"
            )
            for name, present in channel_loaded.items():
                f.write(f'openclaw_channel_plugin_loaded{{channel="{name}"}} {present}\n')
        os.replace(OUT_TMP, OUT_FINAL)


    def main() -> int:
        now = time.time()
        lines = tail(LOG_PATH, 1200)
        err_lines = tail(ERR_PATH, 1200)
        vm_start_ts = microvm_active_enter_ts()

        ready = find_last(READY_RE, lines)
        # Count any failure lines that are NEWER than the most recent ready
        # line.  This way a plugin failure followed by a successful restart
        # does not stay red forever.
        ready_ts_str = ready["ts"] if ready else ""
        ready_epoch = iso_to_epoch(ready_ts_str) if ready_ts_str else 0.0
        fail_count = 0
        for line in err_lines:
            m = FAIL_RE.search(line)
            if not m:
                continue
            if iso_to_epoch(m["ts"]) >= ready_epoch:
                fail_count += 1

        channel_loaded = {c: 0.0 for c in EXPECTED}
        if ready:
            plugin_list = [p.strip() for p in ready["list"].split(",") if p.strip()]
            for c in EXPECTED:
                channel_loaded[c] = 1.0 if c in plugin_list else 0.0
            payload = dict(
                plugins_total=float(int(ready["n"])),
                ready_ts=ready_epoch,
                ready_age=max(0.0, now - ready_epoch) if ready_epoch else 0.0,
                init_failures=float(fail_count),
                parse_ok=1.0,
                vm_start_ts=vm_start_ts,
            )
        else:
            payload = dict(
                plugins_total=0.0,
                ready_ts=0.0,
                ready_age=0.0,
                init_failures=float(fail_count),
                parse_ok=0.0,
                vm_start_ts=vm_start_ts,
            )

        write_metrics(payload, channel_loaded)
        return 0


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
{
  systemd.services.openclaw-canary = {
    description = "OpenClaw gateway log → Prometheus textfile metrics";

    # ProtectSystem=strict makes ReadOnlyPaths the default; explicitly allow
    # writing only into the textfile dir.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${canaryScript}";
      # Must run as `openclaw` because the log directory
      # (/var/lib/openclaw/.openclaw/logs) is 0700 openclaw:openclaw — that
      # permission mode is set by the VM itself via the virtiofs-shared state
      # dir and can't be relaxed from the host.  Writes go to the
      # 1777-mode textfile dir, so the prometheus user reads it just fine.
      User = "openclaw";
      Group = "openclaw";
      UMask = "0022";
      ReadOnlyPaths = [ "/var/lib/openclaw/.openclaw/logs" ];
      ReadWritePaths = [ textfileDir ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallFilter = [ "@system-service" ];
    };
  };

  systemd.timers.openclaw-canary = {
    description = "Run the OpenClaw gateway canary every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      Persistent = true;
      Unit = "openclaw-canary.service";
    };
  };
}
