# Spin down the spinning HDDs that Linux never touches.
#
# Despite being an always-on server, NixOS only uses the NVMe (ext4 root + ESP
# stub). Every other disk is Windows-dual-boot / external data: three of them
# are *rotational* and, left alone, sit there spinning and burning ~6-8W each
# for an OS that isn't even running. That standing idle draw is the single
# biggest electricity waste on the box (see the "Electricity / idle power" note
# in CLAUDE.md). This module parks them.
#
# Why hd-idle (a daemon) and not a one-shot `hdparm -S`/spindown at boot:
# nothing here mounts or polls these disks (no smartd, no udisks2), so a disk
# that gets spun up by any stray access would otherwise never return to
# standby. hd-idle watches /proc/diskstats and re-parks a disk whenever it goes
# idle again — self-healing.
#
# Matching is by /dev/disk/by-id ONLY: the kernel device letters (sdb/sdc/…)
# are NOT stable on this box — they reshuffle between boots (observed shifting
# even between two back-to-back SSH sessions), so sdX matching would target the
# wrong platter. `-s 1` resolves the by-id symlinks at runtime, which also
# covers the USB disk appearing/disappearing.
#
# Confirmed on the box (2026-07-22): the default "scsi" STOP-UNIT command parks
# these internal SATA disks (libata SAT layer) — `hd-idle -t <dev>` drove the
# Hitachi straight to `standby`. The two internal disks obey reliably; the USB
# bridge is best-effort (many USB-SATA bridges ignore STANDBY — harmless if so).
{ pkgs, lib, ... }:
let
  # Idle timeout. hd-idle's own docs warn that spinning up too often wears the
  # spindle; they recommend a 3-5 min minimum and default to 10 min. Since these
  # disks are never accessed by Linux they spin down once ~10 min after boot and
  # then stay down for the whole session — no cycling — so 10 min is purely a
  # safety margin against a stray one-off access causing a park/unpark flap.
  idleSeconds = 600;

  # The three rotational disks, by stable id. Keep in sync with the box if a
  # drive is swapped (get ids from: for d in /sys/block/sd*; do
  # cat $d/queue/rotational; done  →  /dev/disk/by-id).
  spinDisks = [
    "ata-Hitachi_HUS724030ALE641_P8JKX7GX"        # 3TB internal SATA  (Windows NTFS)
    "ata-ST4000DM004-2CV104_ZFN0EHXF"             # 4TB internal SATA  (Windows NTFS, SMR)
    "usb-Generic_STORAGE_DEVICE_000000001532-0:0" # 238GB USB (exfat) — best-effort over USB
  ];

  # hd-idle's CLI is positional: a leading "-i 0" makes the default "never spin
  # down" (so the SSDs/NVMe are left alone), then each disk is named with "-a"
  # and given its own "-i <sec>".
  argv =
    [ "-i" "0" "-s" "1" ]
    ++ lib.concatMap (d: [ "-a" "/dev/disk/by-id/${d}" "-i" (toString idleSeconds) ]) spinDisks;
in
{
  systemd.services.hd-idle = {
    description = "Spin down idle Windows-only HDDs (hd-idle)";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ]; # ensure /dev/disk/by-id is populated
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.hd-idle}/bin/hd-idle " + lib.concatStringsSep " " argv;
      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
