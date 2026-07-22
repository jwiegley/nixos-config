# Drafts MCP bridge transport health check.
#
# The scheduled probe verifies the host service, loopback SSE endpoint,
# persistent ssh child, hera forced command, and MCP server through
# initialize + tools/list. It deliberately sends no tools/call, so the timer
# cannot address, launch, reopen, or reveal Drafts.app.
#
# An explicit, untimed drafts-mcp-app-check.service adds one read-only
# drafts_list_workspaces call for operator-requested TCC/application
# diagnostics. Starting that unit may reveal Drafts.app on hera.
#
# Scheduled metrics:
#
#   * drafts_mcp_bridge_up
#   * drafts_mcp_sse_open_ok
#   * drafts_mcp_ssh_hera_ok
#   * drafts_mcp_check_last_run_timestamp_seconds
#
# Recovery remains an external systemctl restart of drafts-mcp.service driven
# by alerts/drafts.yaml and drafts-mcp-self-heal. Neither probe remediates.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.draftsMcpCheck;
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  probePython = pkgs.python3.withPackages (ps: [ ps.httpx ]);
  probeSource = ../../../scripts/drafts-mcp-check/drafts_mcp_check.py;

  healthScript = pkgs.writeShellScript "drafts-mcp-check" ''
    exec ${probePython}/bin/python3 ${probeSource} "$@"
  '';

  probeHardening = {
    Type = "oneshot";
    DynamicUser = true;
    TimeoutStartSec = "120s";
    ProtectSystem = "strict";
    ProtectHome = true;
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    LockPersonality = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
  };
in
{
  options.services.draftsMcpCheck = {
    enable = lib.mkEnableOption "Drafts MCP bridge transport health probe";
    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Transport polling interval in seconds.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.drafts-mcp-check = {
      description = "Drafts MCP bridge transport health probe (SSE, ssh to hera, MCP tools/list)";
      after = [
        "drafts-mcp.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      environment.DRAFTS_MCP_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";

      serviceConfig = probeHardening // {
        ExecStart = "${healthScript}";
        ReadWritePaths = [ textfileDir ];
      };
    };

    systemd.services.drafts-mcp-app-check = {
      description = "Manual Drafts MCP app/TCC check (contacts Drafts.app on hera and may reveal it)";
      after = [
        "drafts-mcp.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      environment.DRAFTS_MCP_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";

      serviceConfig = probeHardening // {
        ExecStart = "${healthScript} --app-check";
      };
    };

    systemd.timers.drafts-mcp-check = {
      description = "Timer for drafts-mcp transport check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        Unit = "drafts-mcp-check.service";
        AccuracySec = "15s";
      };
    };
  };
}
