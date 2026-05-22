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

  # ---- YAML generation helpers ----

  # Render a single python-like float so YAML is readable.
  yamlFloat = f: builtins.toString f;

  yamlBool = b: if b then "true" else "false";

  autofillRangeYaml = ''
    # ─── Pool Autofill — pattern-based detection ─────────────────────────────
    template:
      - binary_sensor:
          - name: "Flume GPM in Autofill Range"
            unique_id: flume_gpm_in_autofill_range
            state: >
              {% set gpm = states('${cfg.flumeCurrentSensor}') | float(-1) %}
              {{ ${yamlFloat cfg.autofill.gpmMin} <= gpm <= ${yamlFloat cfg.autofill.gpmMax} }}
            availability: >
              {{ states('${cfg.flumeCurrentSensor}') not in ['unknown','unavailable'] }}
            attributes:
              generation: water_attribution_v1

    sensor:
      - platform: history_stats
        name: "Flume Minutes in Autofill Range ${toString cfg.autofill.windowMinutes}m"
        unique_id: flume_minutes_in_autofill_range_${toString cfg.autofill.windowMinutes}m
        entity_id: binary_sensor.flume_gpm_in_autofill_range
        state: "on"
        type: time
        duration:
          minutes: ${toString cfg.autofill.windowMinutes}
        end: "{{ now() }}"

      - platform: statistics
        name: "Flume GPM ${toString cfg.autofill.windowMinutes}m Mean"
        unique_id: flume_gpm_${toString cfg.autofill.windowMinutes}m_mean
        entity_id: ${cfg.flumeCurrentSensor}
        state_characteristic: mean
        max_age:
          minutes: ${toString cfg.autofill.windowMinutes}
        sampling_size: 50
  '';

  poolAutofillActiveYaml = ''
    template:
      - binary_sensor:
          - name: "Pool Autofill Active"
            unique_id: pool_autofill_active
            state: >
              {% set mins = (states('sensor.flume_minutes_in_autofill_range_${toString cfg.autofill.windowMinutes}m') | float(0)) * 60 %}
              {% set m = states('sensor.flume_gpm_${toString cfg.autofill.windowMinutes}m_mean') | float(-1) %}
              {{ mins >= ${toString cfg.autofill.minMinutesInRange}
                 ${lib.optionalString cfg.autofill.enforceMeanCheck
                     "and ${yamlFloat cfg.autofill.gpmMin} <= m <= ${yamlFloat cfg.autofill.gpmMax}"} }}
            delay_off:
              minutes: 1
            attributes:
              water_category: autofill
              generation: water_attribution_v1
  '';

  poolAutofillGatedGpmYaml = ''
    template:
      - sensor:
          - name: "Water Pool Autofill Gated GPM"
            unique_id: water_pool_autofill_gpm_gated
            unit_of_measurement: "gal/min"
            state: >
              {% if is_state('binary_sensor.pool_autofill_active', 'on') %}
                {{ states('${cfg.flumeCurrentSensor}') | float(0) }}
              {% else %}
                0
              {% endif %}
            availability: >
              {{ states('binary_sensor.pool_autofill_active') not in ['unknown','unavailable']
                 and states('${cfg.flumeCurrentSensor}') not in ['unknown','unavailable'] }}
            attributes:
              water_category: autofill
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water Pool Autofill Total"
        unique_id: water_pool_autofill_total
        source: sensor.water_pool_autofill_gpm_gated
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';

  domesticHotYaml = lib.optionalString (cfg.domesticHotFlowSensor != null) ''
    template:
      - sensor:
          - name: "Water Domestic Hot GPM"
            unique_id: water_domestic_hot_gpm
            unit_of_measurement: "gal/min"
            state: >
              {{ states('${cfg.domesticHotFlowSensor}') | float(0) }}
            availability: >
              {{ states('${cfg.domesticHotFlowSensor}') not in ['unknown','unavailable'] }}
            attributes:
              water_category: domestic_hot
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water Domestic Hot Total"
        unique_id: water_domestic_hot_total
        source: sensor.water_domestic_hot_gpm
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';

  perZoneGatedYaml = z: ''
    template:
      - sensor:
          - name: "Water ${z.name} Gated GPM"
            unique_id: water_${z.slug}_gpm_gated
            unit_of_measurement: "gal/min"
            state: >
              {% if is_state('valve.sprinkler_control_${z.slug}_zone', 'open') %}
                {{ states('${cfg.flumeCurrentSensor}') | float(0) }}
              {% else %}
                0
              {% endif %}
            availability: >
              {{ states('valve.sprinkler_control_${z.slug}_zone') not in ['unknown','unavailable']
                 and states('${cfg.flumeCurrentSensor}') not in ['unknown','unavailable'] }}
            attributes:
              water_category: irrigation
              zone_slug: ${z.slug}
              ${lib.optionalString (z.type != null) "zone_type: ${z.type}"}
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water ${z.name} Total"
        unique_id: water_${z.slug}_total
        source: sensor.water_${z.slug}_gpm_gated
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';

  zonesIterationYaml = lib.concatMapStringsSep "\n" perZoneGatedYaml cfg.zones;

  # Aggregate irrigation total (sum of zones, with drop tolerance)
  zoneTotalsList = lib.concatMapStringsSep ", "
    (z: "'sensor.water_${z.slug}_total'") cfg.zones;

  aggregateIrrigationYaml = ''
    template:
      - sensor:
          - name: "Water Irrigation Total"
            unique_id: water_irrigation_total
            unit_of_measurement: "gal"
            device_class: water
            state_class: total_increasing
            state: >
              {% set zones = [ ${zoneTotalsList} ] %}
              {% set s = zones | map('states') | map('float', 0) | sum %}
              {% set last = states('sensor.water_irrigation_total') | float(0) %}
              {% set tol = ${yamlFloat cfg.aggregateDropToleranceGal} %}
              {{ (([s, last] | max | round(3)) if ((last - s) < tol) else (s | round(3))) }}
            availability: >
              {% set zones = [ ${zoneTotalsList} ] %}
              {{ zones | map('states') | reject('in', ['unknown','unavailable']) | list | length == zones | length }}
            attributes:
              water_category: irrigation
              generation: water_attribution_v1
  '';

  # Convenience binary_sensor: any irrigation zone open right now.
  # Used by future NR consumer flows; also a clean signal for Grafana annotations.
  zoneValveList = lib.concatMapStringsSep ", "
    (z: "'valve.sprinkler_control_${z.slug}_zone'") cfg.zones;

  irrigationActiveYaml = ''
    template:
      - binary_sensor:
          - name: "Irrigation Active"
            unique_id: irrigation_active
            state: >
              {% set valves = [ ${zoneValveList} ] %}
              {{ valves | map('states') | select('eq', 'open') | list | length > 0 }}
            availability: >
              {% set valves = [ ${zoneValveList} ] %}
              {{ valves | map('states') | reject('in', ['unknown','unavailable']) | list | length > 0 }}
            attributes:
              water_category: irrigation
              generation: water_attribution_v1
  '';

  # Gated-GPM list for the "other" residual subtraction
  zoneGatedList = lib.concatMapStringsSep ", "
    (z: "'sensor.water_${z.slug}_gpm_gated'") cfg.zones;

  hasHot = cfg.domesticHotFlowSensor != null;

  otherResidualYaml = ''
    template:
      - sensor:
          - name: "Water Other GPM"
            unique_id: water_other_gpm
            unit_of_measurement: "gal/min"
            state: >
              {% set total = states('${cfg.flumeCurrentSensor}') | float(0) %}
              {% set autofill = states('sensor.water_pool_autofill_gpm_gated') | float(0) %}
              ${lib.optionalString hasHot "{% set hot = states('sensor.water_domestic_hot_gpm') | float(0) %}"}
              {% set zones = [ ${zoneGatedList} ] %}
              {% set irrigation = zones | map('states') | map('float', 0) | sum %}
              {% set residual = total - autofill ${lib.optionalString hasHot "- hot"} - irrigation %}
              {{ [residual, 0] | max | round(3) }}
            attributes:
              water_category: other
              generation: water_attribution_v1

    sensor:
      - platform: integration
        name: "Water Other Total"
        unique_id: water_other_total
        source: sensor.water_other_gpm
        method: left
        unit_time: min
        unit_prefix: ""
        round: 3
  '';

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

  # config block populated in Task 8
  config = lib.mkIf cfg.enable {
    # placeholder — full materialization added in Task 8
  };

  # Verification helper: surface the generated YAML text so flake/dev tools
  # can inspect what the module would produce. Not used at runtime.
  _module.args._yamlPreview = pkgs.writeText "water_attribution_preview.yaml" ''
    ${autofillRangeYaml}

    ${poolAutofillActiveYaml}

    ${poolAutofillGatedGpmYaml}

    ${domesticHotYaml}

    ${zonesIterationYaml}

    ${irrigationActiveYaml}

    ${aggregateIrrigationYaml}

    ${otherResidualYaml}
  '';
}
