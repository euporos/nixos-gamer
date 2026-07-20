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

  # Wake-on-LAN on the wired NIC (enp8s0, MAC c8:fe:0f:fd:66:93). The card
  # advertises `Supports Wake-on: pumbg`, so magic-packet ("g") works. This
  # runs `ethtool -s enp8s0 wol g` via a systemd service; NM's default
  # wake-on-lan setting is "preserve", so it does not clobber it. Also requires
  # the firmware "Power On by PCI-E/onboard LAN" setting to be enabled.
  # Remote OS choice: WoL always lands here (NixOS = systemd-boot default);
  # to boot Windows once, `bootctl set-oneshot auto-windows && reboot`.
  networking.interfaces."enp8s0".wakeOnLan.enable = true;

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
    # euporious.gamer power control from the NAS VM: WoL lands here (NixOS), and
    # this key runs `bootctl set-oneshot auto-windows && reboot` (-> Windows) or
    # `systemctl poweroff`. Private half lives on the NAS at
    # /home/phylax/.ssh/gamer_control (euporious runs as phylax).
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE6fpoC4JQmiyzf9ls9z6aM1o7c4nCU7C/5F9GrAg3nr euporious-gamer-control@nas-nixos"
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
