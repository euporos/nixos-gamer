{ config, ... }:

{
  # Proprietary NVIDIA driver for the GTX 1080 Ti (Pascal, sm_61).
  # Pascal support ends with the 580 branch — `production`/`latest` (590+)
  # no longer ship kernels for this card, so pin legacy_580 explicitly.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    # The open kernel module only supports Turing (RTX 20xx) and newer.
    open = false;
    modesetting.enable = true;
    powerManagement.enable = false;
    nvidiaSettings = false;
  };

  # CDI device injection for containers: podman run --device nvidia.com/gpu=all
  hardware.nvidia-container-toolkit.enable = true;
}
