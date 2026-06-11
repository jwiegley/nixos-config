# drafts-mcp: host-side SSE bridge to the Drafts.app MCP server on hera.
#
# Bridges a remote *stdio* MCP server (`drafts-mcp-server`, packaged on
# hera at /etc/profiles/per-user/johnw/bin/drafts-mcp-server) to a loopback
# *SSE* endpoint on 127.0.0.1:9082. mcp-proxy 0.10.0 runs in server mode and
# spawns ONE long-lived child for its entire lifetime: drafts-tool-filter,
# which in turn execs a single ssh child to hera. That ssh execs
# drafts-mcp-server via an authorized_keys forced-command (the remote command
# arg is intentionally omitted — the forced-command pins the binary and
# ignores SSH_ORIGINAL_COMMAND).
#
# OpenClaw (10.99.0.2) and Hermes (10.99.1.2) reach 127.0.0.1:9082 via the
# two-stage DNAT chain (openclaw-microvm.nix / hermes-microvm.nix dnatPorts).
# LAN hosts cannot reach it — the bind is loopback-only.
#
# Modeled on:
#   - modules/services/stock-trader.nix  (DynamicUser + LoadCredential +
#     RuntimeDirectory + writable HOME; stateless — no DB to own)
#   - modules/services/hermes-mcp.nix    (hardening block, after/wants,
#     sops restartUnits, RestrictAddressFamilies incl AF_INET)
#
# Recovery: a dead hera-side backend leaves mcp-proxy a silent green zombie
# (it catches the upstream error and keeps serving isError), so
# Restart=on-failure does NOT cover steady-state backend death. The
# load-bearing recovery is the health-probe-driven
# `systemctl restart drafts-mcp.service` in
# modules/services/drafts-mcp-self-heal.nix (added in the monitoring phase),
# driven by modules/monitoring/services/drafts-mcp-check.nix + alerts/drafts.yaml.
# Restart=on-failure + StartLimit here only handle hard crashes and bound
# boot crash-loops when hera is unreachable.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.drafts-mcp;

  # ---- PINNED hera host key (captured Phase 1: ssh-keyscan -t ed25519 hera.lan) ----
  # A store-path pin means a hera host-key change (e.g. macOS reinstall)
  # crash-loops the bridge until this line is updated and rebuilt — that is
  # intentional (fail closed). See the host-key-rotation runbook (spec §14).
  # The assertion below fails the build closed if this ever reverts to the
  # REPLACE_ME placeholder.
  pinnedKnownHosts = pkgs.writeText "drafts-mcp-known-hosts" ''
    hera.lan ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE92Mnzmx/CVS6GiGbJ1vGC0Sdf+D7/vSU/PN7f1Y1MV
  '';

  pinnedPlaceholderPresent = lib.hasInfix "REPLACE_ME" (builtins.readFile pinnedKnownHosts);

  # Write-tool filter shim — the sole OpenClaw enforcement point. Imported
  # directly; no overlay/flake entry (pkgs/drafts-tool-filter).
  draftsToolFilter = import ../../pkgs/drafts-tool-filter { inherit pkgs; };

  # ---- ssh-stdio wrapper ----
  # The single ssh child (spawned by the filter shim). NO remote-command arg:
  # hera's authorized_keys forced-command execs drafts-mcp-server and ignores
  # SSH_ORIGINAL_COMMAND. The private key is read from the per-unit
  # credentials directory populated by LoadCredential.
  #
  # CREDENTIAL PATH IS HARDCODED, NOT $CREDENTIALS_DIRECTORY: mcp-proxy spawns
  # its stdio backend (the filter shim, then this wrapper) through the MCP
  # Python SDK's stdio_client, which by default scrubs the child env down to
  # get_default_environment()'s allowlist (HOME, LOGNAME, PATH, SHELL, TERM,
  # USER on POSIX). $CREDENTIALS_DIRECTORY is NOT on that list, so it expands
  # to "" here and ssh sees `-i /hera-ssh-key` → "Identity file not
  # accessible" → publickey auth fails (and mcp-proxy keeps serving isError as
  # a silent green zombie). The credentials dir name is the stable, documented
  # systemd path `/run/credentials/<unit>/`, so we reference the key there
  # directly instead of relying on the stripped env var.
  #   -T                       : no PTY (forced-command + clean stdio)
  #   IdentitiesOnly=yes       : use ONLY the -i key, ignore agent/defaults
  #   BatchMode=yes            : never prompt (fail fast in a unit)
  #   StrictHostKeyChecking=yes: refuse unknown/changed host keys
  #   UserKnownHostsFile=<pin> : trust ONLY the pinned hera key
  #   GlobalKnownHostsFile=/dev/null : ignore /etc/ssh known_hosts
  #   ConnectTimeout=10        : bound the TCP/auth handshake
  #   ServerAliveInterval=30 / ServerAliveCountMax=3 : detect a dead peer
  #                              within ~90s so the child exits (then the
  #                              probe-driven restart can recover).
  sshWrapper = pkgs.writeShellScript "drafts-mcp-ssh" ''
    exec ${pkgs.openssh}/bin/ssh -T \
      -i /run/credentials/drafts-mcp.service/hera-ssh-key \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile=${pinnedKnownHosts} \
      -o GlobalKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      johnw@hera.lan
  '';
in
{
  options.services.drafts-mcp = {
    enable = lib.mkEnableOption "the drafts-mcp Drafts.app(hera) SSE bridge";

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Bind address for the SSE endpoint. The default 127.0.0.1 keeps the
        bridge unreachable from the LAN; OpenClaw and Hermes microVMs reach it
        via the two-stage DNAT chain (openclaw-microvm.nix / hermes-microvm.nix).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9082;
      description = ''
        TCP port for the SSE endpoint. 9082 is recorded as a single loopback
        line in docs/ports.txt; re-verify it is free against a live `ss -ltnp`
        on vulcan before first switch.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Fail closed at eval until the real Phase-1 hera host key replaces the
    # placeholder. (writeText with the placeholder body builds fine on its
    # own, so without this assertion the service would build and then
    # crash-loop on StrictHostKeyChecking at runtime.)
    assertions = [
      {
        assertion = !pinnedPlaceholderPresent;
        message = ''
          services.drafts-mcp.enable is true but the pinned hera known_hosts
          in modules/services/drafts-mcp.nix still contains the REPLACE_ME
          placeholder. Capture the real key with
          `ssh-keyscan -t ed25519 hera.lan` and paste it into pinnedKnownHosts
          before enabling (land it in the SAME commit as the enable flag).
        '';
      }
    ];

    # Dedicated ed25519 private key authorizing the forced-command on hera.
    # owner johnw, mode 0400 — dual-use by design:
    #   * the drafts-mcp bridge service reads it via LoadCredential, which
    #     systemd performs as root (PID 1) BEFORE the DynamicUser switch, so
    #     root-readability is all the service itself needs;
    #   * the host Claude Code operator path (claude-vulcan / mcp/drafts-hera.yaml)
    #     reads it DIRECTLY as johnw via `ssh -i /run/secrets/drafts/...`
    #     — vulcan has no local YubiKey, so a file-based key is required there too.
    # Both authenticate the SAME forced-command key (pinned to drafts-mcp-server).
    # restartUnits cuts the service onto a rotated key on rebuild.
    sops.secrets."drafts/hera-ssh-private-key" = {
      owner = "johnw";
      mode = "0400";
      restartUnits = [ "drafts-mcp.service" ];
    };

    systemd.services.drafts-mcp = {
      description = "Drafts.app (hera) MCP SSE bridge";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        # Bound boot crash-loops if hera is unreachable. Verified shape:
        # litellm.nix:89-94 puts these under unitConfig (NOT serviceConfig).
        StartLimitIntervalSec = "300";
        StartLimitBurst = "5";
      };

      environment = {
        # ProtectHome=true makes /home unavailable; ssh still wants a writable
        # HOME for ~/.ssh scratch. %t = the runtime root (/run); point HOME at
        # the private RuntimeDirectory so ssh never hits a read-only-home error.
        HOME = "%t/drafts-mcp";
      };

      serviceConfig = {
        Type = "exec";

        # Server mode: bind the SSE listener on loopback, spawn the filter
        # shim, which spawns the single ssh child. NO --transport (a
        # client-only no-op; server mode mounts /sse + /mcp unconditionally).
        # The shim denies drafts_run_action on this VM-facing SSE endpoint —
        # it is the SOLE OpenClaw enforcement point. (All other write tools
        # are allowed since the 2026-06-10 owner decision to give the agent
        # VMs the full read/write draft surface.)
        #
        # Chain: mcp-proxy ─► drafts-tool-filter ─► ssh johnw@hera.lan
        #        ─(forced-command)► drafts-mcp-server ─osascript► Drafts.app
        ExecStart = lib.escapeShellArgs [
          "${pkgs.mcp-proxy}/bin/mcp-proxy"
          "--host"
          cfg.host
          "--port"
          (toString cfg.port)
          "--"
          "${draftsToolFilter}/bin/drafts-tool-filter"
          "${sshWrapper}"
        ];

        # A dead backend is a silent zombie; on-failure only catches hard
        # crashes (probe-driven restart is the real recovery). ~30s avoids
        # tight boot crash-loops against a transiently-down hera.
        Restart = "on-failure";
        RestartSec = "30s";

        DynamicUser = true;

        # Private, writable HOME for ssh under /run (tmpfs). No StateDirectory
        # — the bridge is stateless.
        RuntimeDirectory = "drafts-mcp";
        RuntimeDirectoryMode = "0700";

        # Dedicated ssh private key, read-only in the unit namespace. The id
        # `hera-ssh-key` MUST match the basename the wrapper hardcodes at
        # /run/credentials/drafts-mcp.service/hera-ssh-key (it can't use
        # $CREDENTIALS_DIRECTORY — the MCP SDK strips it from the stdio child;
        # see the sshWrapper comment).
        LoadCredential = [
          "hera-ssh-key:${config.sops.secrets."drafts/hera-ssh-private-key".path}"
        ];

        # Hardening — cloned from hermes-mcp.nix:166-187 / stock-trader.nix:222-247.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        # ssh dials hera over the LAN — AF_INET is required.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        # mcp-proxy + the shim are Python (CPython needs W^X off).
        MemoryDenyWriteExecute = false;

        MemoryMax = "256M";
      };
    };
  };
}
