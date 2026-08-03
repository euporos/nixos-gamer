{ config, pkgs, ... }:

let
  # abcde expands these itself at rip time, so the $-refs have to survive both
  # Nix and the shell that sources /etc/abcde.conf. Double-quoted Nix strings
  # here (plain \$ escape); single-quoted in the config below so the sourcing
  # shell does not expand them either.
  outFmt   = "\${ARTISTFILE}/\${ALBUMFILE}/\${TRACKNUM}.\${TRACKFILE}";
  vaOutFmt = "Various-\${ALBUMFILE}/\${TRACKNUM}.\${ARTISTFILE}-\${TRACKFILE}";
in

{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
    ./disk-spindown.nix
    ./whisper.nix
    ./summarize.nix
    ./sops.nix
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
  # Headless safety valve: NEVER drop to an interactive emergency/rescue shell
  # on boot. This box lives at 192.168.85.30 and is driven remotely (WoL from the
  # NAS); a failed mount stranding it at a console root-password prompt with no
  # sshd means it's dead until someone walks over with a keyboard. With this off,
  # any boot failure that would have gone to emergency mode instead continues to
  # multi-user.target, so the network and sshd come up and it stays reachable.
  systemd.enableEmergencyMode = false;

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

  # --- Storage: NAS (CIFS) --------------------------------------------------
  # Mount //192.168.85.50/Netspace the same way nas-nixos does (cifs,
  # username=/password= credentials). The credentials file is decrypted from
  # the repo by sops-nix (see sops.nix) to /run/secrets/smb-secrets at
  # activation — no longer hand-placed at /etc/nixos/secrets/smb-secrets. This
  # This share is the SOURCE OF TRUTH for the transcription pipeline, not a
  # delivery target any more: artifacts/transcriptions/<stem>/ holds the source
  # audio, every transcript format (whisper.nix) and the summaries
  # (summarize.nix), and _inbox/ there is a drop point for new audio. Nothing
  # durable is kept on the SSD. Consequence for THIS mount: it is now on the
  # critical path at job time — but still not at boot time, so the resilience
  # options below stay exactly as they were. Both workers probe the share and
  # no-op while it is down, so an outage delays jobs instead of failing them.
  #
  # Deviation from nas-nixos, on purpose: nofail + x-systemd.automount. This box
  # is headless and off most of the time (WoL), so a NAS that is unreachable at
  # boot must never delay or fail the boot — see the boot-resilience rules
  # above. automount mounts the share lazily on first access (when the worker
  # writes a result), never eagerly at boot; nofail keeps a mount failure
  # non-fatal. cifs-utils provides the mount.cifs helper systemd needs.
  #
  # dir_mode=0777/file_mode=0666: permit any local user to read and write, not
  # just the mount-owner uid=1000. Both workers run as root and bypass these
  # masks anyway (the DynamicUser summarizer that originally forced this open is
  # long gone), but nginx serves the archive listings and downloads as user
  # `nginx` and needs the read side. Everything on this SMB share is
  # authenticated as the single credentials account regardless of local user, so
  # these client-side masks are the only gate — open them to the whole box.
  fileSystems."/media/NAS/Netspace" = {
    device = "//192.168.85.50/Netspace";
    fsType = "cifs";
    options = [
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=60"
      "x-systemd.device-timeout=30s"
      "x-systemd.mount-timeout=30s"
      "credentials=${config.sops.secrets."smb-secrets".path}"
      "uid=1000"
      "gid=100"
      "dir_mode=0777"
      "file_mode=0666"
    ];
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
    # "cdrom" is required to rip: /dev/sr0 is brw-rw---- root:cdrom, so without
    # it abcde/cdparanoia fail with permission denied as a non-root user.
    extraGroups = [ "networkmanager" "wheel" "cdrom" ];
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
    python3      # on $PATH for ad-hoc scripts / debugging (the summarize worker
                 # runs its own pinned python via an absolute store path, so this
                 # is only for interactive use, not a dependency of any service)
    cifs-utils   # mount.cifs helper for the NAS mount above

    # CD ripping. abcde shells out to these by name, so they must be on $PATH
    # alongside it or a rip dies mid-run with "command not found".
    abcde
    cdparanoia   # the ripper abcde drives
    lame         # MP3 encoder
    flac         # abcde's default output format / for lossless rips
    eject        # abcde ejects the disc when done
    cdrtools     # cdda2wav / CD-Text fallback readers
  ];

  # --- CD ripping defaults --------------------------------------------------
  # abcde reads /etc/abcde.conf first, then ~/.abcde.conf (which may override
  # any of this). Keeping the defaults here rather than in a hand-placed dotfile
  # means `abcde` with no arguments does the right thing for every user and the
  # settings are version-controlled like everything else on this box.
  environment.etc."abcde.conf".text = ''
    # MP3 out. abcde's own default is FLAC, and OUTPUTTYPE is what switches it;
    # MP3ENCODERSYNTAX picks which encoder binary drives it (lame, installed above).
    OUTPUTTYPE=mp3
    MP3ENCODERSYNTAX=lame
    # -V 2 is LAME's variable-bitrate ~190kbps setting — transparent for almost
    # all material and smaller than a fixed 320. Use -b 320 instead for CBR.
    LAMEOPTS='-V 2'

    # Where finished albums land. On the NAS so a rip is immediately reachable
    # from every machine, like the transcription archive.
    OUTPUTDIR=/media/NAS/Netspace/music

    # Intermediate WAVs must NOT go to OUTPUTDIR: abcde writes the raw rip first
    # and encodes afterwards, so leaving this unset would push ~600MB per disc
    # over CIFS and read it straight back. Keep the scratch on the local SSD.
    WAVOUTPUTDIR=/var/tmp/abcde

    # Tag lookup. musicbrainz is the live database; the freedb servers abcde
    # defaults to have been dead for years, and without this a rip silently
    # produces "Track 01"-style names with no artist/album tags.
    CDDBMETHOD=musicbrainz

    # <Artist>/<Album>/<NN.Track>.mp3, and the same for compilations except the
    # per-track artist is kept (VA discs otherwise collapse to one bogus artist).
    OUTPUTFORMAT='${outFmt}'
    VAOUTPUTFORMAT='${vaOutFmt}'
    # Zero-pad track numbers so 2 sorts before 10 in every player and file browser.
    PADTRACKS=y

    # Encode while the next track is still being read, and use both spare cores.
    MAXPROCS=3
    EJECTCD=y
  '';

  # abcde does not create WAVOUTPUTDIR itself — a rip aborts on the first track
  # if it is missing. Sticky + world-writable like /var/tmp so any user can rip;
  # the 10d age lets systemd-tmpfiles reap WAVs left behind by an aborted rip.
  systemd.tmpfiles.rules = [
    "d /var/tmp/abcde 1777 root root 10d"
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
