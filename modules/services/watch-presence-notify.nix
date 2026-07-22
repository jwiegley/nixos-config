{
  config,
  lib,
  pkgs,
  ...
}:

# Notify (via Home Assistant iPhone push) when the unrecognized "Watch" device
# (192.168.3.77, randomized MAC 66:97:7f:43:f1:6a) joins the WiFi network, so the
# user can catch it and identify it. Requested 2026-07-21.
#
# Detection: the device is a sleeping WiFi client with a private/randomized MAC.
# We treat it as PRESENT when it is unicast-reachable — ICMP reply OR a resolved
# ARP neighbor entry (an active device answers ARP at L2 even if it drops ICMP).
# We deliberately do NOT use mDNS here: avahi caches watch.lan and reports it
# "present" long after the device leaves, which would both false-fire and defeat
# edge detection. Edge-triggered (absent->present) with a 10-min debounce; the
# first run just records a baseline so we don't fire on a stale state.
#
# CAVEAT: if the AP isolates WiFi clients (station isolation), vulcan cannot
# unicast-reach the Watch even when it is online, and this will stay silent. If
# the user sees the Watch was online but got no alert, switch to a passive
# mDNS-announcement monitor instead. The .3.77 IP is its current DHCP lease; a
# DHCP reservation on OPNsense would make it stable.
#
# Message path verified 2026-07-21 (test push, HTTP 200) to
# notify.mobile_app_john_wiegleys_iphone. Remove this import to disable.

let
  watchIp = "192.168.3.77";
  haTokenPath = "/run/secrets/openclaw/home-assistant-token";

  checkScript = pkgs.writeShellScript "watch-presence-check" ''
    set -uo pipefail
    STATE_DIR="$STATE_DIRECTORY"
    STATE="$STATE_DIR/present"
    LASTNOTIFY="$STATE_DIR/last-notify"

    # --- presence: ICMP reply, or a resolved ARP neighbor (active at L2) ---
    present=0
    if ${pkgs.iputils}/bin/ping -c1 -W2 ${watchIp} >/dev/null 2>&1; then
      present=1
    else
      # nudge ARP resolution, then read the neighbor state
      ${pkgs.iputils}/bin/ping -c1 -W1 ${watchIp} >/dev/null 2>&1 || true
      if ${pkgs.iproute2}/bin/ip neigh show ${watchIp} 2>/dev/null \
           | ${pkgs.gnugrep}/bin/grep -qE 'REACHABLE|STALE|DELAY|PROBE'; then
        present=1
      fi
    fi

    # first run: record baseline only, never fire on a stale/unknown state
    if [ ! -f "$STATE" ]; then
      echo "$present" > "$STATE"
      exit 0
    fi
    prev=$(cat "$STATE" 2>/dev/null || echo 0)
    echo "$present" > "$STATE"

    now=$(${pkgs.coreutils}/bin/date +%s)
    if [ "$present" = "1" ] && [ "$prev" = "0" ]; then
      last=0
      [ -f "$LASTNOTIFY" ] && last=$(cat "$LASTNOTIFY" 2>/dev/null || echo 0)
      if [ $((now - last)) -gt 600 ]; then
        echo "$now" > "$LASTNOTIFY"
        TOKEN=$(cat ${haTokenPath})
        ${pkgs.curl}/bin/curl -sS -m8 -X POST \
          -H "Authorization: Bearer $TOKEN" \
          -H 'Content-Type: application/json' \
          -d '{"title":"⌚ Watch came online","message":"The unrecognized \"Watch\" device (192.168.3.77) just joined the WiFi network — detected on vulcan."}' \
          http://localhost:8123/api/services/notify/mobile_app_john_wiegleys_iphone \
          >/dev/null 2>&1 || true
      fi
    fi
  '';
in
{
  systemd.services.watch-presence-notify = {
    description = "Notify via HA when the unrecognized 'Watch' device joins WiFi";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = checkScript;
      User = "root"; # root has CAP_NET_RAW for ping + can read /run/secrets
      StateDirectory = "watch-presence";
    };
  };

  systemd.timers.watch-presence-notify = {
    description = "Poll for the unrecognized 'Watch' device joining WiFi";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "60s";
      RandomizedDelaySec = "10s";
    };
  };
}
