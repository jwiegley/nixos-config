{ config, lib, pkgs, ... }:

let
  # Directory for textfile collector metrics
  textfileDir = "/var/lib/prometheus/node-exporter";

  # Windows container metrics exporter script
  windowsExporter = pkgs.writeShellScript "windows-exporter" ''
    set -euo pipefail

    OUTPUT_FILE="${textfileDir}/windows_container.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"

    # Write metrics header
    cat > "$TEMP_FILE" <<'HEADER'
# HELP windows_rdp_port_open Whether Windows RDP port (3389) is listening (1 = open, 0 = closed)
# TYPE windows_rdp_port_open gauge
# HELP windows_web_port_open Whether Windows web interface port (8006) is listening (1 = open, 0 = closed)
# TYPE windows_web_port_open gauge
# HELP windows_container_memory_bytes Windows container memory usage in bytes
# TYPE windows_container_memory_bytes gauge
# HELP windows_container_cpu_seconds_total Windows container total CPU time in seconds
# TYPE windows_container_cpu_seconds_total counter
HEADER

    # Check if RDP port is open (3389)
    rdp_open=0
    if ss -tlnp | grep -q ':3389 '; then
      rdp_open=1
    fi
    echo "windows_rdp_port_open $rdp_open" >> "$TEMP_FILE"

    # Check if web interface port is open (8006)
    web_open=0
    if ss -tlnp | grep -q ':8006 '; then
      web_open=1
    fi
    echo "windows_web_port_open $web_open" >> "$TEMP_FILE"

    # Get Windows container resource usage from podman
    if ${pkgs.podman}/bin/podman ps --filter "name=windows11" --format "{{.Names}}" 2>/dev/null | grep -q "windows11"; then
      # Container is running - get stats
      stats=$(${pkgs.podman}/bin/podman stats windows11 --no-stream --format "{{.MemUsage}}\t{{.CPUPerc}}" 2>/dev/null || echo "0B / 0B	0.00%")

      # Parse memory usage (format: "1.5GiB / 8GiB")
      mem_used=$(echo "$stats" | cut -f1 | awk '{print $1}')
      mem_unit=$(echo "$mem_used" | sed 's/[0-9.]*//g')
      mem_value=$(echo "$mem_used" | sed 's/[^0-9.]//g')

      # Convert to bytes
      mem_bytes=0
      case "$mem_unit" in
        "B")
          mem_bytes=$(echo "$mem_value" | ${pkgs.bc}/bin/bc)
          ;;
        "KiB"|"KB")
          mem_bytes=$(echo "$mem_value * 1024" | ${pkgs.bc}/bin/bc)
          ;;
        "MiB"|"MB")
          mem_bytes=$(echo "$mem_value * 1024 * 1024" | ${pkgs.bc}/bin/bc)
          ;;
        "GiB"|"GB")
          mem_bytes=$(echo "$mem_value * 1024 * 1024 * 1024" | ${pkgs.bc}/bin/bc)
          ;;
      esac

      echo "windows_container_memory_bytes $mem_bytes" >> "$TEMP_FILE"

      # Get CPU time from systemd
      cpu_seconds=$(systemctl show windows11.service --property=CPUUsageNSec --value 2>/dev/null || echo "0")
      cpu_seconds=$(echo "scale=2; $cpu_seconds / 1000000000" | ${pkgs.bc}/bin/bc)
      echo "windows_container_cpu_seconds_total $cpu_seconds" >> "$TEMP_FILE"
    else
      # Container not running
      echo "windows_container_memory_bytes 0" >> "$TEMP_FILE"
      echo "windows_container_cpu_seconds_total 0" >> "$TEMP_FILE"
    fi

    # Add collection timestamp
    echo "# HELP windows_exporter_last_run_timestamp_seconds Timestamp of last Windows metrics check" >> "$TEMP_FILE"
    echo "# TYPE windows_exporter_last_run_timestamp_seconds gauge" >> "$TEMP_FILE"
    echo "windows_exporter_last_run_timestamp_seconds $(date +%s)" >> "$TEMP_FILE"

    # Atomically replace the metrics file
    ${pkgs.coreutils}/bin/mv "$TEMP_FILE" "$OUTPUT_FILE"
    ${pkgs.coreutils}/bin/chmod 644 "$OUTPUT_FILE"
  '';
in
{
  # Systemd service for Windows container metrics exporter
  systemd.services.windows-exporter = {
    description = "Windows Container Metrics Exporter for Prometheus";
    after = [ "network.target" "windows11.service" ];
    path = with pkgs; [ iproute2 gawk coreutils podman bc systemd ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = windowsExporter;
      User = "root";  # Needs root to check ports and podman stats
    };
  };

  # Timer to run exporter every 30 seconds
  systemd.timers.windows-exporter = {
    description = "Windows Container Metrics Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };

  # Ensure textfile directory exists
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];
}
