# Discord round-trip canary — mutual cross-probing.
#
# Actively verifies Discord's inbound MESSAGE_CREATE -> agent dispatch ->
# reply pipeline, the one leg no other probe touches (2026-07-15 silent
# Discord-zombie incident; see scripts/discord_canary.py and
# docs/DISCORD_CANARY_SETUP.md).
#
# Design (2026-07-15): instead of a dedicated probe bot, the two agents probe
# EACH OTHER, reusing their existing Discord bot tokens (no new secrets):
#   probes.hermes  : @Claw (OpenClaw) posts -> Hermes replies  -> hermes_discord_canary_*
#   probes.openclaw: Hermes posts        -> @Claw replies       -> openclaw_discord_canary_*
# Accepted blind spot: if BOTH gateways die simultaneously, neither reports.
#
# Each probe is one oneshot service + timer. Token source per probe is either
# a raw token file (tokenFile, e.g. openclaw/discord-token) or an
# EnvironmentFile that defines DISCORD_BOT_TOKEN (envFile, e.g. hermes/env).

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.discordCanary;

  script = pkgs.writers.writePython3Bin "discord-canary" {
    flakeIgnore = [
      "E501" # long doc/JSON lines
      "W503"
      "E265"
    ];
  } (builtins.readFile ../../../scripts/discord_canary.py);

  probeOpts =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this Discord canary direction";
        channelId = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Discord channel id (snowflake) both bots can read+send in.";
        };
        targetUserId = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "The TARGET bot's Discord user id (whose reply proves the round-trip).";
        };
        targetName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Cosmetic name for the target (used in the probe message + journal).";
        };
        metricName = lib.mkOption {
          type = lib.types.str;
          default = "${name}_discord_canary";
          description = "Prometheus metric base name, e.g. hermes_discord_canary.";
        };
        tokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to a raw bot-token file (loaded via LoadCredential). Mutually exclusive with envFile.";
        };
        envFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to an EnvironmentFile defining DISCORD_BOT_TOKEN. Mutually exclusive with tokenFile.";
        };
        intervalSeconds = lib.mkOption {
          type = lib.types.int;
          default = 300;
          description = "Probe cadence in seconds (default 5 min).";
        };
        timeoutSeconds = lib.mkOption {
          type = lib.types.int;
          default = 90;
          description = "Seconds to wait for the target's reply before scoring failure.";
        };
      };
    };

  enabled = lib.filterAttrs (_: p: p.enable) cfg.probes;

  mkService =
    name: p:
    lib.nameValuePair "discord-canary-${name}" {
      description = "Discord round-trip canary: probe ${p.targetName}";
      after = [
        "microvm@hermes.service"
        "microvm@openclaw.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      environment = {
        CANARY_CHANNEL_ID = p.channelId;
        CANARY_TARGET_USER_ID = p.targetUserId;
        CANARY_TARGET_NAME = p.targetName;
        CANARY_METRIC_NAME = p.metricName;
        CANARY_TIMEOUT = toString p.timeoutSeconds;
      }
      // lib.optionalAttrs (p.tokenFile != null) {
        # LoadCredential exposes the raw token under $CREDENTIALS_DIRECTORY.
        CANARY_BOT_TOKEN_FILE = "%d/token";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "hermes-mcp";
        Group = "hermes-mcp";
        ExecStart = "${script}/bin/discord-canary";
        TimeoutStartSec = "240s";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SuccessExitStatus = [
          0
          1
        ];
      }
      // lib.optionalAttrs (p.tokenFile != null) {
        LoadCredential = [ "token:${p.tokenFile}" ];
      }
      // lib.optionalAttrs (p.envFile != null) {
        EnvironmentFile = p.envFile;
      };
    };

  mkTimer =
    name: p:
    lib.nameValuePair "discord-canary-${name}" {
      description = "Discord round-trip canary timer: ${p.targetName}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # OnActiveSec, NOT OnBootSec. OnBootSec is relative to BOOT, so a timer
        # first created by a `nixos-rebuild switch` on a long-uptime host has its
        # only anchor already far in the past and never fires -- and
        # OnUnitActiveSec cannot rescue it, because that anchors on the last
        # activation of the *service*, which has never run. The timer sits in
        # ActiveState=active/SubState=elapsed with an EMPTY NextElapse forever,
        # which looks healthy in `systemctl status`.
        #
        # That is not theoretical: discord-canary-hermes.timer was created by a
        # switch on 2026-07-30 at 10:15 against a 2026-07-03 boot, so its
        # OnBootSec=3min resolved to 27 days earlier and the hermes direction was
        # dead from birth. Its openclaw twin only worked because the service had
        # been started by hand, which gave OnUnitActiveSec an anchor.
        #
        # OnActiveSec is relative to the TIMER's own activation, so it arms on a
        # switch and on a boot alike. (Persistent= was dropped here: it only
        # affects OnCalendar= timers, so it was always a no-op.)
        #
        # ACCEPTED COST: systemd fires at the minimum of the enabled values, so
        # every switch that restarts this timer schedules a probe 3 min later
        # regardless of when the canary last ran. OnBootSec did not do that. On a
        # switch-heavy day that exceeds the 900s cadence intervalSeconds was
        # retuned to (to hold #interconnect traffic at 384 msgs/day rather than
        # 1,152), in a channel granted on the condition it stays clean. Accepted
        # because the alternative is a timer that silently never fires at all; each
        # probe still deletes its own message, and OpenClawDiscordCanaryStale
        # tolerates one missed run either way.
        OnActiveSec = "3min";
        OnUnitActiveSec = "${toString p.intervalSeconds}s";
        RandomizedDelaySec = "20s";
        AccuracySec = "10s";
        Unit = "discord-canary-${name}.service";
      };
    };
in
{
  options.services.discordCanary.probes = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule probeOpts);
    default = { };
    description = "Named Discord round-trip canary probes (one per direction).";
  };

  config = lib.mkIf (enabled != { }) {
    assertions = lib.mapAttrsToList (name: p: {
      assertion = p.channelId != "" && p.targetUserId != "" && (p.tokenFile != null || p.envFile != null);
      message = "services.discordCanary.probes.${name} needs channelId, targetUserId, and exactly one of tokenFile/envFile (see docs/DISCORD_CANARY_SETUP.md).";
    }) enabled;

    systemd.services = lib.mapAttrs' mkService enabled;
    systemd.timers = lib.mapAttrs' mkTimer enabled;
  };
}
