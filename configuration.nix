{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
    ./whisper.nix
  ];

  # --- Boot -----------------------------------------------------------------
  # Existing machine: UEFI + systemd-boot. canTouchEfiVariables is true here
  # (unlike the netcup VPS) because this box has a real, writable EFI NVRAM.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The ESP is a Windows-created 96MB partition shared with the Microsoft
  # bootloader (~25MB). Kernel (13MB) + one initrd (~27MB zstd) barely leaves
  # room for a second generation, so: keep at most 2 boot entries, and
  # xz-compress the initrd (~20MB) so two generations fit with headroom.
  boot.loader.systemd-boot.configurationLimit = 2;
  boot.initrd.compressor = "xz";

  # --- Networking -----------------------------------------------------------
  # LAN box behind the home router: NetworkManager + DHCP (no static config).
  networking.hostName = "nixos-gamer";
  networking.networkmanager.enable = true;

  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [ 22 ];
  };

  # --- Locale / time --------------------------------------------------------
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };

  # German keyboard, on the console and (should X/Wayland ever be added) in X11.
  console.keyMap = "de";
  services.xserver.xkb = {
    layout = "de";
    variant = "";
  };

  # --- Users ----------------------------------------------------------------
  users.users.phylax = {
    isNormalUser = true;
    description = "Phylax";
    extraGroups = [ "networkmanager" "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUfngoK+AS94LbMt7PaxLkquhHtmpa0YiUdDBkuT1iN services@olivermotz.com"
    ];
  };

  # Root key so `nix run .#deploy` can push the closure and activate over SSH
  # without a sudo password prompt (see README for the one-time bootstrap).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUfngoK+AS94LbMt7PaxLkquhHtmpa0YiUdDBkuT1iN services@olivermotz.com"
  ];

  programs.git = {
    enable = true;
    config = {
      user.name = "Oliver Motz";
      user.email = "technical@olivermotz.com";
    };
  };

  # --- SSH ------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "prohibit-password";
  };

  # --- Packages -------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    curl
    tmux
    tree
    htop
    file
    jq
  ];

  # --- Nix ------------------------------------------------------------------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # phylax must be trusted so `nixos-rebuild --target-host` can import the
    # copied closure into the store over SSH.
    trusted-users = [ "root" "phylax" ];
    download-buffer-size = 524288000;
  };

  # NixOS release the machine was first installed from. Leave as-is.
  system.stateVersion = "26.05";
}
