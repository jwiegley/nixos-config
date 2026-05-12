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
        platforms = [ "discord" ];
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
      # memory/skills directories: omit — the upstream module's tmpfiles
      # creates ${stateDir}/.hermes/memories and .hermes/plugins on
      # activation (see nixosModules.nix:712-713). Hermes's defaults
      # already point there. Overriding without a matching tmpfiles
      # entry would force Hermes to mkdir at runtime, which may not
      # have the right group-write bits.
    };
  };

  # User+group inside the guest — must match the host UID so the
  # virtio-fs share permissions line up.
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    createHome = true; # defensive — state share is also tmpfiles'd on host
  };
  users.groups.hermes.gid = hermesGid;
}
