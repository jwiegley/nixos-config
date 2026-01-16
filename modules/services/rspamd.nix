{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Shell script to call rspamc learn_spam
  learnSpamShellScript = pkgs.writeShellScript "rspamd-learn-spam.sh" ''
    exec ${pkgs.rspamd}/bin/rspamc learn_spam
  '';

  # Shell script to call rspamc learn_ham
  learnHamShellScript = pkgs.writeShellScript "rspamd-learn-ham.sh" ''
    exec ${pkgs.rspamd}/bin/rspamc learn_ham
  '';

  # Custom Lua rules for rspamd
  customLuaRules = pkgs.writeText "rspamd.local.lua" ''
    -- =======================================================================
    -- Custom rspamd Lua rules
    -- =======================================================================

    local rspamd_logger = require "rspamd_logger"

    -- Detect non-standard x-binaryenc encoding (spam indicator)
    -- Background: x-binaryenc is a fake/non-standard encoding used by spammers
    -- to evade detection. ICU library correctly refuses to convert it.
    rspamd_config.X_BINARYENC_SPAM = {
      callback = function(task)
        -- Check MIME parts for x-binaryenc in content-transfer-encoding or charset
        local parts = task:get_parts()
        if parts then
          for _,part in ipairs(parts) do
            -- Check content-transfer-encoding via get_cte()
            local cte = part:get_cte()
            if cte and cte:lower():match('x%-binaryenc') then
              return true
            end
            -- Check charset for text parts
            if part:is_text() then
              local tp = part:get_text()
              if tp then
                local charset = tp:get_charset()
                if charset and charset:lower():match('x%-binaryenc') then
                  return true
                end
              end
            end
          end
        end

        -- Also check Content-Transfer-Encoding header directly
        local cte_header = task:get_header('Content-Transfer-Encoding')
        if cte_header and cte_header:lower():match('x%-binaryenc') then
          return true
        end

        return false
      end,
      score = 7.5,
      description = 'Message uses non-standard x-binaryenc encoding (spam indicator)',
      group = 'headers'
    }

    -- =======================================================================
    -- Detect random/gibberish email addresses using entropy analysis
    -- Spammers often use randomly generated addresses like "xk8jf2dk9@domain.com"
    -- =======================================================================

    -- Helper function: Calculate Shannon entropy of a string
    local function calculate_entropy(str)
      if not str or #str == 0 then return 0 end

      local freq = {}
      local len = #str

      -- Count character frequencies
      for i = 1, len do
        local c = str:sub(i, i):lower()
        freq[c] = (freq[c] or 0) + 1
      end

      -- Calculate entropy: H = -Σ(p * log2(p))
      local entropy = 0
      for _, count in pairs(freq) do
        local p = count / len
        entropy = entropy - (p * math.log(p) / math.log(2))
      end

      return entropy
    end

    -- Helper function: Calculate consonant-to-vowel ratio
    local function consonant_vowel_ratio(str)
      if not str or #str == 0 then return 0, 0 end

      local vowels = 0
      local consonants = 0
      local vowel_set = { a=1, e=1, i=1, o=1, u=1 }

      for i = 1, #str do
        local c = str:sub(i, i):lower()
        if c:match('[a-z]') then
          if vowel_set[c] then
            vowels = vowels + 1
          else
            consonants = consonants + 1
          end
        end
      end

      return consonants, vowels
    end

    -- Helper function: Count letter-digit transitions (mixing indicator)
    local function count_transitions(str)
      if not str or #str < 2 then return 0 end

      local transitions = 0
      local last_is_digit = str:sub(1, 1):match('%d') ~= nil

      for i = 2, #str do
        local c = str:sub(i, i)
        local is_digit = c:match('%d') ~= nil
        local is_letter = c:match('[a-zA-Z]') ~= nil

        if is_digit or is_letter then
          local current_is_digit = is_digit
          if current_is_digit ~= last_is_digit then
            transitions = transitions + 1
          end
          last_is_digit = current_is_digit
        end
      end

      return transitions
    end

    -- Helper function: Check for consecutive consonants (gibberish indicator)
    local function max_consecutive_consonants(str)
      if not str then return 0 end

      local max_consec = 0
      local current = 0
      local vowel_set = { a=1, e=1, i=1, o=1, u=1 }

      for i = 1, #str do
        local c = str:sub(i, i):lower()
        if c:match('[a-z]') then
          if vowel_set[c] then
            current = 0
          else
            current = current + 1
            if current > max_consec then
              max_consec = current
            end
          end
        end
      end

      return max_consec
    end

    -- Main gibberish detection rule
    rspamd_config.FROM_ADDR_GIBBERISH = {
      callback = function(task)
        -- Get sender from SMTP envelope first, then MIME
        local from = task:get_from('smtp')
        if not from or not from[1] then
          from = task:get_from('mime')
        end
        if not from or not from[1] then
          return false
        end

        local user = from[1].user
        if not user then return false end

        -- Strip plus-addressing suffix (user+tag@domain)
        local base_user = user:match('^([^+]+)') or user

        -- Skip very short addresses (< 5 chars) - too little data
        if #base_user < 5 then return false end

        -- Skip addresses that look like UUIDs or system addresses
        if base_user:match('^[0-9a-f][-0-9a-f]+[0-9a-f]$') then return false end
        if base_user:match('^noreply') or base_user:match('^no%-reply') then return false end
        if base_user:match('^postmaster') or base_user:match('^mailer%-daemon') then return false end

        -- Calculate metrics
        local entropy = calculate_entropy(base_user)
        local consonants, vowels = consonant_vowel_ratio(base_user)
        local transitions = count_transitions(base_user)
        local max_consec = max_consecutive_consonants(base_user)

        -- Calculate scores for each metric
        local score = 0
        local reasons = {}

        -- High entropy check (random strings typically > 3.8)
        -- Normalize by length: shorter strings naturally have lower entropy
        local normalized_entropy = entropy
        if #base_user < 10 then
          -- Adjust threshold for short strings
          normalized_entropy = entropy * (10 / #base_user) * 0.7
        end

        if normalized_entropy > 4.2 then
          score = score + 2.0
          table.insert(reasons, string.format("high_entropy=%.2f", entropy))
        elseif normalized_entropy > 3.8 then
          score = score + 1.0
          table.insert(reasons, string.format("elevated_entropy=%.2f", entropy))
        end

        -- Consonant-to-vowel ratio check
        -- Normal English: ~1.5-2.5 consonants per vowel
        if vowels > 0 then
          local ratio = consonants / vowels
          if ratio > 5.0 then
            score = score + 2.0
            table.insert(reasons, string.format("few_vowels=%.1f", ratio))
          elseif ratio > 3.5 then
            score = score + 1.0
            table.insert(reasons, string.format("low_vowels=%.1f", ratio))
          end
        elseif consonants > 3 then
          -- No vowels at all in a string with >3 consonants
          score = score + 2.5
          table.insert(reasons, "no_vowels")
        end

        -- Letter-digit transition check
        -- Many transitions suggest random mixing like "a1b2c3d4"
        local transition_ratio = transitions / #base_user
        if transition_ratio > 0.4 then
          score = score + 2.0
          table.insert(reasons, string.format("digit_mixing=%d", transitions))
        elseif transition_ratio > 0.25 then
          score = score + 1.0
          table.insert(reasons, string.format("some_mixing=%d", transitions))
        end

        -- Consecutive consonants check
        -- Normal words rarely have >4 consecutive consonants
        if max_consec >= 6 then
          score = score + 1.5
          table.insert(reasons, string.format("consonant_cluster=%d", max_consec))
        elseif max_consec >= 5 then
          score = score + 0.5
          table.insert(reasons, string.format("long_consonants=%d", max_consec))
        end

        -- Only flag if multiple indicators present (score >= 2.5)
        -- This reduces false positives on unusual but legitimate addresses
        if score >= 2.5 then
          local desc = string.format("%s [%s]", base_user, table.concat(reasons, ", "))
          return true, score, desc
        end

        return false
      end,
      score = 1.0,  -- Base score, actual score returned by callback
      description = 'Sender address appears randomly generated (gibberish)',
      group = 'headers'
    }
  '';

  # Sieve script for learning spam (when moved to TrainSpam)
  # References script by name from sieve_pipe_bin_dir
  learnSpamScript = pkgs.writeText "learn-spam.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainSpam" {
      pipe :copy "rspamd-learn-spam.sh";
    }
  '';

  # Sieve script for learning ham (when moved to TrainGood)
  # References script by name from sieve_pipe_bin_dir
  learnHamScript = pkgs.writeText "learn-ham.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables", "fileinto"];

    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "TrainGood" {
      pipe :copy "rspamd-learn-ham.sh";
    }
  '';

  # Sieve script to move trained spam to Spam folder
  moveToSpamScript = pkgs.writeText "move-to-spam.sieve" ''
    require ["fileinto", "imap4flags"];

    # Move all messages in TrainSpam to Spam after learning
    fileinto "Spam";

    # Mark the original message in TrainSpam as deleted
    addflag "\\Deleted";
  '';

  # Shell script to rescan message and redeliver via Postfix
  retrainShellScript = pkgs.writeShellScript "rspamd-retrain.sh" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Receive username as argument from Sieve
    USER="$1"

    if [ -z "$USER" ]; then
      echo "ERROR: No username provided" >&2
      exit 1
    fi

    # Reinject via sendmail to trigger full Postfix delivery pipeline:
    # Postfix → rspamd milter (adds/updates X-Spam headers) → dovecot LMTP → Sieve filtering
    # Use setuid wrapper to handle Postfix permissions
    # -G: gateway submission (don't add headers)
    # -i: ignore single dots on lines by themselves
    # -f: envelope sender
    exec /run/wrappers/bin/sendmail -G -i -f "$USER@localhost" "$USER@localhost"
  '';

  # Sieve script for retraining (when moved to Retrain folder)
  retrainScript = pkgs.writeText "retrain.sieve" ''
    require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

    # Capture the username from IMAP session
    if environment :matches "imap.user" "*" {
      set "username" "''${1}";
    }

    # Only process if in Retrain mailbox
    if environment :matches "imap.mailbox" "*" {
      set "mailbox" "''${1}";
    }

    if string "''${mailbox}" "Retrain" {
      # Pipe message through rspamd for rescanning, then redeliver via LDA
      # Pass username as argument so dovecot-lda knows where to deliver
      pipe :copy "rspamd-retrain.sh" ["''${username}"];
    }
  '';

  # Sieve script to clean up retrained messages
  retrainCleanupScript = pkgs.writeText "retrain-cleanup.sieve" ''
    require ["imap4flags"];

    # Mark the original message in Retrain as deleted
    # User's mail client will expunge it on next sync
    addflag "\\Deleted";
  '';

  # Note: moveToGoodScript removed - TrainGood now uses process-good.sieve directly
  # to re-filter messages via active.sieve instead of moving to Good folder first
in
{
  # SOPS secret for Rspamd controller password
  sops.secrets."rspamd-controller-password" = {
    owner = "rspamd";
    mode = "0400";
    restartUnits = [ "rspamd.service" ];
  };

  # SOPS secret for Rspamd PostgreSQL password
  sops.secrets."rspamd-db-password" = {
    owner = "rspamd";
    mode = "0400";
    restartUnits = [ "rspamd.service" ];
  };

  # SOPS secret for LiteLLM API key
  sops.secrets."litellm-vulcan-lan" = {
    owner = "rspamd";
    mode = "0400";
    restartUnits = [ "rspamd.service" ];
  };

  # Enable Rspamd service using NixOS module
  services.rspamd = {
    enable = true;

    # Custom Lua rules (gibberish detection, etc.)
    localLuaRules = customLuaRules;

    # Configure workers to include override directory for password
    workers.controller = {
      includes = [ "/var/lib/rspamd/override.d/worker-controller.inc" ];
      # Explicitly configure secure IPs and bind socket
      extraConfig = ''
        # Secure web interface access from localhost
        secure_ip = "127.0.0.1";
        secure_ip = "::1";

        # IMPORTANT: Use single controller worker for RRD support
        # Multiple controller workers break RRD graphs
        count = 1;
      '';
    };

    # Configure proxy worker for milter protocol integration with Postfix
    workers.rspamd_proxy = {
      type = "rspamd_proxy";
      bindSockets = [ "localhost:11332" ];
      count = 4;
      extraConfig = ''
        milter = yes;
        timeout = 30s;
        upstream "local" {
          default = yes;
          self_scan = yes;
        }
      '';
    };

    # Use local Redis instance for statistics
    locals = {
      "logging.inc".text = ''
        # Logging configuration
        # Using "notice" to suppress frequent "allow unauthorized connection from trusted IP"
        # messages that occur every minute from Prometheus scraping /metrics.
        # These are informational (not warnings) but clutter logs significantly.
        level = "notice";

        # Keep systemd journal logging
        systemd = true;
      '';

      "options.inc".text = ''
        # DNS configuration for better performance
        # Rspamd can make 20-64 concurrent DNS queries per message for RBLs/SURBLs/URIBLs
        # Use Unbound recursive resolver to avoid blocklist rate-limiting/blocking
        dns {
          nameserver = ["192.168.1.1"];  # Use local Unbound recursive resolver
          timeout = 2s;                  # Timeout for DNS queries
          sockets = 32;                  # Number of concurrent DNS sockets
          retransmits = 2;               # Number of retries for failed queries
        }

        local_addrs = [
          "127.0.0.0/8",
          "192.168.0.0/16",
          "172.16.0.0/12",
          "10.0.0.0/8",
          "::1",
        ];

        neighbours {
          server1 { host = "https://rspamd.vulcan.lan:443"; }
        }

        # Custom local TLD file to recognize .lan domain
        # This prevents "TLD part is not detected" warnings for internal URLs
        # like nagios.vulcan.lan
        url_tld = "$LOCAL_CONFDIR/local.d/maps.d/effective_tld_names.dat";
      '';

      # Custom TLD file - includes .lan for internal domain URLs
      # This file supplements the default public suffix list
      "maps.d/effective_tld_names.dat".source = pkgs.runCommand "custom-tlds" { } ''
        # Copy the default TLD list
        cat ${pkgs.rspamd}/share/rspamd/effective_tld_names.dat > $out
        # Add custom local TLDs
        echo "" >> $out
        echo "// Custom local TLDs for internal network domains" >> $out
        echo "lan" >> $out
        echo "local" >> $out
      '';

      "redis.conf".text = ''
        # Redis backend configuration for Bayes classifier
        servers = "127.0.0.1:6381";
      '';

      "rrd.conf".text = ''
        # RRD configuration for historical statistics and graphs
        # Enable RRD for throughput page
        rrd = "/var/lib/rspamd/rspamd.rrd";
      '';

      "statistic.conf".text = ''
        # Statistics configuration
        classifier "bayes" {
          backend = "redis";
          servers = "127.0.0.1:6381";

          # Tokenizer settings
          tokenizer {
            name = "osb";
          }

          # Cache settings
          cache {
            type = "redis";
            servers = "127.0.0.1:6381";
          }

          # Minimum learns before autolearn kicks in
          min_learns = 10;

          # Autolearn settings
          autolearn {
            spam_threshold = 12.0;
            ham_threshold = -5.0;
          }

          # Statfiles required for classifier (Redis-backed)
          statfile {
            symbol = "BAYES_HAM";
            spam = false;
          }
          statfile {
            symbol = "BAYES_SPAM";
            spam = true;
          }
        }
      '';

      "actions.conf".text = ''
        # Action thresholds - never reject, only add headers
        # Let Sieve handle spam filing based on X-Spam headers
        reject = 999;  # Effectively disable rejection
        add_header = 4;
        greylist = 3;
      '';

      "milter_headers.conf".text = ''
        # Extended headers for comprehensive spam analysis
        # Enables: X-Spamd-Result, X-Spamd-Bar, X-Spam-Level, X-Spam-Status,
        #          X-Rspamd-Server, X-Rspamd-Queue-Id, Authentication-Results
        extended_spam_headers = true;

        # CRITICAL: Add headers to local and authenticated mail
        # Without these, rspamd won't add headers to mail from localhost or authenticated users
        # This is why headers were missing in test messages!
        skip_local = false;
        skip_authenticated = false;
      '';

      # Email authentication policy scores (SPF, DKIM, DMARC)
      # These modules are enabled by default; we customize scores for better spam detection
      "policies_group.conf".text = ''
        # Custom scores for email authentication policies
        # More aggressive than defaults to properly penalize/reward authentication

        symbols {
          # SPF (Sender Policy Framework) symbols
          "R_SPF_ALLOW" { weight = -1.0; description = "SPF verification passed"; }
          "R_SPF_FAIL" { weight = 3.0; description = "SPF verification failed"; }
          "R_SPF_SOFTFAIL" { weight = 1.5; description = "SPF verification soft-failed"; }
          "R_SPF_NEUTRAL" { weight = 0.0; description = "SPF neutral result"; }
          "R_SPF_NA" { weight = 0.5; description = "No SPF record"; }
          "R_SPF_DNSFAIL" { weight = 0.0; description = "SPF DNS lookup failed"; }
          "R_SPF_PERMFAIL" { weight = 2.0; description = "SPF permanent failure"; }
          "R_SPF_PLUSALL" { weight = 5.0; description = "Dangerous +all SPF record"; }

          # DKIM (DomainKeys Identified Mail) symbols
          "R_DKIM_ALLOW" { weight = -1.0; description = "DKIM verification passed"; }
          "R_DKIM_REJECT" { weight = 3.0; description = "DKIM verification failed"; }
          "R_DKIM_TEMPFAIL" { weight = 0.5; description = "DKIM temporary failure"; }
          "R_DKIM_PERMFAIL" { weight = 2.0; description = "DKIM permanent failure"; }
          "R_DKIM_NA" { weight = 0.5; description = "No DKIM signature"; }

          # DMARC (Domain-based Message Authentication) symbols
          "DMARC_POLICY_ALLOW" { weight = -1.5; description = "DMARC verification passed"; }
          "DMARC_POLICY_ALLOW_WITH_FAILURES" { weight = -0.5; description = "DMARC passed with some failures"; }
          "DMARC_POLICY_REJECT" { weight = 4.0; description = "DMARC policy requests rejection"; }
          "DMARC_POLICY_QUARANTINE" { weight = 2.5; description = "DMARC policy requests quarantine"; }
          "DMARC_POLICY_SOFTFAIL" { weight = 0.5; description = "DMARC policy is none"; }
          "DMARC_NA" { weight = 0.0; description = "No DMARC policy"; }
          "DMARC_BAD_POLICY" { weight = 1.0; description = "Invalid DMARC policy in DNS"; }

          # ARC (Authenticated Received Chain) symbols
          "ARC_ALLOW" { weight = -1.0; description = "ARC verification passed"; }
          "ARC_REJECT" { weight = 1.0; description = "ARC verification failed"; }
          "ARC_INVALID" { weight = 0.5; description = "ARC chain invalid"; }
          "ARC_DNSFAIL" { weight = 0.0; description = "ARC DNS lookup failed"; }
          "ARC_NA" { weight = 0.0; description = "No ARC signatures"; }
        }
      '';

      "metrics.conf".text = ''
        # Prometheus metrics export
        group "web" {
          path = "/metrics";
        }
      '';

      "gpt.conf".text = ''
        # GPT/LLM integration via LiteLLM proxy
        # NOTE: This file is included INSIDE the gpt{} block from modules.d/gpt.conf
        # Do NOT wrap these settings in another gpt{} block - that causes nested sections

        enabled = true;

        # LiteLLM proxy configuration (OpenAI-compatible API)
        type = "openai";
        url = "http://127.0.0.1:4000/v1/chat/completions";
        # Using MLX quantized model with Harmony filter for efficient inference
        # LiteLLM harmony_filter guardrail strips analysis channel markers
        model = "hera/gpt-oss-120b";

        # Enable GPT analysis for ham messages (default is false)
        # Without this, GPT is skipped for messages with negative scores
        allow_ham = true;

        # Model parameters (required for OpenAI-type endpoints)
        model_parameters = {
          "hera/gpt-oss-120b" = {
            max_completion_tokens = 500;
          }
        };

        # Request timeout - increased from 15s to 30s to handle occasional LLM slowdowns
        # and prevent IO timeout alerts when model inference takes longer
        timeout = 30s;

        # Spam classification prompt - must return JSON with probability and reason fields
        prompt = "Analyze this email for spam. Return JSON only with: {\"probability\": <number 0.0-1.0>, \"reason\": \"<brief explanation>\"}. No other text.";

        # Enable JSON mode - this selects the JSON conversion function
        json = true;
        # Request JSON response format from the API
        include_response_format = true;

        # Feed GPT results back to Bayes classifier for learning
        autolearn = false;

        # Custom header for GPT reasoning (set to null to disable)
        reason_header = "X-GPT-Spam-Reason";

        # Placeholder for API key - will be overridden by include below
        api_key = "placeholder";

        # Load API key from runtime-generated file (injected by systemd preStart)
        # This include has priority 15 (higher than default override.d priority of 10)
        .include(try=true; priority=15) "/var/lib/rspamd/override.d/gpt.conf"
      '';

      "dkim_signing.conf".text = ''
        # Disable DKIM signing for local/private domains
        # DKIM is only useful for public internet domains
        sign_local = false;

        # Still allow signing for authenticated users with public domains
        # but don't fail if key is missing
        allow_hdrfrom_mismatch_sign_networks = false;
      '';

      # Phishing module configuration - whitelist internal domains
      "phishing.conf".text = ''
        # Phishing module configuration for internal domain whitelisting
        # Prevents false positives on internal URLs like nagios.vulcan.lan

        # Keep phishing detection enabled but with local exceptions
        openphish_enabled = false;  # Disable external OpenPhish feed (high resource usage)

        # Exceptions for internal domains - prevents false positives
        # The PHISHED_WHITELISTED symbol allows legitimate internal URLs
        exceptions = {
          PHISHED_WHITELISTED = [
            "$LOCAL_CONFDIR/local.d/maps.d/phishing_whitelist.inc",
          ];
        };
      '';

      # Phishing whitelist map - contains internal domains to exclude from phishing checks
      "maps.d/phishing_whitelist.inc".text = ''
        # Internal domain whitelist for phishing module
        # Format: one domain per line, supports wildcards with glob: prefix
        # These domains will not trigger phishing alerts
        vulcan.lan
        *.vulcan.lan
      '';

      # Settings for whitelisting local domain mail
      "settings.conf".text = ''
        # Whitelist for local vulcan.lan domain mail
        # Applies when both sender and recipient are in vulcan.lan
        # This prevents false positives like R_SUSPICIOUS_URL on internal URLs
        local_mail_whitelist {
          priority = high;

          # Match sender from vulcan.lan or any subdomain (e.g., nagios.vulcan.lan)
          from = "/.*@(.*\\.)?vulcan\\.lan$/i";

          # Match recipient in vulcan.lan (local delivery)
          rcpt = "/.*@(.*\\.)?vulcan\\.lan$/i";

          apply {
            # Disable URL reputation checks for internal mail
            # Internal URLs like nagios.vulcan.lan trigger R_SUSPICIOUS_URL false positives
            symbols_disabled = ["R_SUSPICIOUS_URL", "URIBL_BLOCKED"];
          }
        }
      '';

      # Worker controller configuration for web UI
      "worker-controller.inc".text = ''
        # Enable web UI
        static_dir = "${pkgs.rspamd}/share/rspamd/www";

        # Secure IPs that don't require password
        secure_ip = "127.0.0.1";
        secure_ip = "::1";
      '';

      "rbl.conf".text = ''
        # Disable problematic RBL sources that cause excessive warnings
        # IMPORTANT: Both 'enabled' and 'monitored' must be false to fully disable
        # - enabled = false: Stops RBL from being used for scoring
        # - monitored = false: Stops rspamd from checking DNS availability

        rbls {
          # SenderScore changed DNS response format in 2024
          # Now returns 127.0.4.XX (score) for ALL IPs including test IP 127.0.0.1
          # This causes rspamd to log "DNS spoofing" warnings
          senderscore {
            enabled = false;
            monitored = false;
          }
          senderscore_reputation {
            enabled = false;
            monitored = false;
          }

          # bl.blocklist.de has unreliable DNS (frequent SERVFAIL)
          # Authoritative servers on Cloudflare are misconfigured
          # NOTE: Use 'blocklistde' (no underscore) to match rspamd's default config naming
          blocklistde {
            enabled = false;
            monitored = false;
          }
        }
      '';
    };
  };

  # Systemd service override to inject password into controller configuration
  systemd.services.rspamd = {
    preStart = ''
      # Create override directory for controller worker
      mkdir -p /var/lib/rspamd/override.d

      # Read password from SOPS secret and write to controller override file
      if [ -f "${config.sops.secrets."rspamd-controller-password".path}" ]; then
        PASSWORD_HASH=$(cat "${config.sops.secrets."rspamd-controller-password".path}")
        {
          echo "# Auto-generated password configuration from SOPS"
          echo "password = \"$PASSWORD_HASH\";"
          echo "enable_password = \"$PASSWORD_HASH\";"
        } > /var/lib/rspamd/override.d/worker-controller.inc

        chown rspamd:rspamd /var/lib/rspamd/override.d/worker-controller.inc
        chmod 600 /var/lib/rspamd/override.d/worker-controller.inc
      fi

      # Read LiteLLM API key from SOPS secret and write to GPT module override file
      # Use /var/lib/rspamd because /etc is read-only on NixOS
      if [ -f "${config.sops.secrets."litellm-vulcan-lan".path}" ]; then
        API_KEY=$(cat "${config.sops.secrets."litellm-vulcan-lan".path}")
        {
          echo "# Auto-generated GPT module override from SOPS"
          echo "# This overrides the default enabled=false in modules.d/gpt.conf"
          echo "enabled = true;"
          echo "api_key = \"$API_KEY\";"
        } > /var/lib/rspamd/override.d/gpt.conf

        chown rspamd:rspamd /var/lib/rspamd/override.d/gpt.conf
        chmod 600 /var/lib/rspamd/override.d/gpt.conf
      fi
    '';

    serviceConfig = {
      # Ensure SOPS secrets are available before starting
      LoadCredential = [
        "rspamd-password:${config.sops.secrets."rspamd-controller-password".path}"
        "litellm-api-key:${config.sops.secrets."litellm-vulcan-lan".path}"
      ];
    };
  };

  # Redis instance for Rspamd (separate from other Redis instances)
  services.redis.servers.rspamd = {
    enable = true;
    port = 6381;
    bind = "127.0.0.1";
    requirePass = null; # No password for local-only access
    save = [
      [
        900
        1
      ] # Save after 900 sec if at least 1 key changed
      [
        300
        10
      ] # Save after 300 sec if at least 10 keys changed
      [
        60
        10000
      ] # Save after 60 sec if at least 10000 keys changed
    ];
  };

  # PostgreSQL database for Rspamd history
  services.postgresql.ensureDatabases = [ "rspamd" ];
  services.postgresql.ensureUsers = [
    {
      name = "rspamd";
      ensureDBOwnership = true;
    }
  ];

  # Deploy Sieve scripts and pipe executables for spam/ham learning
  # Sieve scripts reference executables by name from sieve_pipe_bin_dir
  # NOTE: Directory creation moved to dovecot.nix to ensure correct parent/child ordering
  systemd.tmpfiles.rules = [
    # Sieve scripts symlinks (directory created in dovecot.nix)
    "L+ /var/lib/dovecot/sieve/global/rspamd/learn-spam.sieve - - - - ${learnSpamScript}"
    "L+ /var/lib/dovecot/sieve/global/rspamd/learn-ham.sieve - - - - ${learnHamScript}"
    "L+ /var/lib/dovecot/sieve/global/rspamd/move-to-spam.sieve - - - - ${moveToSpamScript}"
    # Retrain folder scripts
    "L+ /var/lib/dovecot/sieve/global/rspamd/retrain.sieve - - - - ${retrainScript}"
    "L+ /var/lib/dovecot/sieve/global/rspamd/retrain-cleanup.sieve - - - - ${retrainCleanupScript}"
    # move-to-good.sieve removed - TrainGood now uses process-good.sieve directly

    # Sieve pipe executables directory
    # Dovecot requires pipe scripts to be in sieve_pipe_bin_dir for security
    "d /var/lib/dovecot/sieve-pipe-bin 0755 dovecot2 dovecot2 -"
    "L+ /var/lib/dovecot/sieve-pipe-bin/rspamd-learn-spam.sh - - - - ${learnSpamShellScript}"
    "L+ /var/lib/dovecot/sieve-pipe-bin/rspamd-learn-ham.sh - - - - ${learnHamShellScript}"
    "L+ /var/lib/dovecot/sieve-pipe-bin/rspamd-retrain.sh - - - - ${retrainShellScript}"
  ];

  # Nginx virtual host for Rspamd web UI
  services.nginx.virtualHosts."rspamd.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/rspamd.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/rspamd.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:11334/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };

    # Metrics endpoint for Prometheus
    locations."/metrics" = {
      proxyPass = "http://127.0.0.1:11334/metrics";
      extraConfig = ''
        # Allow Prometheus to scrape metrics
        allow 127.0.0.1;
        deny all;
      '';
    };
  };

  # Prometheus scrape configuration for Rspamd metrics
  # Using 60s interval instead of global 15s to reduce "allow unauthorized
  # connection from trusted IP" log messages. These messages are informational
  # (not warnings) - they indicate Prometheus scrapes are being accepted from
  # localhost without password authentication, which is expected behavior.
  services.prometheus.scrapeConfigs = [
    {
      job_name = "rspamd";
      scrape_interval = "60s";
      static_configs = [
        {
          targets = [ "localhost:11334" ];
        }
      ];
      metrics_path = "/metrics";
    }
  ];

  # System packages for Rspamd utilities
  environment.systemPackages = with pkgs; [
    rspamd
  ];
}
