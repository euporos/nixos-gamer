{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
    ./whisper.nix
  ];

  # --- Boot -----------------------------------------------------------------
  # UEFI + GRUB. canTouchEfiVariables is true because this box has a real,
  # writable EFI NVRAM (creates the GRUB boot entry on install).
  #
  # Why GRUB and not systemd-boot: the ESP is a Windows-created 96MB partition
  # shared with the Microsoft bootloader (~27MB). systemd-boot (Boot Loader
  # Spec) must copy the kernel (13MB) + initrd (~25MB) ONTO the ESP per
  # generation, so two *differing* generations (77MB) + Windows (27MB) overflow
  # 96MB → ENOSPC mid-deploy on the next kernel bump. GRUB instead reads the
  # kernel/initrd straight from /nix/store on the ext4 root and puts only a
  # small stub on the ESP — the per-generation growth vanishes and the 96MB
  # ceiling is gone. This mirrors the euporos laptop (identical Windows-first
  # 96MB ESP, GRUB, no /boot problem). Migration was done with
  # `nixos-rebuild switch --install-bootloader` after remounting the ESP from
  # /boot to /boot/efi (see hardware-configuration.nix).
  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    device = "nodev";     # EFI install, no MBR target
    useOSProber = true;   # detect the Windows Boot Manager → GRUB menu entry
  };

  # --- Networking -----------------------------------------------------------
  # LAN box behind the home router: NetworkManager + DHCP (no static config).
  networking.hostName = "nixos-gamer";
  networking.networkmanager.enable = true;

  # Wake-on-LAN on the wired NIC (enp8s0, MAC c8:fe:0f:fd:66:93). The card
  # advertises `Supports Wake-on: pumbg`, so magic-packet ("g") works. This
  # runs `ethtool -s enp8s0 wol g` via a systemd service; NM's default
  # wake-on-lan setting is "preserve", so it does not clobber it. Also requires
  # the firmware "Power On by PCI-E/onboard LAN" setting to be enabled.
  # Remote OS choice: WoL always lands here (NixOS = GRUB default entry);
  # to boot Windows once, `grub-reboot "<Windows entry>" && reboot` (find the
  # exact entry name in /boot/grub/grub.cfg — grub-reboot sets a one-shot via
  # grubenv, reverting to the NixOS default afterward).
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
