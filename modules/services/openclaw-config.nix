{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = (import ../../models.nix).llm.agent;

  # Derive the single OpenClaw model entry from models.yaml `llm.agent`.
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
        allowFrom = [ "639822278535807007" ];
        guilds = {
          "1477037634931916891" = {
            requireMention = false;
            users = [ "639822278535807007" ];
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
