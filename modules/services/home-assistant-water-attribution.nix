# modules/services/home-assistant-water-attribution.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.home-assistant-water-attribution;

  zoneSubmodule = lib.types.submodule {
    options = {
      slug = lib.mkOption {
        type = lib.types.str;
        description = "Snake-case slug matching valve.sprinkler_control_<slug>_zone";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "Human-readable display name";
      };
      type = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "spray" "drip" ]);
        default = null;
        description = "Sprinkler head type, used as InfluxDB tag";
      };
    };
  };

in
{
  options.services.home-assistant-water-attribution = {
    enable = lib.mkEnableOption "water attribution tracking in Home Assistant";

    flumeCurrentSensor = lib.mkOption {
      type = lib.types.str;
      default = "sensor.flume_sensor_sierra_oaks_current";
      description = "Flume entity reporting gal/min instantaneous flow.";
    };

    domesticHotFlowSensor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "sensor.water_heater_ch1_ch1_unit1_hot_water_flow";
      description = ''
        Optional indoor hot-water flow sensor (gal/min). Setting to null
        disables the domestic_hot category entirely.
      '';
    };

    autofill = {
      gpmMin = lib.mkOption { type = lib.types.float; default = 3.0; };
      gpmMax = lib.mkOption { type = lib.types.float; default = 5.0; };
      windowMinutes = lib.mkOption { type = lib.types.int; default = 10; };
      minMinutesInRange = lib.mkOption { type = lib.types.int; default = 9; };
      enforceMeanCheck = lib.mkOption { type = lib.types.bool; default = true; };
    };

    cycles = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "daily" "weekly" "monthly" ]);
      default = [ "daily" "weekly" "monthly" ];
    };

    weekStart = lib.mkOption {
      type = lib.types.enum [ "monday" "sunday" ];
      default = "monday";
    };

    aggregateDropToleranceGal = lib.mkOption {
      type = lib.types.float;
      default = 5.0;
      description = "Gal-drop tolerance for the aggregate irrigation sum template.";
    };

    zones = lib.mkOption {
      type = lib.types.listOf zoneSubmodule;
      default = [];
      example = [
        { slug = "front_yard"; name = "Front Yard"; type = "spray"; }
        { slug = "drip_front_left"; name = "Drip Front Left"; type = "drip"; }
      ];
    };

    packageOutputPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hass/packages/water_attribution.yaml";
      description = "Where to materialize the generated package YAML.";
    };

    zonesJsonOutputPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/flume-autofill/zones.json";
      description = "Where to materialize the canonical zones.json for Phase 2/3.";
    };
  };

  # config block populated in Task 5+
  config = lib.mkIf cfg.enable {
    # placeholder
  };
}
