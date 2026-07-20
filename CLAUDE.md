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
- **The ESP (`/boot`) is a tiny 96MB Windows-created partition** shared with
  the Microsoft bootloader (~25MB). Kernel ≈ 13MB, initrd ≈ 20MB (xz).
  `configurationLimit = 2` + `boot.initrd.compressor = "xz"` exist to make two
  generations fit — a third does not. If a switch fails with ENOSPC on /boot:
  delete old system generations and stale `*.tmp` files in `/boot/EFI/nixos/`.

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
