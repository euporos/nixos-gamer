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
#    max_cstate=1 alone was NOT enough: with it active the box still froze
#    idle three times in 28 h (2026-10-10 21:00, 10-11 00:09, 10-11 14:08).
#    It only hides the ACPI C2 state from the OS; the SMU still drops cores
#    into CC6 and the package into PC6 on its own, and those enables stayed
#    set (read on the box: 0xC0010292 = 0x100000052, 0xC0010296 = 0x484848).
#    zen-c6-disable clears them via MSR at boot — the same bits as
#    `zenstates.py --c6-disable`: package C6 = 0xC0010292 bit 32, core C6 =
#    0xC0010296 bits 6/14/22. MSR state does not survive a reset, hence a
#    boot-time service rather than a one-off.
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
  # msr.allow_writes=on: the kernel otherwise warns on every write to these
  # (to it) unknown AMD MSRs.
  boot.kernelParams = [ "processor.max_cstate=1" "msr.allow_writes=on" ];
  boot.kernelModules = [ "msr" ];

  systemd.services.zen-c6-disable = {
    description = "Disable Zen 1 core and package C6 (idle-freeze erratum)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    path = [ pkgs.msr-tools ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for dev in /dev/cpu/[0-9]*; do
        cpu=''${dev##*/}
        pc6=$(( 16#$(rdmsr -p "$cpu" 0xC0010292) ))
        cc6=$(( 16#$(rdmsr -p "$cpu" 0xC0010296) ))
        wrmsr -p "$cpu" 0xC0010292 $(( pc6 & ~(1 << 32) ))
        wrmsr -p "$cpu" 0xC0010296 $(( cc6 & ~((1 << 22) | (1 << 14) | (1 << 6)) ))
      done
      echo "C6 off: 0xC0010292=$(rdmsr -p 0 0xC0010292) 0xC0010296=$(rdmsr -p 0 0xC0010296)"
    '';
  };

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
