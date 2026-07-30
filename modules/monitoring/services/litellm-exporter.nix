{
  config,
  lib,
  pkgs,
  ...
}:

let
  models = import ../../../models.nix;

  # Prometheus label set stamped on EVERY litellm_* sample this exporter emits.
  #
  # Defined ONCE here, and injected verbatim into both scripts below, because
  # the series identity has to be byte-identical across all FOUR emission
  # sites: the up-path, the HTTP-error path, the response-validation-failure
  # path, and the wrapper's last-resort `|| ...` fallback. If the down-state
  # carried a different label set from the up-state, litellm_availability
  # would resolve to two distinct series and LitellmBackendDown
  # (modules/monitoring/alerts/litellm.yaml) would silently stop matching the
  # moment the gateway actually broke.
  #
  # The model name is a LABEL rather than build-time text so that plain-YAML
  # alert rules can render it as {{ $labels.model }}. That is what allowed
  # litellm-availability-alerts.nix -- a second, parallel rule mechanism whose
  # only reason to be Nix was interpolating this model name into rule text --
  # to be retired in favour of alerts/litellm.yaml (see that file's header).
  labelSet = ''{model="${models.llm.primary.name}"}'';

  # Script that tests LiteLLM availability by making a simple query
  litellmHealthCheck = pkgs.writeShellScript "litellm-health-check" ''
    set -uo pipefail

    # Label set for every sample below -- see `labelSet` in the Nix let block.
    LABELS='${labelSet}'

    # Get API key from environment (use LITELLM_MASTER_KEY if available)
    API_KEY="''${LITELLM_API_KEY:-''${LITELLM_MASTER_KEY:-}}"
    if [ -z "$API_KEY" ]; then
      echo "ERROR: Neither LITELLM_API_KEY nor LITELLM_MASTER_KEY is set" >&2
      exit 1
    fi

    # Test query to ${models.llm.primary.name}
    # Retry once after 60s on failure to handle transient unavailability
    # (model loading on hera can take 1-3 minutes for large models).
    # Note: curl exit code 28 = timeout; captured via || to avoid set -e abort.
    HTTP_CODE="000"
    for attempt in 1 2; do
      RESPONSE=$(${pkgs.curl}/bin/curl -s -w "\n%{http_code}" -X POST \
        http://127.0.0.1:4000/v1/chat/completions \
        -H "x-api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{
          "model": "${models.llm.primary.name}",
          "messages": [{"role": "user", "content": "What is 2+2? Answer with only the number."}],
          "max_tokens": 10,
          "temperature": 0
        }' \
        --max-time 180) || true

      HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
      BODY=$(echo "$RESPONSE" | head -n-1)

      if [ "$HTTP_CODE" = "200" ]; then
        break
      elif [ "$attempt" -eq 1 ]; then
        sleep 60
      fi
    done

    # Check HTTP status
    if [ "$HTTP_CODE" != "200" ]; then
      echo "litellm_availability$LABELS 0"
      echo "litellm_response_time_seconds$LABELS 0"
      echo "# HTTP error: $HTTP_CODE (after 2 attempts)"
      exit 0
    fi

    # Check if response contains an answer
    # Try content field first, then reasoning_content field (for reasoning models)
    CONTENT=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.choices[0].message.content // ""')
    if [ -z "$CONTENT" ] || [ "$CONTENT" = "null" ]; then
      CONTENT=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.choices[0].message.reasoning_content // ""')
    fi

    # Check if we got a valid response structure (choices array exists)
    if echo "$BODY" | ${pkgs.jq}/bin/jq -e '.choices[0]' > /dev/null 2>&1; then
      # For reasoning models, just verify we got some content back
      # We don't strictly validate the answer is "4" since the model might reason differently
      if [ -n "$CONTENT" ] && [ "$CONTENT" != "null" ]; then
        echo "litellm_availability$LABELS 1"

        # Extract response time if available
        RESPONSE_TIME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.usage.total_time // 0')
        echo "litellm_response_time_seconds$LABELS $RESPONSE_TIME"

        echo "# Last successful query: $(date -Iseconds)"
        exit 0
      fi
    fi

    # If we got here, something failed
    echo "litellm_availability$LABELS 0"
    echo "litellm_response_time_seconds$LABELS 0"
    echo "# Response validation failed"
  '';

  # Prometheus textfile exporter script
  exporterScript = pkgs.writeShellScript "litellm-exporter" ''
    set -euo pipefail

    METRICS_DIR="/var/lib/prometheus-node-exporter-textfiles"
    METRICS_FILE="$METRICS_DIR/litellm.prom"
    TEMP_FILE="$METRICS_DIR/litellm.prom.$$"

    # Same label set as the health-check script -- see `labelSet` in the Nix
    # let block. The fallback below is the FOURTH emission site and must not
    # drift from the other three.
    LABELS='${labelSet}'

    # Ensure directory exists
    mkdir -p "$METRICS_DIR"

    # Run health check and write to temp file
    {
      echo "# HELP litellm_availability LiteLLM model availability (1=available, 0=unavailable)"
      echo "# TYPE litellm_availability gauge"
      echo "# HELP litellm_response_time_seconds LiteLLM response time in seconds"
      echo "# TYPE litellm_response_time_seconds gauge"

      # Last-resort fallback: the health-check script exits non-zero only
      # BEFORE it has emitted any sample (missing API key, or a crash), so this
      # cannot duplicate a metric line. It must carry $LABELS and BOTH series,
      # or a hard exporter failure would publish a differently-identified
      # litellm_availability and drop litellm_response_time_seconds entirely.
      ${litellmHealthCheck} || {
        echo "litellm_availability$LABELS 0"
        echo "litellm_response_time_seconds$LABELS 0"
      }
    } > "$TEMP_FILE"

    # Atomic move
    mv "$TEMP_FILE" "$METRICS_FILE"
  '';
in
{
  # Systemd service to run the exporter
  systemd.services.litellm-exporter = {
    description = "LiteLLM Prometheus Exporter";
    after = [ "node-exporter.service" ];
    # Note: litellm runs as a user service (Home Manager), so we can't depend on it here
    # The health check script will report availability=0 if litellm is down

    serviceConfig = {
      Type = "oneshot";
      ExecStart = exporterScript;
      TimeoutStartSec = "12min";
      # EnvironmentFile will be set below to use litellm-secrets
      User = "node-exporter";
      Group = "node-exporter";
    };
  };

  # Timer to run every 20 minutes so failures recover quickly
  systemd.timers.litellm-exporter = {
    description = "LiteLLM Prometheus Exporter Timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "20min";
      Unit = "litellm-exporter.service";
    };
  };

  # Deliberately empty: no API key is set here. The key reaches the exporter
  # through EnvironmentFile (the litellm-secrets SOPS file, wired just below),
  # and the health-check script picks up LITELLM_API_KEY or LITELLM_MASTER_KEY
  # from that environment.
  systemd.services.litellm-exporter.environment = {
    # The exporter will use the master key directly for simplicity
    # In production, you should generate a dedicated virtual key
  };

  # Link to existing litellm-secrets for the API key
  systemd.services.litellm-exporter.serviceConfig.EnvironmentFile =
    lib.mkForce
      config.sops.secrets."litellm-secrets".path;

  # Ensure prometheus-node-exporter textfile directory exists and is writable
  # Directory is already created with 1777 permissions by the tmpfiles rule in
  # modules/monitoring/services/system-exporters.nix (node-exporter.nix, the
  # module this used to name, was removed 2025-10-31)
}
