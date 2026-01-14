{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nagios-daily-report;

  # Python script for generating the report
  reportScript = ./nagios-daily-report-script.py;

  # Wrapper script that sets environment variables and runs the Python script
  reportWrapper = pkgs.writeShellScript "nagios-daily-report-wrapper.sh" ''
    export STATUS_FILE="${cfg.statusFile}"
    export LOG_FILE="${cfg.logFile}"
    export SMTP_HOST="${cfg.smtpHost}"
    export SMTP_PORT="${toString cfg.smtpPort}"
    export FROM_EMAIL="${cfg.fromEmail}"
    export TO_EMAIL="${cfg.toEmail}"

    ${pkgs.python3}/bin/python3 ${reportScript}
  '';

in
{
  options.services.nagios-daily-report = {
    enable = mkEnableOption "Nagios daily health report via email";

    toEmail = mkOption {
      type = types.str;
      default = "johnw@vulcan.lan";
      description = "Email address to send the daily report to";
    };

    fromEmail = mkOption {
      type = types.str;
      default = "nagios@vulcan.lan";
      description = "From email address for the report";
    };

    smtpHost = mkOption {
      type = types.str;
      default = "localhost";
      description = "SMTP server hostname";
    };

    smtpPort = mkOption {
      type = types.port;
      default = 25;
      description = "SMTP server port";
    };

    statusFile = mkOption {
      type = types.str;
      default = "/var/lib/nagios/status.dat";
      description = "Path to Nagios status.dat file";
    };

    logFile = mkOption {
      type = types.str;
      default = "/var/log/nagios/nagios.log";
      description = "Path to Nagios log file";
    };

    schedule = mkOption {
      type = types.str;
      default = "08:00";
      description = "Time to send daily report (systemd calendar format)";
    };
  };

  config = mkIf cfg.enable {
    # Systemd service for generating and sending the report
    systemd.services.nagios-daily-report = {
      description = "Generate and email Nagios daily health report";

      serviceConfig = {
        Type = "oneshot";
        User = "nagios";
        Group = "nagios";
        ExecStart = "${reportWrapper}";
      };

      # Ensure Nagios is running and has data
      after = [ "nagios.service" ];
      wants = [ "nagios.service" ];
    };

    # Systemd timer to run daily at configured time
    systemd.timers.nagios-daily-report = {
      description = "Timer for Nagios daily health report";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
    };
  };
}
