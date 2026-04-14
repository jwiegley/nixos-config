{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager = {
    # Use the same nixpkgs as the system
    useGlobalPkgs = true;

    # Install packages to /etc/profiles instead of ~/.nix-profile
    useUserPackages = true;

    # Backup existing files when they conflict with home-manager files
    backupFileExtension = "hm-bak";

    # Pass hostname and inputs to home-manager modules so they can be used
    # by the shared johnw.nix cross-platform module
    extraSpecialArgs = {
      hostname = config.networking.hostName;
      inherit inputs;
    };
  };

  # Fix Home Manager services to wait for nix-daemon
  # This prevents "Connection reset by peer" errors during activation
  systemd.services = lib.mkMerge (
    map
      (username: {
        "home-manager-${username}" = {
          after = [ "nix-daemon.socket" ];
          wants = [ "nix-daemon.socket" ];
          serviceConfig = {
            # Restart on failure to handle transient nix-daemon issues
            Restart = "on-failure";
            RestartSec = "5s";
          };
          environment = {
            # Ensure the service can connect to nix-daemon
            NIX_REMOTE = "daemon";
          };
        };
      })
      [
        "changedetection"
        "litellm"
        "open-webui"
        "perplexica"
        "wallabag"
        "teable"
        "opnsense-exporter"
        "technitium-dns-exporter"
        "openspeedtest"
        "container-db"
        "container-web"
        "container-misc"
        "container-monitor"
        "johnw"
      ]
  );
}
