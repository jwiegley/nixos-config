{ config, lib, pkgs, ... }:

{
  # Enable hardware graphics acceleration
  # Required for GPU support including Vulkan on Asahi Linux
  hardware.graphics = {
    enable = true;
    # Enable 32-bit support for compatibility (if needed)
    enable32Bit = false;  # Not needed on aarch64
  };

  # Use modesetting driver for Apple Silicon GPU
  # Mesa provides OpenGL and Vulkan support via the Asahi driver
  services.xserver.videoDrivers = [ "modesetting" ];
}
