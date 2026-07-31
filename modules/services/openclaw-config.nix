{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = (import ../../models.nix).llm.agent;

  # Derive the single OpenClaw model entry from models.nix `llm.agent`.
  # The retry-policy fields (maxSeconds / initialDelay / maxDelay) are *not*
  # part of openclaw's model schema, so they are intentionally omitted.
  derivedModel = {
    id = agent.name;
    name = agent.name;
    inherit (agent)
      api
      reasoning
      input
      cost
      contextWindow
      maxTokens
      ;
  };

  # Structural mirror of /tmp/openclaw-structural.json. Every secret leaf is
  # left `null`; per-credential SOPS secrets are merged in at host build time
  # via `jq -s '.[0] * .[1]'`.
  defaultConfig = {
    meta = {
      lastTouchedVersion = "2026.5.7";
      lastTouchedAt = "2026-05-14T17:21:02.136Z";
    };

    auth = {
      profiles = {
        "vulcan:manual" = {
          provider = "vulcan";
          mode = "token";
        };
      };
      cooldowns = {
        billingBackoffHours = 2;
        failureWindowHours = 1;
      };
    };

    models = {
      mode = "merge";
      providers = {
        vulcan = {
          baseUrl = "http://127.0.0.1:4000/v1";
          apiKey = null;
          api = "openai-completions";
          models = [ derivedModel ];
        };
      };
    };

    agents = {
      defaults = {
        model = {
          primary = "vulcan/${agent.name}";
          fallbacks = [ ];
        };
        models = {
          "vulcan/${agent.name}" = { };
        };
        workspace = "~/.openclaw/workspace";
        memorySearch = {
          enabled = true;
          provider = "openai";
          remote = {
            baseUrl = "http://127.0.0.1:4000/v1";
            apiKey = "dummy-key";
          };
          model = "vulcan/hera/bge-m3";
        };
        contextPruning = {
          mode = "cache-ttl";
          ttl = "1h";
        };
        compaction = {
          mode = "safeguard";
        };
        typingMode = "instant";
        timeoutSeconds = 7200;
        heartbeat = {
          every = "1h";
        };
        sandbox = {
          mode = "off";
          workspaceAccess = "rw";
          scope = "agent";
          docker = {
            network = "bridge";
          };
        };
      };
    };

    tools = {
      web = {
        search = {
          provider = "perplexity";
        };
      };
      message = {
        crossContext = {
          allowWithinProvider = true;
          allowAcrossProviders = true;
        };
      };
      elevated = {
        enabled = true;
      };
      exec = {
        security = "full";
        ask = "off";
      };
    };

    # Canary-triage log sink -- REVERTED 2026-07-31, kept here as the exact recipe.
    #
    # openclaw's structured logger defaults to a rolling file under the guest's tmp dir
    # (/tmp/openclaw/openclaw-YYYY-MM-DD.log, src/logging/logger.ts:47-58). That path is
    # INSIDE the microVM and not visible from the host, which is why the Discord preflight
    # drop reasons never appeared in gateway-vm.log: that file is the VM's stdout capture,
    # while logVerbose() writes through getLogger().debug() to the structured file instead.
    # There is no env override for the path (only OPENCLAW_LOG_LEVEL and OPENCLAW_LOG_PREFIX
    # exist), so it has to be config -- which is why this pairs with the env var rather than
    # replacing it.
    #
    # Uncomment together with OPENCLAW_LOG_LEVEL = "debug" in openclaw-vm.nix and restart
    # microvm@openclaw when a canary needs triage. Left off because debug level can write
    # outbound request bodies (i.e. tokens) to a file on the shared state dir.
    #
    # logging = {
    #   file = "/var/lib/openclaw/.openclaw/logs/openclaw-debug.log";
    # };

    commands = {
      native = "auto";
      nativeSkills = "auto";
      restart = true;
      ownerDisplay = "raw";
    };

    channels = {
      whatsapp = {
        enabled = true;
        dmPolicy = "allowlist";
        allowFrom = [ "+19194299581" ];
        groupPolicy = "allowlist";
        groupAllowFrom = [ "XXXXXXXXXXXXXXXXXX@g.us" ];
        debounceMs = 0;
        mediaMaxMb = 50;
      };
      discord = {
        enabled = true;
        token = null;
        groupPolicy = "allowlist";
        streaming = { };
        dmPolicy = "allowlist";
        # Accept bot-authored messages ONLY when they @mention @Claw. Required for the
        # round-trip canary: openclaw drops bot authors outright by default ("none"), which
        # is why every probe from Hermes went unanswered all of 2026-07-30 while @Claw
        # answered the operator normally. Established from openclaw's own source rather
        # than inferred -- DiscordAccountConfig includes ChannelBotInteractionConfig
        # (src/config/types.discord.ts:272, types.channel-messaging-common.ts:87), and
        # docs/channels/discord.md:1639 recommends exactly this value over `true`.
        #
        # "mentions" is the tight setting: general bot chatter is still dropped, and only a
        # message that mentions @Claw is dispatched. It bypasses the human allowFrom list
        # (bots are never in it) but NOT the guild/channel scoping, so reach is bounded by
        # where the bot can post.
        #
        # Setting this also activates openclaw's shared bot-loop protection: 20 events per
        # bot pair per 60s window, then a 60s cooldown (unordered pair key, so both
        # directions share one counter; state is in-process and clears on restart).
        # The canary sends 2 messages per 15 minutes, so it sits far under that budget.
        #
        # Ping-pong exposure with Hermes now in guilds.<id>.users below: a bot author must
        # still clear preflight.ts:695, which needs a real parsed @mention or a native
        # reply to @Claw. Other bots still die at :563. @everyone from a bot is
        # deliberately blind (preflight.ts:447: `mentionedEveryone && (!authorIsBot ||
        # isPluralKit)`), and plain-name matching contributes nothing (no mentionPatterns,
        # so buildMentionRegexes returns []). The one reachable loop is a Hermes NATIVE
        # REPLY, which sets implicitMention = "reply_to_bot" and satisfies :695; at
        # 3-285s per turn the 20-events/60s guard would never trip. If a real bound is
        # wanted, botLoopProtection = { maxEventsPerWindow; windowSeconds; cooldownSeconds; }
        # is a real key in the deployed schema (src/config/types.channels.ts) -- but it is
        # NOT verified that this NixOS module accepts it. Follow-up, not part of the fix.
        allowBots = "mentions";
        allowFrom = [
          "639822278535807007"
          # Hermes' bot user id — setup step 2 of docs/DISCORD_CANARY_SETUP.md.
          # The round-trip canary posts an @Claw mention AS Hermes, and with
          # dmPolicy/groupPolicy = "allowlist" @Claw silently drops a sender that
          # is not listed, which is why the canary reported ok=0 on every run from
          # the moment it was enabled (post_http=200, "no reply within timeout").
          # NECESSARY BUT NOT SUFFICIENT. An earlier version of this comment claimed
          # "THIS is what unblocked the round-trip canary: it went green at 12:46 on
          # 2026-07-30 (rt=7.4s)". That green was an artifact: until the probe was
          # hardened (gen 2325, 21:39:35) it accepted ANY recent message from the
          # target as a reply, so @Claw answering the operator scored as a canary
          # success. Every green before 21:39 is suspect; only `reply+nonce` and
          # `reply+reference` attributions after it mean anything.
          #
          # allowFrom feeds resolveDiscordTextCommandAccess (control-command
          # authorization) and the DM path. It does NOT feed the guild member gate at
          # message-handler.preflight.ts:563, which is the gate that was actually
          # dropping Hermes -- see guilds.<id>.users below.
          "1503619790261194793"
        ];
        guilds = {
          "1477037634931916891" = {
            requireMention = false;
            # Operator + Hermes. The second entry is LOAD-BEARING, not a widened grant.
            #
            # A NON-EMPTY users list sets hasAccessRestrictions = true for EVERY sender
            # in this guild (allow-list.ts:238-240,
            # `channelUsers = channelConfig?.users ?? guildInfo?.users`), and
            # preflight.ts:563 then drops any sender absent from it. That drop is 132
            # lines BEFORE the allowBots = "mentions" gate at preflight.ts:695, so for a
            # bot missing from this list allowBots is read (:235) and never consulted --
            # which is exactly why setting it correctly changed nothing for a day.
            # Matching is id-only (dangerouslyAllowNameMatching is unset; leave it that
            # way). allowFrom is a DIFFERENT list and does not open :563.
            #
            # A 2026-07-30 test added Hermes here and was reverted the same day on the
            # conclusion that "guild `users` does not gate bot authors". That conclusion
            # was WRONG. It rested on the canary run completing 23:26:16, whose 420s
            # window began 3.5 min after the 23:15:43 VM boot -- warmup, the same
            # invalidation documented for the allowFrom tests above. Verified at store
            # level 2026-07-31: gen 2327 (23:15:19) shipped config template
            # yj9ykskj... with users length 2; gens 2326/2328/2329 shipped 23ql5k6p...
            # with length 1. All three genuine reply+nonce successes (23:51:24, 00:05:13,
            # 00:20:59) fall inside the 23:15:43-00:29:25 window and nowhere else --
            # 0 successes in the 18 runs on either side. The revert landed 9 min after
            # the last success.
            #
            # Do NOT trust any canary result within ~20 min of a VM restart (first
            # success was ~36 min post-boot), and do not remove either id without
            # re-running that A/B/A.
            users = [
              "639822278535807007"
              "1503619790261194793"
            ];
            # channels intentionally EMPTY. A per-channel grant for #interconnect
            # (requireMention = true + a users list) was added 2026-07-30 as a
            # least-privilege alternative to a guild-wide users entry, then REVERTED
            # the same day: @Claw stopped processing inbound Discord messages from the
            # moment it took effect (VM restart 13:21), with gateway-vm.log going
            # silent and no dispatch activity for probes at 15:46 and 15:58. openclaw
            # RETAINS these keys (config-drift keys_removed stayed 0) but evidently
            # does not honour them the way the guild submodule's own key names imply,
            # and an unhonoured allowlist that silently drops everything is worse than
            # no entry. channels.discord.allowFrom alone is sufficient and proven.
            channels = { };
          };
        };
      };
    };

    gateway = {
      mode = "local";
      auth = {
        mode = "token";
        token = null;
      };
      tailscale = {
        mode = "off";
      };
      remote = {
        url = "ws://127.0.0.1:18789";
        transport = "direct";
      };
      controlUi = {
        dangerouslyAllowHostHeaderOriginFallback = true;
      };
    };

    skills = {
      entries = {
        gh-issues = {
          apiKey = null;
          enabled = false;
        };
        "1password" = {
          enabled = false;
        };
        imsg = {
          enabled = false;
        };
        apple-notes = {
          enabled = false;
        };
        apple-reminders = {
          enabled = false;
        };
        bear-notes = {
          enabled = false;
        };
        blogwatcher = {
          enabled = false;
        };
        blucli = {
          enabled = false;
        };
        bluebubbles = {
          enabled = false;
        };
        camsnap = {
          enabled = false;
        };
        clawhub = {
          enabled = false;
        };
        coding-agent = {
          enabled = false;
        };
        eightctl = {
          enabled = false;
        };
        gemini = {
          enabled = false;
        };
        gifgrep = {
          enabled = false;
        };
        github = {
          enabled = false;
        };
        gog = {
          enabled = false;
        };
        goplaces = {
          enabled = false;
        };
        mapq = {
          enabled = false;
        };
        model-usage = {
          enabled = false;
        };
        nano-pdf = {
          enabled = false;
        };
        notion = {
          enabled = false;
        };
        obsidian = {
          enabled = false;
        };
        openai-whisper = {
          enabled = false;
        };
        openai-whisper-api = {
          enabled = false;
        };
        openhue = {
          enabled = false;
        };
        oracle = {
          enabled = false;
        };
        ordercli = {
          enabled = false;
        };
        peekaboo = {
          enabled = false;
        };
        sag = {
          enabled = false;
        };
        session-logs = {
          enabled = false;
        };
        sherpa-onnx-tts = {
          enabled = false;
        };
        slack = {
          enabled = false;
        };
        songsee = {
          enabled = false;
        };
        sonoscli = {
          enabled = false;
        };
        spotify-player = {
          enabled = false;
        };
        summarize = {
          enabled = false;
        };
        things-mac = {
          enabled = false;
        };
        tmux = {
          enabled = false;
        };
        trello = {
          enabled = false;
        };
        video-frames = {
          enabled = false;
        };
        voice-call = {
          enabled = false;
        };
        wacli = {
          enabled = false;
        };
        xurl = {
          enabled = false;
        };
      };
    };

    acp = {
      enabled = true;
      backend = "acpx";
      defaultAgent = "claude";
      allowedAgents = [ "claude" ];
    };

    plugins = {
      allow = [
        "memory-qdrant"
        "whatsapp"
        "discord"
        "perplexity"
        "acpx"
        "brave"
        "lobster"
      ];
      load = {
        paths = [ "/var/lib/openclaw/.openclaw/workspace/skills/memory-qdrant" ];
      };
      slots = {
        memory = "memory-qdrant";
      };
      entries = {
        discord = {
          enabled = true;
        };
        lobster = {
          enabled = true;
        };
        memory-qdrant = {
          enabled = true;
          # autoCapture writes end-of-conversation snippets to Qdrant via the
          # `agent_end` typed hook. As a non-bundled plugin, memory-qdrant is
          # denied conversation access by default, so that hook was silently
          # blocked (gateway log 2026-06-02: "must set
          # plugins.entries.memory-qdrant.hooks.allowConversationAccess=true"),
          # neutering autoCapture while leaving autoRecall + explicit
          # memory_store/search/forget working. Grant it so autoCapture=true
          # actually takes effect.
          hooks = {
            allowConversationAccess = true;
          };
          config = {
            autoCapture = true;
            autoRecall = true;
            captureMaxChars = 512;
            maxMemorySize = 100000;
            qdrantApiKey = null;
            qdrantUrl = "http://127.0.0.1:6333";
          };
        };
        whatsapp = {
          enabled = true;
        };
        brave = {
          enabled = true;
          config = {
            webSearch = {
              apiKey = null;
            };
          };
        };
        perplexity = {
          enabled = true;
        };
        acpx = {
          enabled = true;
        };
      };
      bundledDiscovery = "compat";
    };

    messages = {
      groupChat = {
        visibleReplies = "message_tool";
      };
    };

    wizard = {
      lastRunAt = "2026-05-14T17:21:01.766Z";
      lastRunVersion = "2026.5.7";
      lastRunCommand = "doctor";
      lastRunMode = "local";
    };
  };
in
{
  options.services.openclaw.config = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = defaultConfig;
    description = ''
      Structural openclaw.json. Every key from the live config is rendered
      here; secret leaves (gateway.auth.token, channels.discord.token,
      models.providers.vulcan.apiKey, plugins.entries.brave.config.webSearch.apiKey,
      plugins.entries."memory-qdrant".config.qdrantApiKey, skills.entries.gh-issues.apiKey)
      remain `null` and are merged in at host build time from per-credential
      SOPS secrets via `jq -s '.[0] * .[1]'`.
    '';
  };

  config = {
    nixpkgs.overlays = [
      (final: prev: {
        openclaw-config-template = prev.writeText "openclaw-config-template" (
          builtins.toJSON config.services.openclaw.config
        );
      })
    ];
  };
}
