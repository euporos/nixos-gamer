# Immich (photo library) — TRIAL install, part of the nas-migration project
# (~/ARBEITSSD/projects/nas-migration/project.org, phase 1). The goal is to try
# the web UI and the phone app before Immich moves to the future NAS box. The
# photos stay on the QNAP; Immich indexes them in place as two read-only
# "external libraries":
#
#   /media/NAS/Netspace/PHYLAX/Photoalbum
#   /media/NAS/Netspace/PHYLAX/Photos_Fremdsammlungen
#
# To browse them separately, give each library its own Immich user, which
# gives each one its own timeline, search and face groups. Users and libraries
# are set up in the web UI (Administration → Users / External Libraries); they
# live in Immich's database, not in Nix.
#
#   web UI / phone app:  http://192.168.85.30:2283/   (firewalled to the LAN)
#
# Read-only on purpose: the photo dirs are bind-mounted read-only into the
# Immich services, so nothing Immich does (sidecar writes, deletes) can touch
# the originals. The box's CIFS mount itself is read-write for the whisper
# pipeline. The "-" prefix keeps a NAS that is down at service start from
# failing the unit (the paths are then just missing and Immich reports the
# assets offline until the next library scan) — same no-NAS-on-the-boot-path
# rule as the mount itself.
#
# inotify does not work across CIFS (see CLAUDE.md), so Immich's "watch
# library" option is useless here. The library scan is periodic (the
# default is nightly; it can be changed in Administration → Settings).
#
# State (Postgres DB, thumbnails, encoded videos, ML model cache) lives on the
# NVMe under /var/lib/immich + /var/lib/postgresql + /var/cache/immich.
# Machine learning (faces, CLIP search) runs on the CPU. The GTX 1080 Ti is
# Pascal and Immich's CUDA ML image targets newer cards (see CLAUDE.md).
# Removing the trial: drop this import, then delete those directories and the
# immich database.
{ ... }:
let
  port = 2283;
  lanSubnet = "192.168.85.0/24";
  photoDirs = [
    "/media/NAS/Netspace/PHYLAX/Photoalbum"
    "/media/NAS/Netspace/PHYLAX/Photos_Fremdsammlungen"
  ];
  readOnlyPhotos = {
    BindReadOnlyPaths = map (d: "-${d}") photoDirs;
  };
in
{
  services.immich = {
    enable = true;
    host = "0.0.0.0";
    inherit port;
    # Firewall handled below (LAN only), not via openFirewall.
    openFirewall = false;
    machine-learning.enable = true;
  };

  # Only the server reads the originals. The ML service gets preview images
  # from the server over HTTP and never touches the share.
  systemd.services.immich-server.serviceConfig = readOnlyPhotos;

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s ${lanSubnet} --dport ${toString port} -j nixos-fw-accept
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -p tcp -s ${lanSubnet} --dport ${toString port} -j nixos-fw-accept || true
  '';
}
