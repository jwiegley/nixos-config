# modules/services/home-assistant-water-attribution.nix
#
# Single-source-of-truth NixOS module for water attribution. Generates an HA
# package file at /var/lib/hass/packages/water_attribution.yaml from the
# `zones` list, autofill thresholds, cycles, and detection knobs declared
# below.
#
# Implementation note — JSON-as-YAML:
# We build the entire package as a single Nix attrset and emit it via
# `builtins.toJSON`. JSON is a valid subset of YAML 1.2 (and HA's PyYAML
# loader accepts it), so this sidesteps the whitespace pitfalls of
# concatenating indented-string fragments. It also means every top-level
# integration (`template`, `sensor`, `utility_meter`, `binary_sensor`)
# appears exactly once, which is required — PyYAML silently drops all but
# the last value for duplicate top-level keys.
{
  config,
  lib,
  pkgs,
  ...
}:

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
        type = lib.types.nullOr (
          lib.types.enum [
            "spray"
            "drip"
          ]
        );
        default = null;
        description = "Sprinkler head type, used as InfluxDB tag";
      };
    };
  };

  hasHot = cfg.domesticHotFlowSensor != null;

  flumeSensor = cfg.flumeCurrentSensor;
  windowMin = toString cfg.autofill.windowMinutes;
  windowSuffix = "${windowMin}m";

  # Jinja literal arrays used by template state expressions.
  zoneTotalsLiteral = lib.concatMapStringsSep ", " (z: "'sensor.water_${z.slug}_total'") cfg.zones;
  zoneValveLiteral = lib.concatMapStringsSep ", " (
    z: "'valve.sprinkler_control_${z.slug}_zone'"
  ) cfg.zones;
  zoneGatedLiteral = lib.concatMapStringsSep ", " (z: "'sensor.water_${z.slug}_gated_gpm'") cfg.zones;

  # Drop any null-valued keys from a {key=value;} attrset. Used to omit the
  # optional `zone_type` attribute when a zone's type is null without leaving
  # behind a "zone_type: null" entry.
  dropNulls = a: lib.filterAttrs (_n: v: v != null) a;

  # ── template -> binary_sensor entries ─────────────────────────────────────

  flumeRangeBinarySensor = {
    name = "Flume GPM in Autofill Range";
    unique_id = "flume_gpm_in_autofill_range";
    state = ''
      {% set gpm = states('${flumeSensor}') | float(-1) %}
      {{ ${toString cfg.autofill.gpmMin} <= gpm <= ${toString cfg.autofill.gpmMax} }}
    '';
    availability = ''
      {{ states('${flumeSensor}') not in ['unknown','unavailable'] }}
    '';
    attributes = {
      generation = "water_attribution_v1";
    };
  };

  poolAutofillActiveBinarySensor = {
    name = "Pool Autofill Active";
    unique_id = "pool_autofill_active";
    state =
      let
        meanGuard = lib.optionalString cfg.autofill.enforceMeanCheck " and ${toString cfg.autofill.gpmMin} <= m <= ${toString cfg.autofill.gpmMax}";
      in
      ''
        {% set mins = (states('sensor.flume_minutes_in_autofill_range_${windowSuffix}') | float(0)) * 60 %}
        {% set m = states('sensor.flume_gpm_${windowSuffix}_mean') | float(-1) %}
        {{ mins >= ${toString cfg.autofill.minMinutesInRange}${meanGuard} }}
      '';
    delay_off = {
      minutes = 1;
    };
    attributes = {
      water_category = "autofill";
      generation = "water_attribution_v1";
    };
  };

  irrigationActiveBinarySensor = {
    name = "Irrigation Active";
    unique_id = "irrigation_active";
    state = ''
      {% set valves = [ ${zoneValveLiteral} ] %}
      {{ valves | map('states') | select('eq', 'open') | list | length > 0 }}
    '';
    availability = ''
      {% set valves = [ ${zoneValveLiteral} ] %}
      {{ valves | map('states') | reject('in', ['unknown','unavailable']) | list | length > 0 }}
    '';
    attributes = {
      water_category = "irrigation";
      generation = "water_attribution_v1";
    };
  };

  # ── template -> sensor entries ────────────────────────────────────────────

  poolAutofillGatedGpmSensor = {
    name = "Water Pool Autofill Gated GPM";
    # IMPORTANT: this unique_id was historically `water_pool_autofill_gpm_gated`,
    # which is what every existing HA entity registry row references. HA
    # uses the unique_id to bind the (immutable) entity_id; the entity_id
    # itself is `sensor.water_pool_autofill_gated_gpm` because HA slugifies
    # the `name` attribute, NOT the unique_id. The `source =` references
    # below use the slugified-name shape — that's the entity_id HA actually
    # exposes. Don't try to "align" unique_id with the entity_id, or HA
    # will register parallel `_2`-suffixed entities and orphan the existing
    # series + utility meters. See the Fix #1 commentary in this file's
    # history.
    unique_id = "water_pool_autofill_gpm_gated";
    unit_of_measurement = "gal/min";
    state = ''
      {% if is_state('binary_sensor.pool_autofill_active', 'on') %}
        {{ states('${flumeSensor}') | float(0) }}
      {% else %}
        0
      {% endif %}
    '';
    availability = ''
      {{ states('binary_sensor.pool_autofill_active') not in ['unknown','unavailable']
         and states('${flumeSensor}') not in ['unknown','unavailable'] }}
    '';
    attributes = {
      water_category = "autofill";
      generation = "water_attribution_v1";
    };
  };

  domesticHotGpmSensors = lib.optional hasHot {
    name = "Water Domestic Hot GPM";
    unique_id = "water_domestic_hot_gpm";
    unit_of_measurement = "gal/min";
    state = ''
      {{ states('${cfg.domesticHotFlowSensor}') | float(0) }}
    '';
    availability = ''
      {{ states('${cfg.domesticHotFlowSensor}') not in ['unknown','unavailable'] }}
    '';
    attributes = {
      water_category = "domestic_hot";
      generation = "water_attribution_v1";
    };
  };

  perZoneGatedSensor = z: {
    name = "Water ${z.name} Gated GPM";
    # See poolAutofillGatedGpmSensor: unique_id stays in the historical
    # `_gpm_gated` shape so HA reuses the existing entity_id binding
    # (`sensor.water_${z.slug}_gated_gpm`, slugified from the name).
    unique_id = "water_${z.slug}_gpm_gated";
    unit_of_measurement = "gal/min";
    state = ''
      {% if is_state('valve.sprinkler_control_${z.slug}_zone', 'open') %}
        {{ states('${flumeSensor}') | float(0) }}
      {% else %}
        0
      {% endif %}
    '';
    availability = ''
      {{ states('valve.sprinkler_control_${z.slug}_zone') not in ['unknown','unavailable']
         and states('${flumeSensor}') not in ['unknown','unavailable'] }}
    '';
    attributes = dropNulls {
      water_category = "irrigation";
      zone_slug = z.slug;
      zone_type = z.type; # may be null; dropped by dropNulls
      generation = "water_attribution_v1";
    };
  };

  aggregateIrrigationSensor = {
    name = "Water Irrigation Total";
    unique_id = "water_irrigation_total";
    unit_of_measurement = "gal";
    device_class = "water";
    state_class = "total_increasing";
    state = ''
      {% set zones = [ ${zoneTotalsLiteral} ] %}
      {% set s = zones | map('states') | map('float', 0) | sum %}
      {% set last = states('sensor.water_irrigation_total') | float(0) %}
      {% set tol = ${toString cfg.aggregateDropToleranceGal} %}
      {{ (([s, last] | max | round(3)) if ((last - s) < tol) else (s | round(3))) }}
    '';
    availability = ''
      {% set zones = [ ${zoneTotalsLiteral} ] %}
      {{ zones | map('states') | reject('in', ['unknown','unavailable']) | list | length == zones | length }}
    '';
    attributes = {
      water_category = "irrigation";
      generation = "water_attribution_v1";
    };
  };

  otherResidualSensor = {
    name = "Water Other GPM";
    unique_id = "water_other_gpm";
    unit_of_measurement = "gal/min";
    state =
      let
        hotLine = lib.optionalString hasHot "{% set hot = states('sensor.water_domestic_hot_gpm') | float(0) %}\n";
        hotSubtract = lib.optionalString hasHot " - hot";
      in
      ''
        {% set total = states('${flumeSensor}') | float(0) %}
        {% set autofill = states('sensor.water_pool_autofill_gated_gpm') | float(0) %}
        ${hotLine}{% set zones = [ ${zoneGatedLiteral} ] %}
        {% set irrigation = zones | map('states') | map('float', 0) | sum %}
        {% set residual = total - autofill${hotSubtract} - irrigation %}
        {{ [residual, 0] | max | round(3) }}
      '';
    attributes = {
      water_category = "other";
      generation = "water_attribution_v1";
    };
  };

  templateBlock = [
    {
      binary_sensor = [
        flumeRangeBinarySensor
        poolAutofillActiveBinarySensor
        irrigationActiveBinarySensor
      ];
    }
    {
      sensor = [
        poolAutofillGatedGpmSensor
      ]
      ++ domesticHotGpmSensors
      ++ (map perZoneGatedSensor cfg.zones)
      ++ [
        aggregateIrrigationSensor
        otherResidualSensor
      ];
    }
  ];

  # ── sensor: platform entries ──────────────────────────────────────────────

  historyStatsEntry = {
    platform = "history_stats";
    name = "Flume Minutes in Autofill Range ${windowSuffix}";
    unique_id = "flume_minutes_in_autofill_range_${windowSuffix}";
    entity_id = "binary_sensor.flume_gpm_in_autofill_range";
    state = "on";
    type = "time";
    duration = {
      minutes = cfg.autofill.windowMinutes;
    };
    end = "{{ now() }}";
  };

  statisticsEntry = {
    platform = "statistics";
    name = "Flume GPM ${windowSuffix} Mean";
    unique_id = "flume_gpm_${windowSuffix}_mean";
    entity_id = flumeSensor;
    state_characteristic = "mean";
    max_age = {
      minutes = cfg.autofill.windowMinutes;
    };
    sampling_size = 50;
  };

  # HA's `integration` platform rejects `unit_prefix: ""` even though the spec
  # in docs/ used that to mean "no prefix". The schema only accepts one of
  # ['G','M','T','k'] or None; the default IS None, so we omit the field.
  integrationEntry =
    {
      name,
      unique_id,
      source,
    }:
    {
      platform = "integration";
      inherit name unique_id source;
      method = "left";
      unit_time = "min";
      round = 3;
    };

  poolAutofillTotalEntry = integrationEntry {
    name = "Water Pool Autofill Total";
    unique_id = "water_pool_autofill_total";
    source = "sensor.water_pool_autofill_gated_gpm";
  };

  domesticHotTotalEntry = lib.optional hasHot (integrationEntry {
    name = "Water Domestic Hot Total";
    unique_id = "water_domestic_hot_total";
    source = "sensor.water_domestic_hot_gpm";
  });

  perZoneTotalEntry =
    z:
    integrationEntry {
      name = "Water ${z.name} Total";
      unique_id = "water_${z.slug}_total";
      source = "sensor.water_${z.slug}_gated_gpm";
    };

  otherTotalEntry = integrationEntry {
    name = "Water Other Total";
    unique_id = "water_other_total";
    source = "sensor.water_other_gpm";
  };

  sensorBlock = [
    historyStatsEntry
    statisticsEntry
    poolAutofillTotalEntry
  ]
  ++ domesticHotTotalEntry
  ++ (map perZoneTotalEntry cfg.zones)
  ++ [ otherTotalEntry ];

  # ── utility_meter ─────────────────────────────────────────────────────────

  weekOffsetDays = if cfg.weekStart == "monday" then 0 else 6;

  prettyCategory =
    source:
    let
      stripped = lib.replaceStrings [ "water_" "_total" ] [ "" "" ] source;
      titleCase =
        w:
        if w == "" then
          ""
        else
          lib.toUpper (builtins.substring 0 1 w) + builtins.substring 1 (builtins.stringLength w) w;
      words = lib.splitString "_" stripped;
    in
    "Water " + lib.concatStringsSep " " (map titleCase words);

  cycleTitle =
    cycle:
    lib.toUpper (builtins.substring 0 1 cycle)
    + builtins.substring 1 (builtins.stringLength cycle) cycle;

  utilityMeterEntry =
    source: cycle:
    let
      base = {
        source = "sensor.${source}";
        inherit cycle;
        name = "${prettyCategory source} ${cycleTitle cycle}";
      };
      withOffset =
        if cycle == "weekly" then
          base
          // {
            offset = {
              days = weekOffsetDays;
            };
          }
        else
          base;
    in
    {
      "${source}_${cycle}" = withOffset;
    };

  cumulativeSources = [
    "water_pool_autofill_total"
  ]
  ++ (lib.optional hasHot "water_domestic_hot_total")
  ++ (map (z: "water_${z.slug}_total") cfg.zones)
  ++ [
    "water_irrigation_total"
    "water_other_total"
  ];

  utilityMeterBlock = lib.foldl' (acc: x: acc // x) { } (
    lib.concatMap (source: map (cycle: utilityMeterEntry source cycle) cfg.cycles) cumulativeSources
  );

  # ── SQL fixture sensors (read v3 attributions from flume-data) ───────────
  #
  # Each fixture in the v3 classifier gets three sensors: today / this
  # week / this month. The sensors read `flume_minute_attributions`
  # directly via peer auth — no password, the `hass` Postgres role is
  # granted SELECT in modules/services/databases.nix.
  #
  # `scan_interval: 600` (10 min) is plenty given the underlying data
  # only refreshes on the 6-hour sync cadence.

  fixtures = [
    "irrigation_spray"
    "irrigation_drip"
    "irrigation_bubbler"
    "pool_autofill"
    "shower"
    "dishwasher"
    "sink_hot"
    "sink_cold"
    "clothes_washer_hot"
    "clothes_washer_cold"
    "toilet_flush"
    "fridge_event"
    "leak"
    "unknown"
  ];

  prettyFixture =
    f:
    let
      parts = lib.splitString "_" f;
      cap = s: (lib.toUpper (builtins.substring 0 1 s)) + (builtins.substring 1 (-1) s);
    in
    lib.concatStringsSep " " (map cap parts);

  # SQLAlchemy DSN form that works for peer auth via Unix socket.
  # The "hass" role gets peer access via `local flume-data hass peer`
  # in pg_hba.
  #
  # Note: the modern `sql:` integration uses a fixed 30s scan interval
  # internally and rejects per-entry `scan_interval`. That's overkill
  # for our 6-hour-cadence data, but the queries are cheap (indexed
  # date_trunc) so we accept the default.
  flumeDataDsn = "postgresql://hass@/flume-data?host=/run/postgresql";

  # PostgreSQL date_trunc on a timezone-aware now() gives the local
  # midnight / Monday / first-of-month boundary. We do this server-side
  # so the result is independent of where the HA process thinks "now"
  # is (HA's TZ config can drift from system TZ during upgrades).
  cycleBoundaryExpr =
    cycle:
    {
      daily = "date_trunc('day',   now() AT TIME ZONE 'America/Los_Angeles')";
      weekly = "date_trunc('week',  now() AT TIME ZONE 'America/Los_Angeles')";
      monthly = "date_trunc('month', now() AT TIME ZONE 'America/Los_Angeles')";
    }
    .${cycle};

  cycleSuffix = {
    daily = "today";
    weekly = "week";
    monthly = "month";
  };

  cycleLabel = {
    daily = "Today";
    weekly = "This Week";
    monthly = "This Month";
  };

  # Cycle-resetting sensors for dashboards / cards / automations. These
  # go to zero at midnight, Monday 00:00, or first-of-month and climb
  # back up across the cycle. `total_increasing` is the right state_class
  # for this pattern — HA detects the cycle-boundary drop-to-zero as a
  # known reset and continues the running total in its statistics engine.
  sqlFixtureSensor =
    fixture: cycle:
    let
      slug = "water_fixture_${fixture}_${cycleSuffix.${cycle}}";
    in
    {
      name = "Water Fixture ${prettyFixture fixture} ${cycleLabel.${cycle}}";
      unique_id = slug;
      db_url = flumeDataDsn;
      query = ''
        SELECT COALESCE(SUM(gpm), 0)::numeric(10,2) AS gal
        FROM flume_minute_attributions
        WHERE fixture = '${fixture}'
          AND ts >= ${cycleBoundaryExpr cycle};
      '';
      column = "gal";
      unit_of_measurement = "gal";
      device_class = "water";
      state_class = "total_increasing";
    };

  # Lifetime cumulative sensors for the HA Energy panel. These NEVER
  # reset — they sum every minute we've ever recorded for the fixture.
  # That makes them suitable as a "Water source" in the Energy panel,
  # where HA computes daily/weekly/monthly deltas itself.
  #
  # Add each one to Settings → Energy → Water Consumption to get the
  # per-fixture breakdown (analogous to the per-circuit electricity
  # breakdown). Mix-and-match: e.g., add pool, irrigation_spray,
  # irrigation_drip, shower, dishwasher, clothes_washer_* separately,
  # and combine the rest into a single "other indoor" view in your
  # dashboard.
  sqlFixtureLifetimeSensor = fixture: {
    name = "Water Fixture ${prettyFixture fixture} Lifetime";
    unique_id = "water_fixture_${fixture}_lifetime";
    db_url = flumeDataDsn;
    query = ''
      SELECT COALESCE(SUM(gpm), 0)::numeric(12,2) AS gal
      FROM flume_minute_attributions
      WHERE fixture = '${fixture}';
    '';
    column = "gal";
    unit_of_measurement = "gal";
    device_class = "water";
    state_class = "total_increasing";
  };

  fixtureSqlSensors =
    (lib.flatten (
      map (
        f:
        map (c: sqlFixtureSensor f c) [
          "daily"
          "weekly"
          "monthly"
        ]
      ) fixtures
    ))
    ++ (map sqlFixtureLifetimeSensor fixtures);

  # ── Assembled package YAML ───────────────────────────────────────────────
  #
  # We emit the entire package as JSON (a valid subset of YAML 1.2) prefixed
  # by a comment header. HA's PyYAML loader handles both JSON and the YAML
  # superset.
  packageData = {
    template = templateBlock;
    sensor = sensorBlock;
    utility_meter = utilityMeterBlock;
    sql = fixtureSqlSensors;
  };

  packageYamlFile = pkgs.writeText "water_attribution.yaml" ''
    # ─── Generated by modules/services/home-assistant-water-attribution.nix ──
    # DO NOT EDIT by hand. Update the Nix module and rebuild.
    # Emitted as JSON for whitespace-safe HA package loading (JSON ⊂ YAML 1.2).
    ${builtins.toJSON packageData}
  '';

  zonesJsonFile = pkgs.writeText "zones.json" (
    builtins.toJSON {
      flume_current_sensor = cfg.flumeCurrentSensor;
      domestic_hot_flow_sensor = cfg.domesticHotFlowSensor;
      autofill = {
        gpm_min = cfg.autofill.gpmMin;
        gpm_max = cfg.autofill.gpmMax;
        window_minutes = cfg.autofill.windowMinutes;
        min_minutes_in_range = cfg.autofill.minMinutesInRange;
        enforce_mean_check = cfg.autofill.enforceMeanCheck;
      };
      cycles = cfg.cycles;
      zones = map (z: { inherit (z) slug name type; }) cfg.zones;
      victoriametrics_url = "http://127.0.0.1:8428";
      ha_postgres_dsn = "postgresql:///hass";
    }
  );

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
      gpmMin = lib.mkOption {
        type = lib.types.float;
        default = 3.0;
      };
      gpmMax = lib.mkOption {
        type = lib.types.float;
        default = 5.0;
      };
      windowMinutes = lib.mkOption {
        type = lib.types.int;
        default = 10;
      };
      minMinutesInRange = lib.mkOption {
        type = lib.types.int;
        default = 9;
      };
      enforceMeanCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

    cycles = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "daily"
          "weekly"
          "monthly"
        ]
      );
      default = [
        "daily"
        "weekly"
        "monthly"
      ];
    };

    weekStart = lib.mkOption {
      type = lib.types.enum [
        "monday"
        "sunday"
      ];
      default = "monday";
    };

    aggregateDropToleranceGal = lib.mkOption {
      type = lib.types.float;
      default = 5.0;
      description = "Gal-drop tolerance for the aggregate irrigation sum template.";
    };

    zones = lib.mkOption {
      type = lib.types.listOf zoneSubmodule;
      default = [ ];
      example = [
        {
          slug = "front_yard";
          name = "Front Yard";
          type = "spray";
        }
        {
          slug = "drip_front_left";
          name = "Drip Front Left";
          type = "drip";
        }
      ];
    };

    packageOutputPath = lib.mkOption {
      # `lib.types.path` interns the value into the Nix store, which is
      # nonsense for a runtime output path (/var/lib/hass/...). The
      # activation script substitutes this string into an `install`
      # command, so `lib.types.str` is the right shape.
      type = lib.types.str;
      default = "/var/lib/hass/packages/water_attribution.yaml";
      description = "Where to materialize the generated package YAML.";
    };

    zonesJsonOutputPath = lib.mkOption {
      # See packageOutputPath: this is an `install` target, not a store path.
      type = lib.types.str;
      default = "/var/lib/flume-data/zones.json";
      description = "Where to materialize the canonical zones.json for Phase 2/3.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Shared user/group used by zones.json materialization here and by the
    # Phase 2/3 systemd services in modules/services/flume-data.nix.
    # Declared in this module so Phase 1 can deploy independently of Phase 2.
    # UID/GID pinned to the values the user was originally allocated as
    # `flume-autofill` (uid=905 gid=898). Preserves /var/lib/flume-data
    # file ownership through the 2026-05-23 flume-autofill → flume-data
    # rename; without this NixOS would allocate a fresh uid for the
    # "new" user and orphan every cached JSON / token / reports file.
    users.users.flume-data = {
      isSystemUser = true;
      uid = 905;
      group = "flume-data";
      home = "/var/lib/flume-data";
      createHome = true;
    };
    users.groups.flume-data = {
      gid = 898;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/flume-data 0750 flume-data flume-data -"
    ];

    # Materialize the generated YAML into the HA packages directory.
    # `install -m … -o … -g …` ensures an atomic swap on every rebuild.
    # The parent directory `/var/lib/flume-data` is created by the
    # tmpfiles entry above; `install` only writes the regular files.
    system.activationScripts.water-attribution-package = {
      text = ''
        install -d -m 755 -o hass -g hass /var/lib/hass/packages
        install -m 0644 -o hass -g hass \
          ${packageYamlFile} \
          ${toString cfg.packageOutputPath}
        install -m 0644 -o flume-data -g flume-data \
          ${zonesJsonFile} \
          ${toString cfg.zonesJsonOutputPath}
      '';
      deps = [
        "users"
        "groups"
      ];
    };

    # Restart HA when the generated content changes.
    systemd.services.home-assistant.restartTriggers = [
      packageYamlFile
      zonesJsonFile
    ];
  };
}
