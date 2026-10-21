# nixos-gamer

Flake-based NixOS configuration for the host at **`phylax@192.168.85.30`**.

Despite the name, this is not a gaming machine — the name comes from its Windows
gaming dual-boot. This NixOS side is being set up as a **headless AI processing
host**.

## Hardware

- AMD Ryzen 5 1600X, UEFI, systemd-boot
- NVIDIA GTX 1080 Ti on the proprietary `legacy_580` driver (the last branch
  with Pascal support; `production` ≥ 590 dropped it), CUDA containers via
  podman + nvidia-container-toolkit (CDI)
- Root: `ext4` on `nvme0n1`; several extra SATA/HDD disks present but unmanaged here

`hardware-configuration.nix` was captured from the live machine and carries the
real disk UUIDs — regenerate it with `nixos-generate-config --show-hardware-config`
on the box if the disk layout changes.

## Layout

| file                        | purpose                                         |
| --------------------------- | ----------------------------------------------- |
| `flake.nix`                 | inputs, `nixosConfigurations.nixos-gamer`, `deploy` app |
| `configuration.nix`         | system config (users, SSH, locale, nix, packages) |
| `nvidia.nix`                | proprietary NVIDIA driver (Pascal/`legacy_580`) + container toolkit |
| `whisper.nix`               | German transcription pipeline (WhisperX + diarization) |
| `comfyui.nix`, `comfyui/`   | ComfyUI image generation (podman image, models, workflows) |
| `hardware-configuration.nix`| generated hardware scan (real UUIDs)            |

## Whisper transcription

Async German speech-to-text with speaker diarization on the 1080 Ti
(WhisperX large-v3, int8 — see `whisper.nix` for the full design).

```sh
# upload a recording (any common audio/video format)
curl -T aufnahme.m4a http://192.168.85.30:8990/

# ...the worker picks it up, transcribes, and drops results in
#   /srv/whisper/transcripts/   (aufnahme.txt/.srt/.vtt/.json/.speakers.txt)
curl http://192.168.85.30:8990/transcripts/            # listing
curl -O http://192.168.85.30:8990/transcripts/aufnahme.speakers.txt
```

`scp` into `phylax@…:/srv/whisper/inbox/` works too. Processed audio moves to
`/srv/whisper/processed/`, failures to `/srv/whisper/failed/` (worker logs:
`journalctl -u whisper-worker`). Same-named uploads overwrite older transcripts.

**Speaker diarization** needs a Hugging Face token (gated pyannote models);
without it the worker transcribes without speaker labels. One-time setup:
accept the terms of `pyannote/speaker-diarization-3.1` **and**
`pyannote/segmentation-3.0` on huggingface.co, create a read token, then on
the box as root: `echo 'HF_TOKEN=hf_...' > /var/lib/whisper/hf-token.env`.

## ComfyUI image generation

ComfyUI v0.42.1 on the 1080 Ti, LAN-only at **http://192.168.85.30:8188/**
(firewalled to `192.168.85.0/24`; no auth). It runs as the `comfyui` systemd
service: a podman container built on the box from `comfyui/Containerfile`,
with all state in `/var/lib/comfyui`. Includes ComfyUI-GGUF, Ultimate SD
Upscale and ComfyUI-Manager (v4, the pip package, enabled with
`--enable-manager`).

```sh
systemctl status comfyui            # on the box (as root)
systemctl stop|start|restart comfyui
journalctl -u comfyui -f            # also /var/lib/comfyui/user/comfyui_8188.log
journalctl -u comfyui-models        # model downloads
```

It starts at boot. If a pin changed, the first start rebuilds the image
(~6–15 min; the UI stays down until it finishes). Restarting is harmless:
a prompt in flight is lost, but nothing else is.

**Saved workflows** (Workflows sidebar): `sdxl-juggernaut`, `z-image-turbo`,
`flux1-dev-gguf`, plus `upscale-esrgan` and `upscale-refine-sdxl` (see
[Upscaling for print](#upscaling-for-print)). They are copied from `comfyui/workflows/` on every start, so
**save your own edits under a new name** or they get overwritten. API-format
copies for scripting live in `comfyui/workflows/api/`
(`curl -X POST :8188/prompt -d '{"prompt": …}'`).

Measured at 1024×1024 (warm, model already loaded):

| workflow            | model                         | steps | time/image | peak VRAM |
| ------------------- | ----------------------------- | ----- | ---------- | --------- |
| `sdxl-juggernaut`   | Juggernaut XL v9 (SDXL)       | 30    | ~98 s      | 10.6 GB   |
| `z-image-turbo`     | Z-Image Turbo bf16            | 8     | ~72 s      | 10.8 GB   |
| `flux1-dev-gguf`    | FLUX.1 [dev] Q6_K + T5 Q8_0   | 20    | ~10.7 min  | 9.9 GB    |

Pascal computes all of these in fp32 (it has no usable fp16), so FLUX.1 [dev]
at ~32 s/step is near what the card can do. A cold first run adds 5–20 s for
loading. ComfyUI holds the shared GPU lock for 5 minutes after the last prompt
(models stay loaded), so a queued transcription or summary waits at most that
long. Conversely, a prompt waits while one of those is running.

### Upscaling for print

Generate at the model's native size (~1 MP) and upscale only the keepers.
For reference, A4 at 300 dpi is 3508×2480 px, so ×3.5 from 1024 px covers it.
Results go to `output/upscaled/`. There are two kinds of upscale:

- **Plain model upscale** (`upscale-esrgan`): Load Image → ESRGAN ×4 →
  optional Scale By → Save. Takes 12–30 s for 1024² → 4096². It sharpens
  what is there but adds no new detail, and needs no prompt, so it works on
  any image. Models: `4x-UltraSharp` (crisp, good on generated art,
  CC BY-NC-SA, so personal use only) and `RealESRGAN_x4plus` (BSD, softer).
- **Refined upscale** (Ultimate SD Upscale): ESRGAN first, then every
  1024² tile is re-diffused at low denoise (0.25–0.3) by a diffusion
  model. This invents real fine detail (fur, skin, texture) without
  visible seams.
  - **Your own images:** every generation workflow has an **Upscale**
    group, bypassed by default. Drag the keeper PNG onto the canvas
    (restores its prompt and settings), then drop the same PNG onto the
    group's Load Image (exact pixels, no regeneration). Click the
    `Generate` group title and press Ctrl+B, click the `Upscale` title and
    press Ctrl+B, then queue. The tiles use that workflow's own model and
    prompt. PNGs made before this group existed restore without it; use
    the standalone workflow for those.
  - **Any other image:** `upscale-refine-sdxl` (Juggernaut). Replace
    "describe the picture here" with a few words about the image.

`steps` on the upscale node is the number of steps actually run **per tile**.
Low denoise does not shorten it (that is how ComfyUI's sampler works), so
time ≈ tiles × steps × s/step. The defaults are kept low for that reason.
Measured ×2 (1024² → 2048², 4 tiles, warm):

| upscale                        | steps | time    |
| ------------------------------ | ----- | ------- |
| `upscale-esrgan` ×4            | –     | 12–30 s |
| SDXL group / `upscale-refine-sdxl` | 10 | ~180 s  |
| Z-Image group                  | 4     | ~200 s  |
| Flux group                     | 6     | ~17 min (est.: 246 s at 1 step) |

Time grows with the tile count: ×3.5 (A4) is 16 tiles, so about 4× the ×2
time (roughly 12 min with SDXL). Don't feed the refine an already-huge image.

### Models, LoRAs, custom nodes

```
/var/lib/comfyui/models/
  checkpoints/        all-in-one SD1.5/SDXL .safetensors
  diffusion_models/   UNet/DiT only — Flux, Z-Image, and *.gguf (UnetLoaderGGUF)
  text_encoders/      CLIP / T5 / Qwen (*.gguf via the GGUF CLIP loaders)
  vae/  loras/  upscale_models/   (any other ComfyUI folder works too)
```

- **Pinned, reproducible models**: add an entry to the `models` list in
  `comfyui.nix` (HF repo, revision, file, sha256 from
  `https://huggingface.co/api/models/<repo>/tree/<rev>`), then `nix run .#deploy`.
  `comfyui-models.service` downloads, verifies, and renames into place. Gated
  repos use the sops `hf-token` secret automatically, so accept the license on
  huggingface.co first.
- **Ad hoc**: copy files into the folder as `comfyui` (or `chown comfyui:`
  them), then press `r` in the UI to refresh the lists. No restart needed.
  Manager's model downloader works too.
- **LoRAs**: drop `.safetensors` into `models/loras/` and add a `LoraLoader`
  (SDXL) or `LoraLoaderModelOnly` (Flux/Z-Image) node after the model loader.
  A LoRA must match the base model family.
- **Custom nodes** installed through Manager land in
  `/var/lib/comfyui/custom_nodes/`, their Python deps in
  `/var/lib/comfyui/.local/`. Both persist across restarts and image rebuilds.
  ComfyUI-GGUF and Ultimate SD Upscale are baked into the image
  (`/opt/comfyui-nodes`). Update them by bumping `GGUF_REV` / `USDU_REV` (and
  `USDU_SCRIPT_REV`) in the Containerfile, not through Manager.

### The torch pin — read before updating anything

The GTX 1080 Ti is Pascal (sm_61). PyTorch's **cu128/cu129/cu130 wheels contain
no sm_5x/sm_6x kernels**: they import fine and then die with "no kernel image
is available". The **cu126** wheels still ship sm_60 kernels, which run on
sm_61. That holds up to torch 2.14.1 (verified on the box). So the rule is
the *wheel flavour*, not the torch version:

- `comfyui/torch-pins.txt` pins `torch==2.14.1+cu126` / `torchvision==0.29.1+cu126`.
  The `+cu126` is the important part.
- The same file is a **runtime pip constraint** (`comfyui/pip.conf`). If
  Manager or a custom node's requirements try to replace torch, pip fails
  with `ResolutionImpossible` instead of silently installing a cu128 build.
- ComfyUI's code has its `.git` removed, so Manager's "Update ComfyUI" cannot
  pull. Ignore it, and ignore the startup line `[ComfyUI-Manager] PyTorch is
  not installed`. That check wants torchaudio, which ComfyUI doesn't need and
  which has no cu126 build for torch 2.14.
- `TORCH_DISABLE_NATIVE_JIT=1` (set in the Containerfile) is required. Newer
  torch reroutes some ops to Triton kernels, and Triton needs sm_70+, so
  without it the Z-Image text encoder fails ("Failed to find C compiler").
- **To update**: bump `COMFYUI_TAG`/`COMFYUI_REV` (and/or the torch pins) in
  the Containerfile and regenerate `requirements.lock` (build once with an
  empty lock, then
  `podman run --rm --entrypoint pip <image> freeze`).
  Keep torch on a `+cu126` build. Before switching, check on the box that
  `torch.cuda.get_arch_list()` still contains `sm_60` or `sm_61`. Deploy; the
  next start rebuilds.
- Don't add `--force-fp16`: Pascal's fp16 is 2.5× slower here. The default
  (fp16/bf16 weights, fp32 compute, fp32 VAE) benchmarked fastest.

## Deploy

```sh
nix run .#deploy
```

This pushes the current branch to `origin`, then rebuilds over SSH. Evaluation
runs on your local machine (cheap), but the actual building and cache downloads
happen **on the target** (`--build-host == --target-host`), so the box's stronger
internet does the heavy lifting and nothing but derivations crosses the network.

### One-time bootstrap

The `deploy` app connects as **root** and needs `phylax` to be a trusted Nix user —
both are set by *this* configuration, so the very first activation is a
chicken-and-egg and must be done on the box:

1. Add a git remote named `origin` and push:
   ```sh
   git remote add origin <url>
   git push -u origin main
   ```
2. On the machine, build & switch once as root:
   ```sh
   ssh phylax@192.168.85.30
   git clone <url> ~/nixos-gamer && cd ~/nixos-gamer
   sudo nixos-rebuild switch --flake .#nixos-gamer
   ```

After that first switch, root's SSH key and `phylax`'s trusted-user status are in
place, and `nix run .#deploy` works from this repo without any password prompt.

> Note: this config sets `PasswordAuthentication = false` and installs the
> `services@olivermotz.com` key for both `phylax` and `root`. That key is already
> in `phylax`'s stateful `authorized_keys` on the box, so you will not be locked
> out by the first switch.

## Windows side (dual-boot): OpenSSH for remote power control

The `euporious.gamer` module (runs on `nas-nixos`) drives this box's power/boot
from the LAN. On the **Windows** side it SSHes in as user `phylax` to read a
status banner and to run `shutdown /s` (power off) / `shutdown /r` (the
Windows→NixOS hop). Windows therefore needs OpenSSH Server running and the NAS
control key authorized. Verified working 2026-07-21.

**The non-obvious gotcha:** `phylax` is a **local administrator**, so sshd
*ignores* `C:\Users\phylax\.ssh\authorized_keys`. The key must live in
`C:\ProgramData\ssh\administrators_authorized_keys` **with ACLs restricted to
Administrators + SYSTEM** — otherwise sshd silently refuses it and auth fails
with no useful error.

One-time setup, in an **elevated** PowerShell on Windows:

```powershell
$key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE6fpoC4JQmiyzf9ls9z6aM1o7c4nCU7C/5F9GrAg3nr euporious-gamer-control@nas-nixos'

(Get-WindowsCapability -Online -Name OpenSSH.Server*) | ? State -ne Installed | % { Add-WindowsCapability -Online -Name $_.Name }
Set-Service sshd -StartupType Automatic; Start-Service sshd          # Automatic = survives reboot

if (-not (Get-NetFirewallRule -Name sshd -EA SilentlyContinue)) {
  New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }

$ak = "$env:ProgramData\ssh\administrators_authorized_keys"          # admin -> NOT ~/.ssh
if (-not (Test-Path $ak) -or (Get-Content $ak -Raw) -notmatch 'euporious-gamer-control') { Add-Content $ak $key -Encoding ascii }
icacls.exe $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'   # required, or sshd ignores the file
```

- The authorized key is the public half of `/home/phylax/.ssh/gamer_control` on
  `nas-nixos` (`euporious-gamer-control@nas-nixos`). Its NixOS counterpart is
  `root@gamer`, authorized in `configuration.nix`.
- Verify from the NAS: `ssh -i /home/phylax/.ssh/gamer_control -o StrictHostKeyChecking=no phylax@192.168.85.30 whoami` → `desktop-mksqeig\phylax`.
- The banner `SSH-2.0-OpenSSH_for_Windows_9.5` is what the gamer status probe
  reads to report `:windows`; without sshd the box reads as `:off` even while
  running Windows.
