# Guest config for the Hermes Agent microVM.
# Imported by modules/services/hermes-microvm.nix via microvm.vms.hermes.config.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  bridgeAddr,
  vmAddr,
  vmHostname,
  hermesUid,
  hermesGid,
  stateDir,
  tapName,
  ...
}:
let
  # Single source of truth for LLM selection. Mirrors openclaw-vm.nix:41-42
  # so Hermes and OpenClaw stay on the same `agent` model unless one is
  # intentionally pinned. Edit /etc/nixos/models.nix to change.
  models = import ../../models.nix;
  agentModel = models.llm.agent.name;

  # Python startup shims injected into the hermes-agent process via a
  # `sitecustomize.py` on PYTHONPATH — Python's `site` init auto-imports it
  # before `bin/hermes` runs, so both patches land before openai/run_agent
  # and discord.py do their work. Two shims:
  #
  #   1. httpx.Timeout workaround for upstream hermes-agent v0.13.0 timeout
  #      defaults that the configured `request_timeout_seconds` /
  #      `HERMES_STREAM_READ_TIMEOUT` don't actually override at the httpx
  #      layer. Two paths confirmed broken:
  #        - run_agent.py:7789-7794 builds the streaming `httpx.Timeout(...)`
  #          with hardcoded `connect=30.0` / `pool=30.0` — not exposed via
  #          any documented config knob.
  #        - The same site sets `read=_stream_read_timeout`, falling back to
  #          `float(os.getenv("HERMES_STREAM_READ_TIMEOUT", 120.0))`. Observed
  #          live: even with 600 set everywhere the firing timeout is ~134s.
  #      Bump only those exact documented defaults (30→600 connect/pool,
  #      120→600 read) so we don't silently lengthen user-chosen short
  #      timeouts elsewhere (e.g. the Gemini adapter's explicit 15s connect).
  #
  #   2. Discord WS heartbeat-ACK liveness stamp. discord.py 2.7.1's
  #      `KeepAliveHandler.ack()` (discord/gateway.py:217) runs on every
  #      HEARTBEAT_ACK from Discord (~every 41s while the gateway WS is
  #      healthy). The heartbeat *send* fires on a timer regardless of
  #      connection health, so only the ACK proves the socket is truly
  #      alive. We wrap ack() to atomically stamp a wall-clock timestamp
  #      into the heartbeat file; the host-side hermes-health-check reads
  #      its age. A stale stamp means acks have stopped = a genuine zombie,
  #      and — crucially — heartbeats flow even with zero message traffic,
  #      so an idle server can no longer trip the detector. Replaces the
  #      old gateway.log-idleness heuristic that forced a VM restart
  #      roughly daily on a quiet bot. Non-fatal: if discord.py's API
  #      changed, the health check falls back to the gateway.log scrape.
  hermesPyShim = pkgs.writeTextDir "sitecustomize.py" ''
    """Hermes-agent Python startup shims — see hermes-vm.nix."""
    import os
    import time

    # ---- Shim 1: httpx.Timeout workaround (hermes-agent v0.13.0) ----
    try:
        import httpx as _httpx

        _orig_init = _httpx.Timeout.__init__

        def _patched_init(self, *args, **kwargs):
            _orig_init(self, *args, **kwargs)
            try:
                if getattr(self, "connect", None) == 30.0:
                    self.connect = 600.0
                if getattr(self, "pool", None) == 30.0:
                    self.pool = 600.0
                if getattr(self, "read", None) == 120.0:
                    self.read = 600.0
            except Exception:
                pass

        _httpx.Timeout.__init__ = _patched_init
    except Exception:
        # Don't block Hermes startup if httpx isn't importable yet.
        pass

    # ---- Shim 2: Discord WS heartbeat-ACK liveness stamp ----
    _HEARTBEAT_FILE = "${stateDir}/.hermes/logs/discord_ws_heartbeat"

    def _stamp_discord_heartbeat():
        try:
            os.makedirs(os.path.dirname(_HEARTBEAT_FILE), exist_ok=True)
            tmp = _HEARTBEAT_FILE + ".tmp"
            with open(tmp, "w") as _f:
                _f.write(repr(time.time()))
            os.replace(tmp, _HEARTBEAT_FILE)
        except Exception:
            pass

    try:
        import discord.gateway as _dgw

        _orig_ack = _dgw.KeepAliveHandler.ack

        def _patched_ack(self):
            _stamp_discord_heartbeat()
            return _orig_ack(self)

        _dgw.KeepAliveHandler.ack = _patched_ack
    except Exception:
        pass
  '';
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  # ---- Basic guest config ----
  system.stateVersion = "25.11";
  networking.hostName = vmHostname;
  networking.useNetworkd = true;
  networking.enableIPv6 = false;
  boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  boot.kernel.sysctl."net.ipv6.conf.default.disable_ipv6" = 1;

  # Disable systemd-timesyncd. The host-side egress firewall (see
  # hermes-microvm.nix) only allows TCP/UDP 53 and 443 outbound, so NTP
  # to 0.nixos.pool.ntp.org gets dropped and floods the kernel log with
  # hermes-egress-rejected entries (~1000/day). The VM's clock is
  # driven by kvm-clock from the host, which is already accurate.
  services.timesyncd.enable = false;
  # Allow routing 127.0.0.0/8 traffic on non-loopback interfaces.
  # Required for the nftables OUTPUT DNAT below that rewrites localhost
  # connections to the host bridge IP — without this, the kernel
  # refuses to route packets with source 127.0.0.1 via eth0.
  # Matches openclaw-vm.nix:386.
  boot.kernel.sysctl."net.ipv4.conf.all.route_localnet" = 1;

  # ---- Guest resources ----
  # microvm.nix default is 512 MiB. Python+discord.py running the full
  # agent runtime has OOM-killed at 512 MiB under load (anon-rss:191 MiB
  # python3.12 on top of ~250 MiB kernel+systemd). 1 GiB gives ~512 MiB
  # headroom for the agent process.
  microvm.mem = 1024;

  # ---- Guest networking ----
  microvm.interfaces = [
    {
      type = "tap";
      id = tapName; # threaded from hermes-microvm.nix via _module.args
      mac = "02:00:00:0c:1a:02";
    }
  ];
  # Match `e*` (not just `eth*`) — the kernel may assign an `en*` predictable
  # name to the virtio-net interface. OpenClaw uses the same prefix at
  # openclaw-vm.nix:412.
  systemd.network.networks."10-eth" = {
    matchConfig.Name = "e*";
    address = [ "${vmAddr}/30" ];
    routes = [ { Gateway = bridgeAddr; } ];
  };
  networking.nameservers = [ bridgeAddr ];

  # ---- Two-stage DNAT (stage 1: guest OUTPUT) ----
  # Hermes (and any other in-VM service) targets host LiteLLM via
  # http://127.0.0.1:4000 unchanged. This OUTPUT chain rewrites those
  # connections to the bridge gateway IP, where the host's PREROUTING
  # rule (hermes-host-dnat.service) rewrites them back to 127.0.0.1
  # on the host. Same shape as openclaw-vm.nix:443.
  networking.nftables.enable = true;
  networking.nftables.tables.hermes-dnat = {
    family = "ip";
    content = ''
      chain output {
        type nat hook output priority -100; policy accept;
        ip daddr 127.0.0.1 tcp dport { 4000 } dnat to ${bridgeAddr}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Rewrite source 127.0.0.1 → VM eth0 IP for DNAT'ed packets.
        # Without this, the kernel refuses to route loopback-sourced
        # packets out of a non-loopback interface.
        oifname "e*" ip saddr 127.0.0.0/8 masquerade
      }
    '';
  };

  # ---- Virtio-fs shares ----
  # ro-store: Nix store from host (read-only) — standard microvm.nix idiom.
  # state:    /var/lib/hermes from host (read-write).
  # ro-store mountPoint is the host-store stage; microvm.nix's mounts.nix
  # bind-mounts /nix/.ro-store onto /nix/store at boot when
  # writableStoreOverlay is unset (which it intentionally is for Hermes —
  # uv2nix gives us a sealed venv at build time, no runtime store writes).
  microvm.shares = [
    {
      tag = "ro-store";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto = "virtiofs";
    }
    {
      tag = "state";
      source = stateDir;
      mountPoint = stateDir;
      proto = "virtiofs";
    }
  ];

  # The Hermes activation script writes config.yaml, .env, and .managed
  # into ${stateDir}/.hermes/ at NixOS activation time (system.activationScripts).
  # Activation runs in stage 2 BEFORE local-fs.target — so without
  # `neededForBoot`, those writes land on the VM's tmpfs root and the
  # virtio-fs mount silently shadows them at multi-user.target. Forcing
  # the state share into initrd makes the mount visible to activation.
  #
  # Failure mode: if the host's virtiofsd-state.service is slow or
  # crash-looping, the guest will block in initrd waiting on
  # `dev-virtio\x2dfs-state.mount`. Check virtiofsd status on the host
  # (microvm-virtiofsd@hermes.service) before suspecting in-VM issues.
  fileSystems."${stateDir}".neededForBoot = lib.mkForce true;

  # ---- Vulcan CA bundle (HTTPS to internal services) ----
  # Embed the host's root CA at evaluation time so it lands in the
  # nss-cacert bundle at build time. The runtime path inside the VM
  # (${stateDir}/vulcan-root-ca.crt, mounted via virtio-fs) is staged by
  # the host module's tmpfiles entry but is no longer needed for trust —
  # this readFile burns the cert content into the store. Same pattern as
  # openclaw-vm.nix:277.
  security.pki.certificates = [
    (builtins.readFile ../../certs/vulcan-root-ca.crt)
  ];

  # ---- Hermes Agent service ----
  services.hermes-agent = {
    enable = true;
    user = "hermes";
    group = "hermes";
    createUser = false; # We declare the user explicitly below to match UID 932.
    stateDir = stateDir;
    addToSystemPackages = false; # Known bug #6044 with HERMES_HOME export.
    container.enable = false; # The microVM IS the sandbox.

    # Upstream restructured pyproject.toml so discord.py / telegram / slack
    # only install via the `messaging` extras group. Without this, the
    # gateway logs `Discord: discord.py not installed` and silently drops
    # the Discord adapter (observed 2026-05-22 after a flake.lock bump).
    extraDependencyGroups = [ "messaging" ];

    environmentFiles = [ "${stateDir}/env" ];

    settings = {
      # Declarative agent config. The upstream module deep-merges this
      # into ~/.hermes/config.yaml; the `.managed` marker blocks
      # `hermes config set` so this file is the only source of truth.
      logging.level = "INFO";
      gateway = {
        enabled = true;
        platforms = [
          "discord"
          "api_server"
        ];
      };
      discord = {
        # Token, allowlists, channel scoping come from env vars
        # (DISCORD_BOT_TOKEN, DISCORD_ALLOWED_USERS,
        # DISCORD_ALLOWED_CHANNELS, DISCORD_HOME_CHANNEL,
        # DISCORD_REQUIRE_MENTION). YAML keys below are the knobs that
        # DO NOT have env-var equivalents. If an env var IS set, it
        # overrides the YAML value at runtime — so DISCORD_REQUIRE_MENTION
        # in /var/lib/hermes/env wins over `require_mention` here.
        require_mention = true;
        auto_thread = true;
        reactions = true;
        allow_mentions = {
          everyone = false;
          roles = false;
          users = true;
          replied_user = true;
        };
      };
      # Model routing — Hermes consumes OPENROUTER_API_KEY and
      # OPENROUTER_BASE_URL from the env file. The model identifier is
      # pulled from /etc/nixos/models.nix (`llm.agent.name`) so it tracks
      # the same setting OpenClaw uses for its long-running tool-using
      # sessions; change models.nix to update both modules at once.
      #
      # IMPORTANT: in Hermes v0.14 the model field accepts either a flat
      # string OR a dict with {default, provider, base_url, api_key, ...}.
      # We use the dict form because:
      #
      #   1. The openrouter provider profile (plugins/model-providers/
      #      openrouter/__init__.py:99) hardcodes base_url to
      #      `https://openrouter.ai/api/v1` and only honors OPENROUTER_API_KEY
      #      as an env var — it ignores OPENROUTER_BASE_URL entirely.
      #   2. The streaming-on chat path used to bypass this by reading
      #      os.environ["OPENROUTER_BASE_URL"] directly, but we have
      #      display.streaming = false below (sticky 30s timeout bug), so
      #      non-streaming traffic now flows through the provider profile
      #      and hits the hardcoded openrouter.ai URL with a LiteLLM virtual
      #      key — every call 401s with "Missing Authentication header".
      #   3. Setting model.provider = "custom" + model.base_url + model.api_key
      #      triggers the credential_pool custom-provider branch
      #      (agent/credential_pool.py:`model_provider == "custom"`), which
      #      routes through the supplied endpoint directly. Same fix the
      #      auxiliary block below uses for title_generation / triage_specifier.
      #   4. `${...}` syntax is expanded at config-load time by
      #      _expand_env_vars() (config.py:3838) reading from os.environ,
      #      which already has the values from environmentFiles=.../env.
      #
      # The earlier "Python reads model as a string and gets nothing"
      # warning was for an older Hermes version. v0.14's model resolver
      # (hermes_cli/dump.py:`model_cfg.get("default") or .get("model") or
      # .get("name")`) reads the name from any of those keys.
      model = {
        default = agentModel;
        provider = "custom";
        base_url = "\${OPENROUTER_BASE_URL}";
        api_key = "\${OPENROUTER_API_KEY}";
      };

      # Per-provider request timeout. The default OpenAI-wire client
      # timeout fires at 30s before the first byte arrives, which is
      # too short for a 27B MLX model that needs ~30-60s of prompt
      # evaluation on a 3-4k-token prompt. Setting both per-provider
      # and per-model (per-model has higher priority per
      # hermes_cli/timeouts.py).
      providers.openrouter = {
        request_timeout_seconds = 600;
        models.${agentModel} = {
          timeout_seconds = 600;
          stale_timeout_seconds = 600;
        };
      };

      # Disable streaming. The streaming code path's 30s "Streaming
      # failed before delivery" timeout is sticky despite all timeout
      # overrides — likely because the OpenAI SDK Stream constructor
      # has an early-response timer we haven't located. Non-streaming
      # uses the cleaner _resolved_api_call_timeout() path which
      # honors `request_timeout_seconds` above. Trade-off: Discord
      # gets the full reply at once instead of progressive chunks.
      display.streaming = false;

      # Reduce retry count — at 30s per attempt × 3 retries this was
      # spamming the Discord channel with "Retrying in X.Xs" messages
      # before each failed attempt. Single attempt fails fast and
      # cleanly.
      agent.max_retries = 1;

      # memory/skills directories: omit — the upstream module's tmpfiles
      # creates ${stateDir}/.hermes/memories and .hermes/plugins on
      # activation (see nixosModules.nix:712-713). Hermes's defaults
      # already point there. Overriding without a matching tmpfiles
      # entry would force Hermes to mkdir at runtime, which may not
      # have the right group-write bits.

      # Route auxiliary tasks (title generation, triage, etc.) through
      # our LiteLLM proxy.  Hermes' internal `OPENROUTER_BASE_URL`
      # constant is hardcoded to `https://openrouter.ai/api/v1`
      # (hermes_constants.py:342) and the credential pool builds its
      # default base_url from that constant, NOT from the env var.
      # That means the main streaming chat path (which reads
      # `os.environ["OPENROUTER_BASE_URL"]` directly in run_agent.py)
      # works, but auxiliary tasks fail with HTTP 401 against the real
      # OpenRouter cloud using our LiteLLM virtual key.
      #
      # Setting both base_url+api_key here triggers the `"custom"`
      # provider branch in auxiliary_client._resolve_auxiliary_for_call
      # (auxiliary_client.py:3822-3824), which bypasses the credential
      # pool entirely and uses the supplied endpoint directly. The
      # `${VAR}` syntax is expanded at config-load time by Hermes'
      # `_expand_env_vars()` (config.py:3838) reading from os.environ,
      # which already has the values from environmentFiles=.../env.
      auxiliary = {
        title_generation = {
          base_url = "\${OPENROUTER_BASE_URL}";
          api_key = "\${OPENROUTER_API_KEY}";
        };
        triage_specifier = {
          base_url = "\${OPENROUTER_BASE_URL}";
          api_key = "\${OPENROUTER_API_KEY}";
        };
      };
    };
  };

  # Inject the Python startup shims (httpx.Timeout patch + Discord WS
  # heartbeat-ACK liveness stamp) into the hermes-agent service via
  # PYTHONPATH. Python's site initialization auto-imports
  # `sitecustomize.py` from any path in sys.path on startup, before the
  # main script (`bin/hermes`) runs. See `hermesPyShim` in the
  # let-block above for the why.
  systemd.services.hermes-agent.environment = {
    PYTHONPATH = "${hermesPyShim}";
    # api_server Platform — exposes OpenAI-compatible /v1/chat/completions
    # for the OpenClaw↔Hermes MCP bridge (host's hermes-mcp.service).
    # `API_SERVER_KEY` is supplied via environmentFiles=…/env (sops);
    # `X-Hermes-Session-Key` requests from the host must present that key.
    # Guest firewall scopes inbound traffic to ${bridgeAddr} only.
    API_SERVER_ENABLED = "true";
    API_SERVER_HOST = "0.0.0.0";
    API_SERVER_PORT = "8080";
  };

  # User+group inside the guest — must match the host UID so the
  # virtio-fs share permissions line up.
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    createHome = true; # defensive — state share is also tmpfiles'd on host
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      # Ephemeral debug key generated on the host at /root/.ssh/hermes-debug.
      # Used for interactive debugging from the host (Claude shelling in).
      # Remove once debugging is complete and replace with the proper
      # Phase-2 nightly-report probe key, mirroring the openclaw pattern.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINYXL7oqQT3RgRbnWRQNcKNrywkP3TV2F5m8w02+eGUB claude-hermes-debug"
    ];
  };
  users.groups.hermes.gid = hermesGid;

  # ---- In-VM sshd (debug only) ----
  # Listens on the bridge IP so the host (and only the host, via the
  # extraInputRules nft restriction) can reach it.  Mirrors openclaw-vm.nix.
  services.openssh = {
    enable = true;
    openFirewall = false;
    listenAddresses = [
      {
        addr = vmAddr;
        port = 22;
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "hermes" ];
    };
  };
  networking.firewall = {
    enable = true;
    extraInputRules = ''
      ip saddr ${bridgeAddr} tcp dport 22 accept comment "claude debug ssh from host bridge"
      ip saddr ${bridgeAddr} tcp dport 8080 accept comment "hermes api_server from host bridge (used by host hermes-mcp.service)"
    '';
  };
}
