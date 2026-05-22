{ config, ... }:

# APC Back-UPS Pro 1000S (BR1000MS) via NUT (Network UPS Tools)
#
# usbhid-ups talks to the UPS over USB-HID (vendor 051d, product 0002).
# upsd binds 127.0.0.1:3493 only; Home Assistant (native service) connects
# locally. upsmon owns graceful shutdown on low battery (LB).
#
# Passwords live in SOPS at  nut/upsmon-password  and
# nut/homeassistant-password. Both are read by systemd via LoadCredential.

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
}
