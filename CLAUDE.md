# nixos-gamer

Flake-based NixOS config for the headless AI host at `192.168.85.30`
(hostname `nixos-gamer`, user `phylax`, root SSH works). Despite the name it is
not for gaming — the name comes from the Windows dual-boot on the same machine.

## Deploy

```sh
nix run .#deploy
```

Pushes the current branch to origin, then `nixos-rebuild switch` over SSH with
`--build-host == --target-host` — evaluation is local, building happens on the
box. Never build locally for the box; its internet is faster.

The deploy target is `root@gamer-nixos` — `gamer-nixos` is an alias in the
local `~/.ssh/config` (HostName 192.168.85.30, ForwardAgent yes); deploying
from a machine without that alias needs it added first.

## Hardware constraints (violating these breaks the box)

- **GPU is a GTX 1080 Ti (Pascal, sm_61).** Consequences:
  - NVIDIA driver must stay on `nvidiaPackages.legacy_580` — the last branch
    with Pascal support (`production` ≥ 590 dropped it). See `nvidia.nix`.
  - PyTorch ≥ 2.8 CUDA wheels have **no sm_61 kernels** — anything torch-based
    must use torch ≤ 2.7.x or it dies with "no kernel image is available".
    This is why the WhisperX container image in `whisper.nix` is pinned to a
    2024 build (torch 2.1.1). Do not bump it to a floating tag.
  - No usable fp16 on Pascal; CTranslate2/faster-whisper runs `int8` (dp4a).
- **The ESP is a tiny 96MB Windows-created partition** (`nvme0n1p1`, mounted at
  `/boot/efi`) shared with the Microsoft bootloader (~27MB). It is boxed in
  between the disk start and the Windows partitions, so it **cannot be grown**.
  - **Bootloader is GRUB, on purpose** (`configuration.nix`). systemd-boot
    (Boot Loader Spec) copies kernel+initrd (~38MB/gen) ONTO the ESP per
    generation; two *differing* generations + Windows overflow 96MB → ENOSPC
    mid-deploy on the next kernel bump. GRUB reads kernel/initrd straight from
    `/nix/store` on the ext4 root and puts only a small stub on the ESP, so the
    per-generation ESP growth is gone and there is no generation limit. The
    `euporos` laptop runs the same setup (identical Windows-first 96MB ESP).
  - Mount layout: ESP at `/boot/efi` (`hardware-configuration.nix`); `/boot` is
    a plain dir on the ext4 root holding `grub/grub.cfg` (kernels stay in the
    store, not copied). Do **not** revert the ESP to mounting at `/boot`.
  - Migrating the bootloader (or reinstalling GRUB) needs
    `NIXOS_INSTALL_BOOTLOADER=1` / `nixos-rebuild switch --install-bootloader`
    — a plain switch will not rewrite the ESP stub.

## Wake-on-LAN + remote OS selection

The box is off most of the time and dual-boots NixOS/Windows. WoL powers it on
but **cannot pick the OS** — the magic packet only says "power on". The flow:

- **Wake it**: from any LAN machine, `wakeonlan c8:fe:0f:fd:66:93` (the wired NIC
  `enp8s0`; `nix-shell -p wakeonlan`). WoL is enabled via a systemd `.link`
  file (`networking.interfaces."enp8s0".wakeOnLan.enable` in
  `configuration.nix`), applied by udev on every boot. Also needs the firmware
  "Power On by PCI-E/onboard LAN" setting on. Verify with
  `ethtool enp8s0 | grep Wake-on` → want `g`.
- **Which OS**: NixOS is the GRUB default entry, so WoL always lands in NixOS
  (the SSH-reachable OS). To boot Windows *once*, SSH in and run
  `grub-reboot "<Windows entry>" && systemctl reboot` — GRUB boots Windows next
  (one-shot via grubenv), then reverts to the NixOS default. Find the exact
  entry name (os-prober-generated) in `/boot/grub/grub.cfg` (a `menuentry
  "Windows Boot Manager …"`). Going back: just restart Windows (lands on the
  NixOS default).
- **Windows gotcha**: disable Windows Fast Startup, or a "shutdown" is really
  hibernation (S4) and the NIC won't honor the magic packet from that state.

## Whisper transcription pipeline (`whisper.nix`)

- Web UI: `http://192.168.85.30:8990/` — single static page
  (`whisper-ui/index.html`, no build step, no backend daemon). It polls nginx
  `autoindex_format json` listings under `/status/{inbox,work,failed,transcripts}/`
  to show all jobs (including CLI/scp uploads), and cancels/requeues by
  PUTting `<name>.cancel` / `<name>.requeue` sentinels to `/control/`, handled
  by the `whisper-control` path unit (kills the `whisper-job` podman
  container, or moves files between inbox/ and failed/). A cancelled job's
  audio lands in `failed/` like any failure.
- Upload: `curl -T file.m4a http://192.168.85.30:8990/` (nginx WebDAV PUT,
  atomic rename into `/srv/whisper/inbox`), or scp into that dir.
- systemd path unit + 10-min sweep timer → `whisper-worker` (bash, runs as
  root) → one-shot rootful podman job per file with `--device
  nvidia.com/gpu=all` (CDI). No VRAM held between jobs; ~15× realtime.
- Results in `/srv/whisper/transcripts/` (`.txt/.srt/.vtt/.tsv/.json` +
  jq-generated `.speakers.txt`); audio → `processed/`, failures → `failed/`
  (requeue = move back to inbox). Logs: `journalctl -u whisper-worker`.
- The container user is uid 1001 == host user `whisper` (fixed uid, on
  purpose — bind-mounted job dirs rely on it).
- The image's whisperx downloads its VAD model from a **dead S3 bucket**; the
  worker pre-seeds the sha-verified file into `/var/cache/whisperx/torch/`
  from the whisperX repo's bundled asset. Keep that seeding step.
- **Dual-channel (one speaker per channel)**: the UI's "one speaker per
  channel" checkbox inserts a `.2ch` marker before the extension (e.g.
  `talk.2ch.m4a`); `curl -T talk.m4a http://…/talk.2ch.m4a` triggers it too.
  The worker then ffprobe-verifies 2 channels, ffmpeg-splits L/R into 16 kHz
  mono, runs WhisperX once per channel (json only, **no diarization**), and a
  stdlib Python helper (`whisper-merge.py`) interleaves the segments by start
  time into `SPEAKER_L`/`SPEAKER_R`, emitting the full format set. The `.2ch`
  marker is stripped from every output name. A file wrongly marked (not really
  stereo) falls back to normal transcription. This is exact and free of the HF
  token — prefer it whenever speakers are physically channel-separated.
- **Language**: the pinned image's entrypoint bakes `--language de` (env
  `LANG=de`), so the default is German. The worker overrides it per-job by
  passing `--language <code>` *after* the baked flag (whisperx argparse takes
  the last value). A `.lang-XX` filename marker (UI dropdown, or curl to
  `…/talk.lang-en.m4a`) selects the language; supported: `de` (default), `en`,
  `ru`, `fr`. Non-German alignment models download from HF at runtime (the box
  has internet); `de`'s alignment model is baked into the `-de` image tag.
  Adding a language means: add the `.lang-XX` case in the worker's marker
  loop **and** an `<option>` in the UI — nothing else. Marker is stripped from
  output names, and combines with `.2ch` in any order.
- Speaker diarization only activates when `/var/lib/whisper/hf-token.env`
  contains `HF_TOKEN=hf_…` (gated pyannote models; user must accept terms of
  `pyannote/speaker-diarization-3.1` and `pyannote/segmentation-3.0` on
  huggingface.co). Without it, transcription runs but speakers show as
  `SPEAKER_?`. Status: token installed since 2026-07-19 — diarization active.
- nginx runs under `ProtectSystem=strict`; the inbox is whitelisted via
  `ReadWritePaths`. New writable paths for nginx need the same treatment.

## Gotchas

- First switch after enabling a kernel-module change (e.g. the NVIDIA driver)
  needs a reboot of the box; services like the CDI generator fail until then.
- `hardware-configuration.nix` carries real disk UUIDs — regenerate on the box,
  never hand-edit.
