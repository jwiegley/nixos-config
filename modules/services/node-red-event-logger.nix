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

  systemd.services.node-red-event-logger-schema = {
    description = "Apply Node-RED event-logger schema migrations";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
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
}
