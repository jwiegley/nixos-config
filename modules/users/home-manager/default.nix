{
  config,
  lib,
  pkgs,
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
        "nocobase"
        "open-webui"
        "wallabag"
        "teable"
        "sillytavern"
        "opnsense-exporter"
        "technitium-dns-exporter"
        "openspeedtest"
        "lastsignal"
        "container-db"
        "container-web"
        "container-misc"
        "container-monitor"
        "johnw"
      ]
  );
}
