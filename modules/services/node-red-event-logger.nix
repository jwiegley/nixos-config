{
  config,
  pkgs,
  lib,
  ...
}:

let
  pluginSrc = pkgs.stdenv.mkDerivation {
    name = "node-red-event-logger";
    src = ../../config/node-red-event-logger;
    installPhase = ''
      mkdir -p $out
      cp $src/package.json $src/index.js $out/
    '';
  };
  pluginDest = "/var/lib/node-red/node_modules/node-red-event-logger";
  schemaSql = ../../config/node-red-event-logger/schema.sql;
  rotateSql = ../../config/node-red-event-logger/rotate.sql;
in
{
  # Install the plugin via a copy (not a symlink). Why: Node.js's resolver
  # calls realpath() before module lookup, so a /nix/store symlink would
  # cause require('pg') to search /nix/store/...-node-red-event-logger/node_modules
  # — where pg does not exist. With a real file at /var/lib/node-red/node_modules/
  # node-red-event-logger/index.js, the resolver walks up one level and finds
  # /var/lib/node-red/node_modules/pg (transitive of node-red-contrib-postgresql).
  # restartTriggers on this service re-runs the copy when pluginSrc changes.
  systemd.services.node-red-event-logger-install = {
    description = "Install Node-RED event-logger plugin into userDir/node_modules";
    before = [ "node-red.service" ];
    wantedBy = [ "node-red.service" ];
    restartTriggers = [ pluginSrc ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/rm -rf ${pluginDest}
      ${pkgs.coreutils}/bin/mkdir -p ${pluginDest}
      ${pkgs.coreutils}/bin/cp ${pluginSrc}/package.json ${pluginSrc}/index.js ${pluginDest}/
      ${pkgs.coreutils}/bin/chown -R node-red:node-red ${pluginDest}
      ${pkgs.coreutils}/bin/chmod 0644 ${pluginDest}/package.json ${pluginDest}/index.js
    '';
  };

  systemd.services.node-red.restartTriggers = [ pluginSrc ];

  # Make modules installed into Node-RED's userDir resolvable from settings.js
  # (loaded out of /nix/store by node-red) and from any other code path whose
  # caller location isn't under /var/lib/node-red. Without this, settings.js's
  # `require('pg')` for the audit handler fails because Node walks up from
  # /nix/store, not /var/lib/node-red.
  systemd.services.node-red.environment.NODE_PATH = "/var/lib/node-red/node_modules";

  systemd.services.node-red-event-logger-schema = {
    description = "Apply Node-RED event-logger schema migrations";
    # postgresql-setup runs ensureUsers (creates the `grafana` role). Schema
    # SQL references that role, so we must wait for setup to complete.
    after = [
      "postgresql.service"
      "postgresql-setup.service"
    ];
    requires = [
      "postgresql.service"
      "postgresql-setup.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -d nodered_events -v ON_ERROR_STOP=1 -f ${schemaSql}
    '';
  };

  systemd.services.node-red-event-logger-rotate = {
    description = "Rotate Node-RED event log partitions (create next month, drop >30d)";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -d nodered_events -v ON_ERROR_STOP=1 -f ${rotateSql}
    '';
  };

  systemd.timers.node-red-event-logger-rotate = {
    description = "Daily Node-RED event log rotation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
    };
  };
}
