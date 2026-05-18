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

  # Workaround for upstream hermes-agent v0.13.0 timeout defaults that the
  # configured `request_timeout_seconds` / `HERMES_STREAM_READ_TIMEOUT` don't
  # actually override at the httpx layer. Two paths confirmed broken:
  #
  #   1. run_agent.py:7789-7794 builds the streaming `httpx.Timeout(...)` with
  #      hardcoded `connect=30.0` / `pool=30.0` — those fields aren't exposed
  #      via any documented config knob.
  #   2. The same site sets `read=_stream_read_timeout` where the resolved
  #      value falls back to `float(os.getenv("HERMES_STREAM_READ_TIMEOUT",
  #      120.0))` if `get_provider_request_timeout()` returns None. Observed
  #      live: even with HERMES_STREAM_READ_TIMEOUT=600 in .env AND
  #      providers.openrouter.{request_timeout_seconds=600, models.<name>
  #      .timeout_seconds=600} in config.yaml, the firing timeout is exactly
  #      120s + ~14s connection overhead = ~134s. Something in the resolution
  #      chain is yielding 120.0 at the call site (load_config exception
  #      silently swallowed, dotenv overriding, or stale cached config).
  #
  # Monkey-patch `httpx.Timeout` at Python startup via `sitecustomize.py` on
  # the PYTHONPATH so the patch runs before openai/run_agent imports httpx.
  # Bump only the documented upstream defaults (30s connect/pool, 120s read,
  # 30s/5s write) so we don't silently lengthen user-chosen short timeouts in
  # other code paths (e.g. Gemini adapter explicitly sets 15s/600s/30s/30s
  # which we leave alone). Track upstream NousResearch/hermes-agent issue
  # for the proper fix.
  hermesTimeoutShim = pkgs.writeTextDir "sitecustomize.py" ''
    """Hermes-agent v0.13.0 timeout workaround — see hermes-vm.nix."""
    try:
        import httpx as _httpx

        _orig_init = _httpx.Timeout.__init__

        def _patched_init(self, *args, **kwargs):
            _orig_init(self, *args, **kwargs)
            # run_agent.py:7789-7794 hardcodes connect=30.0 / pool=30.0 in
            # the streaming Timeout, and falls back to read=120.0 when
            # neither HERMES_STREAM_READ_TIMEOUT nor a provider
            # request_timeout_seconds is set. Bump only those exact
            # documented defaults so we don't lengthen user-chosen
            # shorter timeouts elsewhere (e.g. Gemini adapter sets
            # connect=15.0 which we leave alone).
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
      # NOTE: settings.model is a flat string in upstream's schema (see
      # nixosModules.nix:267 example: `model = "anthropic/claude-sonnet-4"`).
      # A nested attrset like `{ name, provider }` deep-merges into
      # config.yaml but Hermes' Python reads `model` as a string and
      # gets nothing — every chat-completion call goes out with model=""
      # and LiteLLM bounces it.
      model = agentModel;

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

  # Inject the httpx.Timeout monkey-patch into the hermes-agent service
  # via PYTHONPATH. Python's site initialization auto-imports
  # `sitecustomize.py` from any path in sys.path on startup, before the
  # main script (`bin/hermes`) runs. See `hermesTimeoutShim` in the
  # let-block above for the why.
  systemd.services.hermes-agent.environment = {
    PYTHONPATH = "${hermesTimeoutShim}";
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
