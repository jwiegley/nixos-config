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
      # OPENROUTER_BASE_URL from the env file. The model name MUST match
      # the `agent` slot in /etc/nixos/models.nix so Hermes shares the
      # same routing/fallback story OpenClaw uses for its long-running
      # tool-using sessions. Update both files together when changing.
      model = {
        provider = "openrouter";
        name = "hera/omlx/Qwen3.6-27B-MLX-8bit";
      };
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
