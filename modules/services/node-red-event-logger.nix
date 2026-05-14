{
  config,
  pkgs,
  lib,
  ...
}:

let
  schemaSql = ../../config/node-red-event-logger/schema.sql;
in
{
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
