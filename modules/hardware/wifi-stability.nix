{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # WiFi Stability Fix for Asahi Linux
  # ============================================================================
  #
  # The Broadcom WiFi driver (brcmfmac) on Apple Silicon has known stability
  # issues under heavy load. This module applies workarounds to prevent system
  # crashes during nixos-rebuild and other network-intensive operations.
  #
  # Known Issue:
  # - brcmfmac driver causes kernel panics during high CPU + network load
  # - Particularly affects nixos-rebuild operations (502 WiFi errors logged)
  # - See: https://github.com/AsahiLinux/linux/issues
  #
  # Workarounds Applied:
  # 1. Disable WiFi power management to improve stability
  # 2. Additional kernel parameters may be added as issues are discovered
  # ============================================================================

  # Disable WiFi power save mode to prevent driver instability
  boot.extraModprobeConfig = ''
    # Disable power save on Broadcom WiFi (brcmfmac)
    # This prevents crashes under heavy network load
    options brcmfmac power_save=0
  '';

  # Optional: Enable high priority workqueue for SDIO
  # Uncomment if stability issues persist
  # boot.kernelParams = [
  #   "brcmfmac.sdio_wq_highpri=1"
  # ];
}
