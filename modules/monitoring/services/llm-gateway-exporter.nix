{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  exporter = pkgs.writers.writePython3Bin "llm-gateway-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/llm-gateway-exporter.py);
in
{
  # Does the LLM gateway actually WORK? Nothing else here asks.
  #
  # On 2026-09-09 an org-mode lookup through Hermes failed with a 502 and no alert
  # fired. Hermes' health check reported api_server_ok=1 throughout, correctly by its
  # own definition: all 21 hermes_* metrics ask "is Hermes up?" -- api server, Discord
  # heartbeat, extract worker, memory/Qdrant, VM uptime -- and none ask "does a tool
  # call work?".
  #
  # The failing path is longer than it looks:
  #     Hermes -> org-db (stdio MCP) -> org_search -> `org db search`
  #            -> LLM gateway :4000 -> hera's embedding model
  # org_sql reaches PostgreSQL directly, but org_search makes an HTTP call to the
  # gateway for embeddings, so a gateway with no live upstream reaches the user as a
  # 502. Verified at the time: NO blackbox target touched :4000, embeddings were not
  # probed at all, and the only mention of the gateway in any rule was advice text
  # inside a self-heal alert -- which fires when the self-heal daemon is escalating,
  # not when a user's tool call fails.
  #
  # That is a whole dependency tier, on another host, feeding all eight of Hermes' MCP
  # servers, with no coverage. This closes it.
  #
  # WHY AN EMBEDDINGS CALL AND NOT JUST REACHABILITY: the gateway answers /v1/models
  # from its own state, so it stays "up" while having no live upstream for an actual
  # inference request. Reachability alone would NOT have caught this incident. See the
  # script docstring for why it is embeddings rather than completions (GPU cost on a
  # contention-sensitive shared host).
  systemd.services.llm-gateway-exporter = {
    description = "Probe the LLM gateway's reachability, embeddings and model roster";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      # No privilege needed: loopback HTTP plus a world-readable /etc/models.json.
      # DynamicUser is still avoided because textfileDir is mode 1777 (sticky), so a
      # rotating uid cannot rename(2) over the .prom left by the previous run.
      User = "root";
      Group = "root";
      ExecStart = "${lib.getExe exporter}";

      # Above the script's own worst case (15s models + 60s embeddings) so it always
      # gets to write its metrics. A unit killed by systemd would leave the PREVIOUS
      # run's .prom in place and the failure would read as success until staleness
      # caught up -- the exact silent-green shape this exporter exists to detect.
      TimeoutStartSec = "3m";

      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      # Loopback only; it never leaves the host.
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
    };
  };

  systemd.timers.llm-gateway-exporter = {
    description = "Timer for the LLM gateway probe";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # HOURLY. The condition is not a latch -- a gateway can lose and regain its
      # upstream within a maintenance window, which is exactly what happened on
      # 2026-09-09 when oMLX was restarted on hera -- so detection latency matters
      # here in a way it does not for the deploy canary. Cost is small: the measured
      # embeddings probe was 4.8s on a three-character input, and /v1/models 0.02s.
      #
      # Not faster than hourly on purpose: the upstream is a shared, contention-
      # sensitive host, and a probe that adds load to the thing it is watching is
      # worse than a slightly later alert.
      OnBootSec = "8m";
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
