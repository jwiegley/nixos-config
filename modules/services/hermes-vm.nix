# Guest config for the Hermes Agent microVM.
# Imported by modules/services/hermes-microvm.nix via microvm.vms.hermes.config.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  bridgeAddr,
  vmHostname,
  hermesUid,
  hermesGid,
  stateDir,
  tapName,
  ...
}:
let
  vmAddr = "10.99.1.2";
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

  # ---- Guest networking ----
  microvm.interfaces = [
    {
      type = "tap";
      id = tapName; # threaded from hermes-microvm.nix via _module.args
      mac = "02:00:00:0c:1a:02";
    }
  ];
  systemd.network.networks."10-eth" = {
    matchConfig.Name = "eth*";
    address = [ "${vmAddr}/30" ];
    routes = [ { Gateway = bridgeAddr; } ];
  };
  networking.nameservers = [ bridgeAddr ];

  # ---- Virtio-fs shares ----
  # ro-store: Nix store from host (read-only) — standard microvm.nix idiom.
  # state:    /var/lib/hermes from host (read-write).
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

  # ---- Vulcan CA bundle (HTTPS to internal services) ----
  # The host's CA cert is staged via tmpfiles into the state share, then
  # systemd reads it from the standard location. Same pattern as the
  # OpenClaw VM.
  security.pki.certificateFiles = [
    "${stateDir}/vulcan-root-ca.crt"
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
    restart = "always";
    restartSec = 5;

    environmentFiles = [ "${stateDir}/env" ];

    settings = {
      # Declarative agent config. The upstream module deep-merges this
      # into ~/.hermes/config.yaml; the `.managed` marker blocks
      # `hermes config set` so this file is the only source of truth.
      logging.level = "INFO";
      gateway.enabled = true;
      gateway.platforms = [ "discord" ];
      discord = {
        # Token, allowlists, channel scoping are all read from env vars
        # (DISCORD_BOT_TOKEN, DISCORD_ALLOWED_USERS,
        # DISCORD_ALLOWED_CHANNELS, DISCORD_HOME_CHANNEL,
        # DISCORD_REQUIRE_MENTION). Settings here are the YAML-level
        # knobs that do NOT have env-var equivalents.
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
      # Memory & skills — keep within stateDir so virtio-fs persists.
      memory.directory = "${stateDir}/.hermes/memories";
      skills.directory = "${stateDir}/.hermes/skills";
    };
  };

  # User+group inside the guest — must match the host UID so the
  # virtio-fs share permissions line up.
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
  };
  users.groups.hermes.gid = hermesGid;
}
