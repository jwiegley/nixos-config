{ config, lib, pkgs, ... }:

{
  services.syncoid = {
    enable = true;

    # Run daily at 4:00 AM
    interval = "*-*-* 04:00:00";

    # Commands for replicating each rpool filesystem
    commands = {
      # Replicate rpool/home
      "rpool-home" = {
        source = "rpool/home";
        target = "tank/Backups/rpool/home";

        # Extra arguments for the replication
        extraArgs = [
          "--no-sync-snap"        # Don't create a sync snapshot
          "--no-privilege-elevation"  # Run as root (configured in systemd)
        ];
      };

      # Replicate rpool/nix
      "rpool-nix" = {
        source = "rpool/nix";
        target = "tank/Backups/rpool/nix";

        extraArgs = [
          "--no-sync-snap"
          "--no-privilege-elevation"
        ];
      };

      # Replicate rpool/root
      "rpool-root" = {
        source = "rpool/root";
        target = "tank/Backups/rpool/root";

        extraArgs = [
          "--no-sync-snap"
          "--no-privilege-elevation"
        ];
      };
    };

    # Common arguments applied to all commands
    commonArgs = [
      "--skip-parent"    # Skip parent datasets
    ];
  };

  # Optional: Create systemd service dependencies to ensure proper ordering
  systemd.services = lib.mkMerge [
    {
      "syncoid-rpool-home" = {
        after = [ "sanoid.service" ];
        wants = [ "sanoid.service" ];
      };
    }
    {
      "syncoid-rpool-nix" = {
        after = [ "sanoid.service" ];
        wants = [ "sanoid.service" ];
      };
    }
    {
      "syncoid-rpool-root" = {
        after = [ "sanoid.service" ];
        wants = [ "sanoid.service" ];
      };
    }
  ];
}