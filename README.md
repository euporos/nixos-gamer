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
