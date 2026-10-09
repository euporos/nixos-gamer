{ config, pkgs, lib, ... }:

# Self-recovery for a headless box nobody can walk up to.
#
# 2026-10-08 the box hard-froze while IDLE (GPU unloaded, nothing running): no
# kernel message, no panic, network dead, still drawing 82 W. A frozen box
# ignores Wake-on-LAN, and the firmware does not power on after AC loss (BIOS
# setting not changed yet), so it stayed dead until someone pressed the button.
#
# Layers, from prevention to recovery:
#
# 1. PREVENT the likely cause: Zen 1 (Ryzen 5 1600X) idle hard-freeze. The
#    deepest package idle state (CC6, exposed by ACPI as "C2 / IOPORT") can lock
#    up first-gen Ryzen at near-zero load — a known erratum, fixed in later
#    AGESA by the "Power Supply Idle Control" BIOS option. This board
#    (Gigabyte AX370-Gaming 5) is on BIOS F8 from 2017, i.e. before that fix.
#    processor.max_cstate=1 caps idle at C1 (HLT). Cost: some idle watts —
#    measure on the Shelly plug if it matters. Remove once the BIOS is updated
#    and "Typical Current Idle" is set.
#
# 2. RECOVER from a hard lockup: the AMD FCH hardware watchdog (sp5100_tco,
#    /dev/watchdog0, auto-loaded). systemd pets it every RuntimeWatchdogSec/2;
#    if the kernel freezes, nobody pets it and the chipset resets the board.
#    RebootWatchdogSec also covers a reboot that hangs on the way down.
#    NOT tested end-to-end: a real test means freezing the kernel, and if the
#    reset then failed the box would be stranded again (see above).
#
# 3. RECOVER from a kernel crash that does not freeze the CPUs: panic on oops
#    and on a hard-locked CPU (NMI watchdog), then reboot after 10 s instead of
#    sitting on a panic screen forever. softlockup_panic is deliberately NOT
#    set: soft lockups can be transient under heavy GPU/IO load, and a real
#    hang is caught by layer 2 anyway.
#
# 4. DIAGNOSE the next one: journald normally syncs to disk every 5 min, so a
#    hard freeze loses the last minutes — exactly the minutes that matter
#    (2026-10-08: the log ended ~1-5 min before the actual freeze). 30 s keeps
#    the gap small; the extra NVMe writes are negligible.
{
  boot.kernelParams = [ "processor.max_cstate=1" ];

  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "5min";
  };

  boot.kernel.sysctl = {
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;
    "kernel.hardlockup_panic" = 1;
  };

  services.journald.extraConfig = ''
    SyncIntervalSec=30s
  '';
}
