{
  config,
  lib,
  pkgs,
  ...
}:

# APC Back-UPS Pro 1000S (BR1000MS) via NUT (Network UPS Tools)
#
# usbhid-ups talks to the UPS over USB-HID (vendor 051d, product 0002).
# upsd binds 127.0.0.1:3493 only; Home Assistant (native service) connects
# locally. upsmon owns graceful shutdown on low battery (LB ~10%) as a
# last-resort fallback; the timer below triggers an earlier graceful
# poweroff at lowBatteryShutdownPercent (default 50%) while still on
# utility power's reserve.
#
# Passwords live in SOPS at  nut/upsmon-password  and
# nut/homeassistant-password. Both are read by systemd via LoadCredential.

let
  lowBatteryShutdownPercent = 50;

  nut = config.power.ups.package;

  # Polls upsd; if on battery (status contains OB) AND battery.charge is
  # below the threshold, initiate a clean poweroff. Silent no-op if upsd
  # is unreachable or vars are missing (e.g. driver still starting).
  pollScript = pkgs.writeShellScript "nut-low-battery-poweroff" ''
    set -u
    UPSC=${nut}/bin/upsc
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    LOGGER=${pkgs.util-linux}/bin/logger

    status=$("$UPSC" apc@localhost ups.status 2>/dev/null || true)
    charge=$("$UPSC" apc@localhost battery.charge 2>/dev/null || true)

    if [ -z "$status" ] || [ -z "$charge" ]; then
      exit 0
    fi

    # ups.status is a space-separated set of flags (OL, OB, LB, CHRG, ...).
    case " $status " in
      *" OB "*) ;;
      *) exit 0 ;;
    esac

    # battery.charge is reported as an integer percent.
    if [ "$charge" -lt ${toString lowBatteryShutdownPercent} ]; then
      "$LOGGER" -p daemon.warning -t nut-low-battery-poweroff \
        "ups.status=$status battery.charge=$charge%; threshold=${toString lowBatteryShutdownPercent}%; initiating poweroff"
      exec "$SYSTEMCTL" poweroff
    fi
  '';
in

{
  sops.secrets."nut/upsmon-password" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [
      "upsd.service"
      "upsmon.service"
    ];
  };

  sops.secrets."nut/homeassistant-password" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "upsd.service" ];
  };

  power.ups = {
    enable = true;
    mode = "standalone";

    ups.apc = {
      driver = "usbhid-ups";
      port = "auto";
      description = "APC Back-UPS Pro 1000S (BR1000MS)";
    };

    upsd.listen = [
      {
        address = "127.0.0.1";
        port = 3493;
      }
    ];

    users.upsmon = {
      passwordFile = config.sops.secrets."nut/upsmon-password".path;
      upsmon = "primary";
    };

    users.homeassistant = {
      passwordFile = config.sops.secrets."nut/homeassistant-password".path;
    };

    upsmon.monitor.apc = {
      system = "apc@localhost";
      user = "upsmon";
      type = "primary";
    };
  };

  systemd.services.nut-low-battery-poweroff = {
    description = "Power off when UPS is on battery and charge < ${toString lowBatteryShutdownPercent}%";
    after = [ "upsd.service" ];
    requires = [ "upsd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pollScript;
    };
  };

  systemd.timers.nut-low-battery-poweroff = {
    description = "Periodic UPS low-battery check (every 30s)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60s";
      OnUnitActiveSec = "30s";
      Unit = "nut-low-battery-poweroff.service";
      AccuracySec = "5s";
    };
  };
}
