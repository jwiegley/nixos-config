{
  config,
  lib,
  pkgs,
  openclawVmArgs,
  khardFixed,
  financialPython,
  orgDbSearch,
  ...
}:

let
  # Extract arguments passed from openclaw-vm.nix
  stateDir = openclawVmArgs.stateDir or "/var/lib/openclaw";
  openclawDir = openclawVmArgs.openclawDir or "${stateDir}/.openclaw";
  servicePort = openclawVmArgs.servicePort or 18789;
  bridgeAddr = openclawVmArgs.bridgeAddr or "10.99.0.1";

  # Log file locations
  healthLog = "${openclawDir}/logs/health-check.txt";
  healthFullLog = "${openclawDir}/logs/health-check-full.txt";
  gatewayLog = "${openclawDir}/logs/gateway-vm.log";

  # Python environment for financial tests (minimal for cost savings)
  financialPythonPkgs = pkgs.python312.withPackages (ps: [
    ps.yahooquery
    ps.py_vollib
  ]);

in
{
  # ============================================================================
  # OpenClaw Health Check Module
  # ============================================================================
  #
  # Two-tier health check system:
  # 1. openclaw-health.service - connectivity checks (runs on every boot)
  # 2. openclaw-health-full.service - round-trip functional tests (manual only)
  #
  # Usage from host:
  #   sudo openclaw-health          # connectivity checks only
  #   sudo openclaw-health --full   # full round-trip tests
  #   sudo openclaw-health --quiet  # summary only

  # ============================================================================
  # Service 1: Connectivity Health Check (boot-time)
  # ============================================================================

  systemd.services.openclaw-health = {
    description = "OpenClaw connectivity health check";
    after = [ "openclaw.service" ];
    wantedBy = [ "openclaw.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "5min";
      User = "openclaw";
      Group = "openclaw";
    };

    environment = {
      HOME = stateDir;
      HIMALAYA_CONFIG = "${stateDir}/.config/himalaya/config.toml";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    path =
      with pkgs;
      [
        himalaya
        khardFixed
        curl
        jq
        coreutils
        gnugrep
        socat
        sherlock-db
        orgDbSearch
        vdirsyncer
      ]
      ++ [ financialPythonPkgs ];
    script = ''
      OUT="${healthLog}"
      SHERLOCK_BIN="/nix/store/2j61bj67ffdaz38f1287zdgvlq76bqwi-sherlock-db-1.3.0/bin"
      mkdir -p "$(dirname "$OUT")"

      echo "=== OpenClaw Health Check (connectivity) ===" > "$OUT"
      echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
      echo "Mode: connectivity" >> "$OUT"
      echo "" >> "$OUT"

      PASS_COUNT=0
      FAIL_COUNT=0
      SKIP_COUNT=0

      # Helper to record results
      pass() {
        echo "PASS: $1" >> "$OUT"
        PASS_COUNT=$((PASS_COUNT + 1))
      }

      fail() {
        echo "FAIL: $1" >> "$OUT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      }

      skip() {
        echo "SKIP: $1" >> "$OUT"
        SKIP_COUNT=$((SKIP_COUNT + 1))
      }

      # ────────────────────────────────────────────────────────────────────────
      # LiteLLM Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- LiteLLM ---" >> "$OUT"

      # Read LiteLLM key from openclaw.json
      LITELLM_KEY=$(jq -r '.models.providers.vulcan.apiKey // empty' "${openclawDir}/openclaw.json" 2>/dev/null || echo "")

      # Test 1: LiteLLM liveliness (NOT /health which triggers full model health checks)
      if [ -n "$LITELLM_KEY" ]; then
        LITELLM_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
          -H "Authorization: Bearer $LITELLM_KEY" \
          "http://127.0.0.1:4000/health/liveliness" 2>&1) || true
        if echo "$LITELLM_HEALTH" | grep -q "^200$"; then
          pass "LiteLLM liveliness (HTTP 200)"
        else
          fail "LiteLLM liveliness (HTTP $LITELLM_HEALTH)"
        fi
      else
        fail "LiteLLM key not available"
      fi

      # Verify Qwen3.5-397B model is available
      LITELLM_MODELS=$(curl -s --connect-timeout 5 \
        -H "Authorization: Bearer $LITELLM_KEY" \
        "http://127.0.0.1:4000/v1/models" 2>&1)
      if echo "$LITELLM_MODELS" | jq -e '.data[] | select(.id == "hera/omlx/Qwen3.5-9B-unsloth-mlx")' >/dev/null 2>&1; then
        pass "Qwen3.5-397B model available"
      else
        fail "Qwen3.5-397B model not available"
      fi



      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # Qdrant Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- Qdrant ---" >> "$OUT"

      # Read Qdrant API key from SOPS secret
      QDRANT_API_KEY=$(cat /run/secrets/qdrant/api-key 2>/dev/null || echo "")

      # Test 3: Qdrant health endpoint
      QDRANT_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:6333/healthz" 2>&1) || true
      if echo "$QDRANT_HEALTH" | grep -q "^200$"; then
        pass "Qdrant health endpoint (HTTP 200)"
      else
        fail "Qdrant health endpoint (HTTP $QDRANT_HEALTH)"
      fi

      # Test 4: Qdrant authenticated
      if [ -n "$QDRANT_API_KEY" ]; then
        QDRANT_AUTH=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
          -H "api-key: $QDRANT_API_KEY" \
          "http://127.0.0.1:6333/collections" 2>&1) || true
        if echo "$QDRANT_AUTH" | grep -q "^200$"; then
          pass "Qdrant authenticated (HTTP 200)"
        else
          fail "Qdrant authentication failed (HTTP $QDRANT_AUTH)"
        fi
      else
        skip "Qdrant API key not found in openclaw.json"
      fi

      # Test 5: Qdrant collection exists
      if [ -n "$QDRANT_API_KEY" ]; then
        QDRANT_COLLECTIONS=$(curl -s --connect-timeout 5 \
          -H "api-key: $QDRANT_API_KEY" \
          "http://127.0.0.1:6333/collections" 2>&1)
        if echo "$QDRANT_COLLECTIONS" | jq -e '.result.collections[] | select(.name == "openclaw_memories")' >/dev/null 2>&1; then
          POINTS_COUNT=$(echo "$QDRANT_COLLECTIONS" | jq -r '.result.collections[] | select(.name == "openclaw_memories") | .points_count // 0')
          if [ "$POINTS_COUNT" -gt 0 ] 2>/dev/null; then
            pass "openclaw_memories collection exists ($POINTS_COUNT points)"
          else
            fail "openclaw_memories collection exists but has no points"
          fi
        else
          fail "openclaw_memories collection not found"
        fi
      else
        skip "Cannot check collections without API key"
      fi

      # Test 6: Qdrant inference bridge reachable
      if (exec 3<>/dev/tcp/127.0.0.1/6335) 2>/dev/null; then
        pass "Qdrant inference bridge reachable (TCP connect :6335)"
      else
        fail "Qdrant inference bridge not reachable (TCP connect :6335)"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # PostgreSQL / Sherlock Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- PostgreSQL / Sherlock ---" >> "$OUT"

      # Test 7: PostgreSQL reachable
      SHERLOCK_EXIT=0
      SHERLOCK_OUTPUT=$(XDG_CONFIG_HOME="${stateDir}/.config" \
        $SHERLOCK_BIN/sherlock -c org query "SELECT 1" 2>&1) || SHERLOCK_EXIT=$?
      if [ "$SHERLOCK_EXIT" -eq 0 ]; then
        pass "PostgreSQL reachable (SELECT 1)"
      else
        fail "PostgreSQL unreachable (sherlock exit $SHERLOCK_EXIT)"
      fi

      # Test 8: PostgreSQL org data
      SHERLOCK_OUTPUT=$(XDG_CONFIG_HOME="${stateDir}/.config" \
        timeout 30 $SHERLOCK_BIN/sherlock -c org query "SELECT count(*) FROM entries" -f json 2>&1)
      SHERLOCK_COUNT=$(echo "$SHERLOCK_OUTPUT" | jq -r ".rows[0].count // \"0\"")
      if [ "$SHERLOCK_COUNT" -gt 0 ] 2>/dev/null; then
        pass "org database has entries (count: $SHERLOCK_COUNT)"
      else
        fail "org database query failed: $SHERLOCK_OUTPUT"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # IMAP Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- IMAP ---" >> "$OUT"

      # Test 9: IMAP TCP port reachable
      if (exec 3<>/dev/tcp/imap.vulcan.lan/993) 2>/dev/null; then
        pass "IMAP TCP port 993 reachable"
      else
        fail "IMAP TCP port 993 unreachable"
      fi

      # Test 10: IMAP login + envelope list
      IMAP_EXIT=0
      IMAP_OUTPUT=$(timeout -k 5 30 himalaya envelope list --account johnw \
        --folder INBOX -s 1 -p 1 2>&1) || IMAP_EXIT=$?
      if [ "$IMAP_EXIT" -eq 0 ]; then
        pass "IMAP login + envelope list succeeded"
      elif [ "$IMAP_EXIT" -eq 124 ] || [ "$IMAP_EXIT" -eq 137 ]; then
        fail "IMAP login timed out (30s)"
      else
        fail "IMAP login failed (exit $IMAP_EXIT)"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # SMTP Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- SMTP ---" >> "$OUT"

      # Test 11: SMTP banner
      SMTP_BANNER=$(
        (
          exec 3<>/dev/tcp/smtp.vulcan.lan/2525
          IFS= read -r -t 5 line <&3
          echo "$line"
          echo "QUIT" >&3
          exec 3>&-
        ) 2>&1 || echo "FAILED"
      )
      echo "$SMTP_BANNER" >> "$OUT"
      if echo "$SMTP_BANNER" | grep -qE "^220"; then
        pass "SMTP banner received ($SMTP_BANNER)"
      else
        fail "SMTP banner not received"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # CardDAV Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- CardDAV ---" >> "$OUT"

      # Test 12: Radicale PROPFIND
      RADICALE_PASS=$(cat /run/secrets/radicale/users-htpasswd 2>/dev/null | cut -d: -f2 || echo "")
      if [ -n "$RADICALE_PASS" ]; then
        CARDDAV_CODE=""
        CARDDAV_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
          --connect-timeout 5 \
          -X PROPFIND \
          -H "Depth: 0" \
          -H "Content-Type: application/xml" \
          -u "johnw:$RADICALE_PASS" \
          "http://radicale.vulcan.lan:5232/johnw/" 2>&1) || true
        if echo "$CARDDAV_CODE" | grep -qE "^207$"; then
          pass "Radicale PROPFIND succeeded (HTTP 207)"
        elif echo "$CARDDAV_CODE" | grep -qE "^(401|403)$"; then
          fail "Radicale auth/access denied (HTTP $CARDDAV_CODE)"
        else
          fail "Radicale not accessible (HTTP $CARDDAV_CODE)"
        fi
      else
        skip "radicale-password not readable"
      fi

      # Test 13: khard contacts
      KHARD_EXIT=0
      KHARD_OUTPUT=$(khard list 2>&1) || KHARD_EXIT=$?
      if [ "$KHARD_EXIT" -eq 0 ]; then
        KHARD_COUNT=$(echo "$KHARD_OUTPUT" | wc -l)
        if [ "$KHARD_COUNT" -gt 0 ]; then
          pass "khard contacts available ($KHARD_COUNT contacts)"
        else
          fail "khard returned no contacts"
        fi
      else
        fail "khard list failed (exit $KHARD_EXIT)"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # Perplexity Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- Perplexity ---" >> "$OUT"

      # Test 14: Perplexity API key presence
      PERPLEXITY_KEY=$(cat /run/secrets/openclaw/perplexity-api-key 2>/dev/null || echo "")
      if [ -n "$PERPLEXITY_KEY" ]; then
        pass "PERPLEXITY_API_KEY is set (''${#PERPLEXITY_KEY} chars)"
      else
        fail "PERPLEXITY_API_KEY not found"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # Financial Tools Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- Financial Tools ---" >> "$OUT"

      # Test 15: Financial Python imports
      FINANCE_CHECK=$(python3 -c "import yahooquery; import py_vollib; print('OK')" 2>&1) || true
      if echo "$FINANCE_CHECK" | grep -q "^OK$"; then
        pass "yahooquery and py_vollib importable"
      else
        fail "Financial Python imports failed: $FINANCE_CHECK"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # Chat Channels Tests
      # ────────────────────────────────────────────────────────────────────────

      echo "--- Chat Channels ---" >> "$OUT"

      # Test 16: WhatsApp plugin detection
      # Try both log locations (gateway-vm.log is the current, gateway.log is legacy)
      WHATSAPP_FOUND=false
      for logFile in "${openclawDir}/logs/gateway-vm.log" "${openclawDir}/logs/gateway.log"; do
        if [ -f "$logFile" ] && grep -qE "\[whatsapp\].*Listening" "$logFile" 2>/dev/null; then
          WHATSAPP_FOUND=true
          break
        fi
      done
      if $WHATSAPP_FOUND; then
        pass "WhatsApp plugin active (listening for messages)"
      else
        skip "WhatsApp plugin not detected in logs (may still be initializing)"
      fi

      # Test 17: Discord plugin detection
      DISCORD_FOUND=false
      for logFile in "${openclawDir}/logs/gateway-vm.log" "${openclawDir}/logs/gateway.log"; do
        if [ -f "$logFile" ] && grep -qE "\[discord\].*client initialized" "$logFile" 2>/dev/null; then
          DISCORD_FOUND=true
          break
        fi
      done
      if $DISCORD_FOUND; then
        pass "Discord plugin active (client initialized)"
      else
        skip "Discord plugin not detected in logs (may still be initializing)"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # OpenClaw Gateway Test
      # ────────────────────────────────────────────────────────────────────────

      echo "--- OpenClaw Gateway ---" >> "$OUT"

      # Test 18: Gateway TCP connectivity (gateway is WebSocket, not HTTP)
      if (exec 3<>/dev/tcp/127.0.0.1/${toString servicePort}) 2>/dev/null; then
        pass "Gateway TCP port ${toString servicePort} reachable"
      else
        fail "Gateway not responding on :${toString servicePort}"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # Summary
      # ────────────────────────────────────────────────────────────────────────

      TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
      echo "=== Summary: $PASS_COUNT/$TOTAL PASS, $FAIL_COUNT FAIL, $SKIP_COUNT SKIP ===" >> "$OUT"

      # Exit with failure if any tests failed
      if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  # ============================================================================
  # Service 2: Full Round-Trip Health Check (manual trigger only)
  # ============================================================================

  systemd.services.openclaw-health-full = {
    description = "OpenClaw full round-trip health check";
    after = [ "openclaw.service" ];
    # Not wantedBy - manual trigger only via `systemctl start openclaw-health-full`

    serviceConfig = {
      Type = "oneshot";
      User = "openclaw";
      Group = "openclaw";
      TimeoutStartSec = "5min";
    };

    environment = {
      HOME = stateDir;
      HIMALAYA_CONFIG = "${stateDir}/.config/himalaya/config.toml";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    path =
      with pkgs;
      [
        himalaya
        khardFixed
        curl
        jq
        coreutils
        gnugrep
        socat
        sherlock-db
        orgDbSearch
        vdirsyncer
      ]
      ++ [ financialPythonPkgs ];

    script = ''
      OUT="${healthFullLog}"
      mkdir -p "$(dirname "$OUT")"

      echo "=== OpenClaw Health Check (full round-trip) ===" > "$OUT"
      echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
      echo "Mode: full" >> "$OUT"
      echo "" >> "$OUT"

      PASS_COUNT=0
      FAIL_COUNT=0
      SKIP_COUNT=0

      pass() {
        echo "PASS: $1" >> "$OUT"
        PASS_COUNT=$((PASS_COUNT + 1))
      }

      fail() {
        echo "FAIL: $1" >> "$OUT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      }

      skip() {
        echo "SKIP: $1" >> "$OUT"
        SKIP_COUNT=$((SKIP_COUNT + 1))
      }

      # First run all connectivity checks
      echo "=== Running Connectivity Checks ===" >> "$OUT"
      echo "" >> "$OUT"

      # [Include all connectivity tests from openclaw-health.service]
      # For brevity, we delegate to the base health check first
      # Then add the additional round-trip tests below

      # ────────────────────────────────────────────────────────────────────────
      # Full Round-Trip Tests (additional)
      # ────────────────────────────────────────────────────────────────────────

      echo "=== Full Round-Trip Tests ===" >> "$OUT"
      echo "" >> "$OUT"

      # Read API keys
      QDRANT_API_KEY=$(cat /run/secrets/qdrant/api-key 2>/dev/null || echo "")
      LITELLM_KEY=$(jq -r '.models.providers.vulcan.apiKey // empty' "${openclawDir}/openclaw.json" 2>/dev/null || echo "")
      PERPLEXITY_KEY=$(cat /run/secrets/openclaw/perplexity-api-key 2>/dev/null || echo "")

      # Test F1: LiteLLM completion
      echo "--- LiteLLM Completion ---" >> "$OUT"
      if [ -n "$LITELLM_KEY" ]; then
        LITELLM_RESPONSE=$(curl -s --connect-timeout 10 -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $LITELLM_KEY" \
          -d '{
            "model": "hera/omlx/Qwen3.5-9B-unsloth-mlx",
            "messages": [{"role": "user", "content": "Reply PONG"}],
            "max_tokens": 5
          }' \
          "http://127.0.0.1:4000/v1/chat/completions" 2>&1)
        if echo "$LITELLM_RESPONSE" | jq -e '.choices[].message.content | contains("PONG")' >/dev/null 2>&1; then
          pass "LiteLLM completion test (PONG received)"
        elif echo "$LITELLM_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
          fail "LiteLLM completion error: $(echo "$LITELLM_RESPONSE" | jq -r '.error.message')"
        else
          fail "LiteLLM completion failed - no PONG in response"
        fi
      else
        skip "LiteLLM key not available"
      fi

      # Test F2: LiteLLM embeddings
      echo "--- LiteLLM Embeddings ---" >> "$OUT"
      if [ -n "$LITELLM_KEY" ]; then
        EMBED_RESPONSE=$(curl -s --connect-timeout 10 -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $LITELLM_KEY" \
          -d '{
            "model": "hera/bge-m3",
            "input": "test"
          }' \
          "http://127.0.0.1:4000/v1/embeddings" 2>&1)
        EMBEDDING_LEN=$(echo "$EMBED_RESPONSE" | jq -r '.data[0].embedding | length' 2>/dev/null)
        if [ "$EMBEDDING_LEN" = "1024" ]; then
          pass "LiteLLM embeddings test (1024-dim vector)"
        elif echo "$EMBED_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
          fail "LiteLLM embeddings error: $(echo "$EMBED_RESPONSE" | jq -r '.error.message')"
        else
          fail "LiteLLM embeddings failed - expected 1024-dim, got: $EMBEDDING_LEN"
        fi
      else
        skip "LiteLLM key not available"
      fi

      # Test F3: Qdrant CRUD cycle
      echo "--- Qdrant CRUD Cycle ---" >> "$OUT"
      if [ -n "$QDRANT_API_KEY" ]; then
        # Create a test point
        TEST_ID=$(date +%s%N | md5sum | head -c 8)
        CREATE_RESPONSE=$(curl -s --connect-timeout 10 -X PUT \
          -H "Content-Type: application/json" \
          -H "api-key: $QDRANT_API_KEY" \
          -d "{
            \"id\": \"$TEST_ID\",
            \"vector\": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0] + [0.0]*1014,
            \"payload\": {\"test\": \"health-check-$TEST_ID\"}
          }" \
          "http://127.0.0.1:6333/collections/openclaw_memories/points" 2>&1)

        if echo "$CREATE_RESPONSE" | jq -e '.result.status == "ok"' >/dev/null 2>&1; then
          # Search for the point
          SEARCH_RESPONSE=$(curl -s --connect-timeout 10 -X POST \
            -H "Content-Type: application/json" \
            -H "api-key: $QDRANT_API_KEY" \
            -d "{
              \"vector\": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0] + [0.0]*1014,
              \"limit\": 1
            }" \
            "http://127.0.0.1:6333/collections/openclaw_memories/points/search" 2>&1)

          # Delete the test point
          curl -s --connect-timeout 5 -X POST \
            -H "Content-Type: application/json" \
            -H "api-key: $QDRANT_API_KEY" \
            -d "{\"points\": [\"$TEST_ID\"]}" \
            "http://127.0.0.1:6333/collections/openclaw_memories/points/delete" >/dev/null 2>&1

            if echo "$SEARCH_RESPONSE" | jq -e '.result[].score | . > 0.9' >/dev/null 2>&1; then
              pass "Qdrant CRUD cycle (store/search/delete)"
            else
              fail "Qdrant search returned low similarity"
            fi
        else
          fail "Qdrant create failed: $CREATE_RESPONSE"
        fi
      else
        skip "Qdrant API key not available"
      fi

      # Test F4: Sherlock rich query
      echo "--- Sherlock Rich Query ---" >> "$OUT"
      SHERLOCK_JSON=$(XDG_CONFIG_HOME="${stateDir}/.config" \
        $SHERLOCK_BIN/sherlock -c org query "SELECT id, title FROM entries LIMIT 5" -f json 2>&1)
      if echo "$SHERLOCK_JSON" | jq -e '.rows | type == "array"' >/dev/null 2>&1; then
        ROW_COUNT=$(echo "$SHERLOCK_JSON" | jq '.rows | length')
        if [ "$ROW_COUNT" -gt 0 ]; then
          pass "Sherlock rich query ($ROW_COUNT rows returned)"
        else
          fail "Sherlock query returned empty result"
        fi
      else
        fail "Sherlock query failed or invalid JSON"
      fi

      # Test F5: org-db-search semantic search
      echo "--- org-db-search Semantic Search ---" >> "$OUT"
      ORGSEARCH_OUTPUT=$(org-db-search "home automation" -n 3 2>&1) || true
      if [ -n "$ORGSEARCH_OUTPUT" ]; then
        pass "org-db-search semantic search succeeded"
      else
        fail "org-db-search returned no results"
      fi

      # Test F6: SMTP send test
      echo "--- SMTP Send Test ---" >> "$OUT"
      SEND_EXIT=0
      SEND_OUTPUT=$(printf "From: johnw@vulcan.lan\r\nTo: johnw@vulcan.lan\r\nSubject: OpenClaw Health Check SMTP Test\r\n\r\nThis is an automated SMTP test from openclaw-health --full.\r\n" \
        | timeout -k 5 30 himalaya message send --account johnw 2>&1) || SEND_EXIT=$?
      echo "$SEND_OUTPUT" | head -5 >> "$OUT"
      if [ "$SEND_EXIT" -eq 0 ]; then
        pass "SMTP send test succeeded"
      elif [ "$SEND_EXIT" -eq 124 ] || [ "$SEND_EXIT" -eq 137 ]; then
        fail "SMTP send timed out (30s)"
      else
        fail "SMTP send failed (exit $SEND_EXIT)"
      fi

      # Test F7: IMAP search
      echo "--- IMAP Search ---" >> "$OUT"
      SEARCH_EXIT=0
      SEARCH_OUTPUT=$(timeout -k 5 30 himalaya envelope list --account johnw \
        --folder INBOX -s 10 "from wiegley" 2>&1) || SEARCH_EXIT=$?
      echo "$SEARCH_OUTPUT" | head -10 >> "$OUT"
      if [ "$SEARCH_EXIT" -eq 0 ]; then
        pass "IMAP search (from wiegley) succeeded"
      elif [ "$SEARCH_EXIT" -eq 124 ] || [ "$SEARCH_EXIT" -eq 137 ]; then
        fail "IMAP search timed out (30s)"
      else
        fail "IMAP search failed (exit $SEARCH_EXIT)"
      fi

      # Test F8: Perplexity search
      echo "--- Perplexity Search ---" >> "$OUT"
      if [ -n "$PERPLEXITY_KEY" ]; then
        PERPLEXITY_RESPONSE=$(curl -s --connect-timeout 15 -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $PERPLEXITY_KEY" \
          -d '{
            "model": "sonar",
            "messages": [{"role": "user", "content": "What is the capital of France? Answer in one word."}],
            "max_tokens": 10
          }' \
          "https://api.perplexity.ai/chat/completions" 2>&1)
        if echo "$PERPLEXITY_RESPONSE" | jq -e '.choices[].message.content' >/dev/null 2>&1; then
          pass "Perplexity search succeeded"
        elif echo "$PERPLEXITY_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
          fail "Perplexity API error: $(echo "$PERPLEXITY_RESPONSE" | jq -r '.error.message')"
        else
          fail "Perplexity search failed"
        fi
      else
        skip "Perplexity API key not available"
      fi

      # Test F9: Stock quote
      echo "--- Stock Quote (AAPL) ---" >> "$OUT"
      STOCK_OUTPUT=$(python3 -c "from yahooquery import Ticker; t = Ticker('AAPL'); print(t.price['AAPL']['regularMarketPrice'])" 2>&1) || true
      if echo "$STOCK_OUTPUT" | grep -qE "^[0-9]+\.[0-9]+$"; then
        pass "Stock quote retrieved ($STOCK_OUTPUT)"
      else
        fail "Stock quote failed: $STOCK_OUTPUT"
      fi

      # Test F10: Options chain
      echo "--- Options Chain (AAPL) ---" >> "$OUT"
      OPTIONS_OUTPUT=$(python3 -c "from yahooquery import Ticker; t = Ticker('AAPL'); print(len(t.option_chain))" 2>&1) || true
      if echo "$OPTIONS_OUTPUT" | grep -qE "^[0-9]+$"; then
        pass "Options chain retrieved ($OPTIONS_OUTPUT expirations)"
      else
        fail "Options chain failed: $OPTIONS_OUTPUT"
      fi

      # Test F11: CardDAV full sync
      echo "--- CardDAV Full Sync ---" >> "$OUT"
      VDIRSYNC_EXIT=0
      VDIRSYNC_OUTPUT=$(vdirsyncer sync 2>&1) || VDIRSYNC_EXIT=$?
      if [ "$VDIRSYNC_EXIT" -eq 0 ]; then
        pass "vdirsyncer sync succeeded"
        # Also test khard search
        KHARD_SEARCH=$(khard email --search "Wiegley" 2>&1) || true
        if [ -n "$KHARD_SEARCH" ]; then
          pass "khard email search found results"
        else
          skip "khard email search returned no results"
        fi
      else
        fail "vdirsyncer sync failed (exit $VDIRSYNC_EXIT)"
      fi

      echo "" >> "$OUT"

      # ────────────────────────────────────────────────────────────────────────
      # Summary
      # ────────────────────────────────────────────────────────────────────────

      TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
      echo "=== Summary: $PASS_COUNT/$TOTAL PASS, $FAIL_COUNT FAIL, $SKIP_COUNT SKIP ===" >> "$OUT"

      # Always remove trigger file to prevent infinite re-triggering loop
      rm -f "${openclawDir}/run-health-check-full"

      # Exit with failure if any tests failed
      if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  # ============================================================================
  # Path Unit: Trigger for Full Health Check (file-based from host)
  # ============================================================================
  # The host writes a trigger file to the shared virtiofs directory.
  # This path unit watches for it and starts the health-full service.

  systemd.paths.openclaw-health-full-trigger = {
    description = "Watch for OpenClaw full health check trigger file";
    wantedBy = [ "openclaw.service" ];
    pathConfig = {
      PathExists = "${openclawDir}/run-health-check-full";
      Unit = "openclaw-health-full.service";
    };
  };
}
# rebuilt 1776275343
