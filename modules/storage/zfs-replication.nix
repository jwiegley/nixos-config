{ config, lib, pkgs, ... }:

{
  services.syncoid = {
    enable = false;

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
          "--no-privilege-elevation"  # Run as root (configured in systemd)
          "--force-delete"            # Allow deletion of snapshots on target that don't exist on source
        ];
      };

      # Replicate rpool/nix
      "rpool-nix" = {
        source = "rpool/nix";
        target = "tank/Backups/rpool/nix";

        extraArgs = [
          "--no-privilege-elevation"
          "--force-delete"
        ];
      };

      # Replicate rpool/root
      "rpool-root" = {
        source = "rpool/root";
        target = "tank/Backups/rpool/root";

        extraArgs = [
          "--no-privilege-elevation"
          "--force-delete"
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
