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
  - PyTorch's **cu128/cu129/cu130** wheels (the PyPI default since 2.8) have
    **no sm_5x/sm_6x kernels** — they die with "no kernel image is available".
    The trap is the wheel *flavour*, not the torch version: the **cu126**
    wheels still ship `sm_60` (binary-compatible with sm_61) — verified on
    the box 2026-10-21 for 2.8.0, 2.10.0 and 2.14.1 (matmul + fp16 run). So
    pin `torch==X+cu126` from `download.pytorch.org/whl/cu126`. The WhisperX
    image in `whisper.nix` is still pinned to a 2024 build (torch 2.1.1)
    because its newer builds ship a torch without Pascal kernels. Do not
    bump it to a floating tag.
  - **Triton needs sm_70+**, and torch ≥ ~2.12 routes some *eager* ops through
    Triton (`torch._native` registry). On Pascal that fails with "Failed to
    find C compiler" (misleading: a compiler wouldn't help). Set
    `TORCH_DISABLE_NATIVE_JIT=1` for any modern torch on this box; the
    ComfyUI image does.
  - No usable fp16 on Pascal; CTranslate2/faster-whisper runs `int8` (dp4a).
  - **Ollama (summarization) has the same sm_61 trap** — but a different fix.
    This nixpkgs' default `cudaCapabilities` is `7.5 8.0 … 12.1` (it OMITS
    `6.1`), so a stock `ollama-cuda` would ship with no Pascal kernels and die
    identically with "no kernel image is available". The default CUDA here is
    **12.9, which still supports Pascal**, so the fix is simply forcing the arch:
    `nixpkgs.config.cudaCapabilities = [ "6.1" ]` in `summarize.nix` (only
    ollama is CUDA-built, so scoping to this one GPU is correct). This compiles
    ollama-cuda from source for sm_61 (not in the binary cache — a one-time
    remote build). Do **not** let the default CUDA float to 13.x — CUDA 13
    dropped Pascal at the compiler level, so 6.1 would no longer even build.
  - **Ollama GPU boot race (silent CPU fallback).** Ollama probes for CUDA GPUs
    **once at startup** and, finding none, runs **CPU-only** for the whole
    session with no error — a 14B model on the Zen1 CPU is ~10-50x slower, so
    jobs look "stuck" (a chunk takes 10+ min) and a cancel can't interrupt the
    multi-minute prompt-eval. On this box `/dev/nvidia-uvm` (needed for CUDA
    compute) isn't created until ~2 min into boot (module load + the nvidia CDI
    generator), and stock ollama is ordered only `After=network.target`, so on an
    unlucky boot it probes before the GPU exists and falls back. Fixed in
    `summarize.nix`: `systemd.services.ollama` is ordered `after`/`wants` the
    `nvidia-container-toolkit-cdi-generator.service` **and** has an `ExecStartPre`
    that blocks (bounded 60s) until `/dev/nvidia-uvm` appears. **Diagnose** with
    `journalctl -u ollama | grep "inference compute"` — want
    `library=CUDA … GTX 1080 Ti`, **not** `id=cpu library=cpu total_vram="0 B"`;
    or `curl -s localhost:11434/api/ps` — a loaded model must show
    `size_vram` ≈ 9 GB (0 = on CPU). **Live recovery** (no reboot):
    `systemctl restart ollama` re-probes and finds the card.
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
  - **Boot resilience (why the ESP can't brick the box):** Windows keeps
    setting the FAT dirty bit on this shared ESP (Fast Startup / updates), which
    fails `systemd-fsck@boot-efi`. The ESP is therefore `nofail` +
    `x-systemd.device-timeout=5s` (`hardware-configuration.nix`) — a failed
    fsck/mount is non-fatal and boot continues, because the ESP is only needed
    at rebuild time (GRUB stub), never at runtime. Belt-and-suspenders,
    `systemd.enableEmergencyMode = false` (`configuration.nix`) means *any*
    boot fault continues to `multi-user.target` (network + sshd) instead of a
    dead console root-password prompt. Without both, a dirty ESP dropped the
    headless box to emergency mode = remotely dead until someone walked over
    with a keyboard.
  - **Deploy caveat — degraded ⇒ remount ESP first:** because of `nofail`, when
    the ESP got skipped at boot it stays *unmounted* and
    `systemctl is-system-running` reports `degraded`. Before the next
    `nix run .#deploy`, ssh in and
    `fsck.vfat -aw /dev/disk/by-uuid/EC72-7C23 && mount /boot/efi` — otherwise
    GRUB writes its stub to the empty `/boot/efi` dir on the ext4 root instead
    of the real ESP, and the bootloader silently isn't updated.

## Hangs and self-recovery (`resilience.nix`)

**2026-10-08 the box hard-froze while idle** (GPU unloaded, nothing running):
no kernel message, network dead, still drawing **82 W** on the Shelly plug.
Likely the Zen 1 idle-freeze erratum (deep C6 at near-zero load); the board is
a **Gigabyte AX370-Gaming 5 on BIOS F8 (2017)**, older than the AGESA fix.

- **A frozen box ignores WoL** (it's not in S5), and after cutting power at the
  plug it **stayed at 2 W**: the firmware doesn't power on after AC loss, and
  the RTL8125B NIC doesn't answer WoL after a full AC loss either (r8169 arms
  WoL at each OS boot; AC loss resets it). Recovery took someone pressing the
  power button. **Since 2026-10-20 the BIOS has Power → "AC BACK" = Always On**,
  so the Shelly is a remote power button from any state (off, frozen, stranded
  in BIOS setup): relay off → wait ~10 s → on boots the box. euporious
  (`/gamer`, `euporious.gamer` on the NAS) uses this: it reads < 4 W as off,
  powers on via the relay, and has a guarded "Power cycle" action. Still
  pending: a BIOS update + "Power Supply Idle Control: Typical Current Idle",
  after which `processor.max_cstate=1` can go.
- **The box's smart plug is the Shelly Plug S (Gen1) at `192.168.85.203`**
  (no auth, unnamed; `.201` is a second Shelly, *not* the box). Read-only
  state: `curl -s http://192.168.85.203/status | jq '.relays[0].ison,
  .meters[0]'` (`counters` = last 3 minutes in watt-minutes). Reference draw:
  ~2 W off, ~75-80 W idle in NixOS, **82 W** frozen (2026-10-08), **~69 W**
  hung and unreachable (2026-10-12, sitting in BIOS setup). Relay:
  `/relay/0?turn=off|on` — a hard reset; with AC BACK = Always On the box comes
  back up after it.
- Now in place: `processor.max_cstate=1` plus `zen-c6-disable.service`
  (prevention); the `sp5100_tco` hardware watchdog driven by systemd
  (`RuntimeWatchdogSec=30s`); panic on oops / hard lockup + reboot after 10 s;
  journald syncing every 30 s (with the 5-min default the last minutes before
  the freeze were lost from the log).
- **`max_cstate=1` alone did not prevent it**: three more idle freezes on
  2026-10-10/11 with it active. It only hides ACPI C2 from the OS; the SMU
  still used core CC6 / package PC6 (enable bits read set on the box). So
  `zen-c6-disable` clears them via MSR on every boot (`0xC0010292` bit 32,
  `0xC0010296` bits 6/14/22, as `zenstates.py --c6-disable`). Verify:
  `rdmsr -a 0xC0010292` → `52`, `rdmsr -a 0xC0010296` → `80808`
  (`nix-shell -p msr-tools`).
- **The watchdog works** (proven 2026-10-09..11): three freezes were reset
  automatically, the next boot following ~110 s after the last log line.
  **But the firmware can still strand it**: after the 4th reset in a row
  (10-11 14:08) the board stopped in BIOS setup with a "boot failure" message
  and sat there until 10-20 — that is the **~69 W "hung"** reading. 69 W =
  sitting in BIOS, 82 W = frozen OS. Only someone at the box clears it.
- **Diagnosing the next one**: `journalctl --list-boots`; a boot whose last
  lines are *not* the `systemd-shutdown` sequence ended abruptly. Read it with
  `journalctl -b -1 --since "YYYY-MM-DD HH:MM"` — a bare `--since HH:MM` means
  *today*. A watchdog-triggered reset shows up as a new boot after the gap.
  The summarize sweep logs every minute, so the freeze is within ~1 min of the
  last journal line. `/sys/fs/pstore` (efi_pstore) has stayed empty so far —
  no panic text survived, consistent with a hard freeze rather than a panic.
- Opening `/dev/watchdog0` (e.g. `wdctl`) can arm the timer; `wdctl` disarms it
  again on exit (magic close), so reading is safe — but don't hold the device
  open from scripts while systemd owns it.

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

## Secrets (sops-nix)

Secrets are age-encrypted and **checked into the repo** as ciphertext
(`secrets/secrets.yaml`), decrypted on the box at `nixos-rebuild` activation.
This replaced the old hand-placed plaintext files
(`/var/lib/whisper/hf-token.env`, `/etc/nixos/secrets/smb-secrets`).

- **Files**: `flake.nix` pulls the `sops-nix` input and adds
  `sops-nix.nixosModules.sops`; `sops.nix` declares the secrets and the
  decryption identity; `.sops.yaml` lists the recipients; `secrets/secrets.yaml`
  holds the ciphertext. Consumers read `config.sops.secrets.<name>.path`
  (`whisper.nix` → `hf-token`, `configuration.nix` CIFS mount → `smb-secrets`).
- **Recipients** (both can decrypt every secret): the operator's **admin age
  key**, held in `pass` at `admin-age-keys/universal` (lets a human edit); and
  the box's **SSH host key** `/etc/ssh/ssh_host_ed25519_key` (lets the machine
  decrypt at activation — never leaves the box, never in the repo). The host
  recipient is `age1xp2glg…`; regenerate it after any host-key change with
  `ssh-keyscan -t ed25519 192.168.85.30 | ssh-to-age`, update `.sops.yaml`,
  then `sops updatekeys secrets/secrets.yaml`.
- **Decrypted paths**: `/run/secrets/<name>` (tmpfs, mode 0400 root). The
  whisper worker and mount.cifs both run as root, so 0400-root is fine.
- **Edit the secrets** (operator, on a machine holding the admin key):
  ```
  SOPS_AGE_KEY="$(pass show admin-age-keys/universal | grep -v '^#')" \
    nix-shell -p sops --run 'sops secrets/secrets.yaml'
  ```
  Keys: `hf-token` = `HF_TOKEN=hf_…` (whole env-file line, the worker sources
  it); `smb-secrets` = a `username=`/`password=` block. **Run `pass` yourself**
  — the Claude Code harness is hard-blocked from invoking it (a global
  PreToolUse guard), so Claude handles only public data (age *recipients*),
  never the private key or plaintext secret values.
- **Ordering**: secrets materialize at activation, before the (lazy,
  `x-systemd.automount`) NAS mount and the path-triggered whisper worker ever
  need them — no boot-time race.

## Storage model: the NAS is the source of truth

Everything durable the pipeline produces lives on the NAS share, in **one folder
per transcript**:

```
/media/NAS/Netspace/artifacts/transcriptions/
  _inbox/         audio drop point — copy a file here from any machine
  _failed/        failed + cancelled audio (UI "requeue" moves it back to _inbox/,
                  "dismiss" parks it in _failed/_dismissed/ — never deleted)
  <stem>/         source audio + .txt/.srt/.vtt/.tsv/.json/.speakers.txt
                  + <stem>.summary[.N].md + <stem>.notes.md
```

`/srv/whisper` on the SSD is now **pure scratch** and can be wiped at any time:
`inbox/` (staging for HTTP/scp uploads), `work/` (the ext4 job dir podman
bind-mounts — this must *not* move to CIFS), `control/` (UI sentinels) and
`summaries/{inbox,work,failed,control}` (job specs). There is deliberately no
local `transcripts/`, `processed/` or `failed/` any more.

**Why**: with a local original plus a NAS "delivery copy", a transcript
corrected by hand on the share was invisible — the summarizer re-read the
untouched local file. One copy, one truth. The summarizer now reads the very
file you edited.

- **inotify does NOT work across CIFS.** Measured on this box: `inotifywait` on
  a NAS dir saw *nothing* when a second machine created files there, while
  `ls`/`stat` saw them immediately. So a systemd `.path` unit is blind to the
  NAS drop dir — it is **polled** by `whisper-worker`'s timer, which is why that
  timer is **30s** and no longer a 10-min safety net. That 30s is the pickup
  latency for a file copied onto the share. The local `inbox/` keeps its
  instant `.path` unit.
- **NAS offline** (headless box, WoL — it happens): both workers probe the share
  by *writing* a file (the automount trigger can look mounted when the CIFS
  mount underneath failed, so only a create is conclusive) and **no-op** when it
  is down. Queued audio and queued summary specs simply wait for the next sweep
  — jobs are delayed, never dropped or failed. The UI shows a distinct
  `nas unreachable` badge (separate from `offline`, which means the box itself
  is unreachable). `summarize-worker`'s sweep is 1 min for the same retry reason.
- nginx only ever **reads** the share (uploads still land in the local staging
  inbox), so it needs no relaxation of its `ProtectSystem=strict` — verified
  that a `ProtectSystem=strict` + `ProtectHome=yes` unit running as `nginx` can
  read the mount as-is. Do not add NAS `ReadWritePaths` to nginx: resolving one
  at unit start would trigger the automount and could keep nginx from starting
  while the NAS is down, which is exactly when the UI needs to come up to say so.
- Verified CIFS semantics this design leans on: `O_EXCL` create (summary
  numbering), atomic `os.replace` (notes cache), and directory-mtime bump on
  file create (the UI's listing cache).
- **Migration**: `whisper-nas-migrate.service` (runs on every switch/boot,
  ordered before `whisper-worker`) copies anything still in the old local
  `transcripts/`, `processed/` and `failed/` into the NAS layout. It is
  **non-destructive and idempotent** — never overwrites, never deletes, skips
  what the NAS already has, and no-ops once those dirs are gone. **Cleanup after
  migration is manual**: check the NAS, then `rm -rf /srv/whisper/{transcripts,processed,failed}`
  on the box.

## Whisper transcription pipeline (`whisper.nix`)

- Web UI: `http://192.168.85.30:8990/` — single static page
  (`whisper-ui/index.html`, no build step, no backend daemon). It polls nginx
  `autoindex_format json` listings under
  `/status/{inbox,nas-inbox,work,failed,transcripts}/` to show all jobs
  (including CLI/scp/NAS-copy uploads), and cancels/requeues/dismisses by
  PUTting `<name>.cancel` / `<name>.requeue` / `<name>.dismiss` sentinels to `/control/`, handled
  by the `whisper-control` path unit (kills the `whisper-job` podman
  container, or moves files between the inboxes and `_failed/`). A cancelled
  job's audio lands in `_failed/` like any failure. **Sentinel PUTs must have a
  non-empty body**: nginx's WebDAV rejects a zero-length PUT with 500 (`PUT
  request body must be in a file`), so the UI sends a 1-byte body (`control` /
  `sumControl` in `index.html`) — the control services only test existence, so
  the content is irrelevant. Same applies to the `/summaries/control/` cancels.
- **Three ways to submit audio**, all equivalent once queued:
  `curl -T file.m4a http://192.168.85.30:8990/` (nginx WebDAV PUT, atomic
  rename into `/srv/whisper/inbox`) · scp into that dir · copy the file into
  the NAS `_inbox/` from any machine (polled, ~30s).
- systemd path unit (local inbox) + 30s sweep timer (the *only* trigger for
  the NAS drop dir) → `whisper-worker` (bash, runs as root) → one-shot rootful
  podman job per file with `--device nvidia.com/gpu=all` (CDI). No VRAM held
  between jobs; ~15× realtime.
- On success the whole job dir is **moved** to `<NAS>/…/transcriptions/<stem>/`:
  `.txt/.srt/.vtt/.tsv/.json` + jq-generated `.speakers.txt`, plus the source
  audio under its original upload name (so a `.2ch`/`.lang-XX` marker stays
  visible). Failures → `_failed/` (requeue = move back to `_inbox/`). A NAS
  write failure at that moment requeues the audio into the local inbox rather
  than losing it. Logs: `journalctl -u whisper-worker`.
- The CIFS `username=`/`password=` credentials are the `smb-secrets` entry in
  the encrypted `secrets/secrets.yaml`, decrypted by sops-nix to
  `/run/secrets/smb-secrets` at activation (see **Secrets (sops-nix)**). Until
  that entry has real values the mount can't authenticate, and since the NAS is
  the source of truth the pipeline then does nothing at all (see the NAS-offline
  behavior above) rather than degrading to local-only.
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
- Speaker diarization only activates when the `hf-token` secret decrypts to a
  `HF_TOKEN=hf_…` line at `/run/secrets/hf-token` (gated pyannote models; user
  must accept terms of `pyannote/speaker-diarization-3.1` and
  `pyannote/segmentation-3.0` on huggingface.co). Without it, transcription
  runs but speakers show as `SPEAKER_?`. Status: token installed since
  2026-07-19 (now carried in `secrets/secrets.yaml`) — diarization active.
- nginx runs under `ProtectSystem=strict`; the inbox is whitelisted via
  `ReadWritePaths`. New writable paths for nginx need the same treatment.

## Summarization pipeline (`summarize.nix`)

Summarize a transcript via a local **Ollama running Qwen3 14B** (GGUF Q4) on the
1080 Ti. Unlike WhisperX this is not a PyTorch problem — Ollama ships its own
llama.cpp CUDA kernels; the Pascal fix is the `cudaCapabilities` pin above.

**Architecture is fully async and file-driven — a second copy of the whisper
pipeline, not an HTTP service.** (The old synchronous `POST /summarize` daemon
`whisper-summarize.service`, its `= /summarize` nginx proxy, the `DynamicUser`
read-only-fs workaround, and the 503-on-GPU-busy path were **all retired**.) You
drop a small JSON job spec in an inbox and poll for the resulting file — exactly
like transcripts.

- **Job dirs** (tmpfiles, parallel to the audio inbox): `/srv/whisper/summaries/{inbox,work,failed,control}`.
  `inbox`/`control` are `2770 whisper whisper` (setgid, group-writable) so nginx
  (in the `whisper` group) can PUT into them; `work`/`failed` are `0770` (root
  worker writes, group reads for the UI listings).
- **Submit**: `PUT http://192.168.85.30:8990/summaries/inbox/<jobid>.json` with a
  spec body. nginx maps the URL onto the dir via `root = /srv/whisper` (same
  trick as `/control/`, no dav+alias pitfall). Spec keys: **`stem`** (required —
  names the NAS archive folder `<stem>/`, from which the worker reads
  `<stem>.speakers.txt` preferred else `<stem>.txt`; same path-safety as before:
  a bare name that must canonicalize to a direct child of the archive root),
  plus optional `prompt`, `language`, `model`, `num_ctx`, `temperature`,
  `target_words`, `label` (UI display only). `<jobid>` is a UI-generated id; the
  stem lives *inside* the spec (prompt is free text, can't be a filename).
- **Target length**: every summary has a word target — **`target_words`** in the
  spec, default **500** (`SUMMARIZE_TARGET_WORDS`), a strict **±10%** range
  (450–550 for the default). The render pass states the target and the hard
  bounds in both the system and user roles so length compliance beats stylistic
  drift; it applies **only to the final render** (single-pass and from-notes),
  never to the purpose-neutral per-chunk condense. The UI exposes it as a
  per-transcript number input next to the `+ prompt` box (persisted under
  `whispersumwords`).
- **Output language** (`detect_language` in `summarize.nix`): the summary must
  come out in the transcript's language, but **you cannot rely on the model to
  infer "same language as the transcript"** — it's reliable in the single-pass
  render, but the chunked path's condense step (an all-English instruction
  scaffold building bullet notes) silently flips the running-**notes** to
  English, and the render then faithfully mirrors the now-English notes → an
  English summary of a German talk. Worse, the poisoned `<stem>.notes.md` cache
  makes every *future* summary of that stem English too. Fix: the worker
  **auto-detects** the transcript language (cheap stopword/Cyrillic heuristic
  over the whole transcript, limited to the pipeline's `de/en/fr/ru`) and states
  it **explicitly** ("Write the notes/summary in German…") in *every* pass —
  condense and render. The spec's optional `language` overrides detection; an
  ambiguous ~50/50 bilingual mix detects nothing and falls back to the generic
  instruction. **Mixed-language transcripts** (German with interspersed English)
  detect the **dominant** language (counts aren't close) and force it, which
  keeps the summary coherent instead of drifting. **Diagnose** a wrong-language
  summary by `head`-ing `<stem>.notes.md` — if the *notes* are already the wrong
  language, delete the cache and re-summarize so the corrected condense reruns.
- **Poll**: `/status/summaries/{inbox,work,failed}/` autoindex-JSON listings.
- **Cancel**: `PUT /summaries/control/<jobid>.cancel` (see cancel semantics below).
- **Result**: `<stem>.summary[.N].md` written **into the NAS `<stem>/` folder**,
  beside the transcript it came from (race-free `O_EXCL` numbering — each
  summarize **appends** a new numbered summary; `O_EXCL` verified working over
  CIFS), plus for chunked jobs `<stem>.notes.md`. There is no separate delivery
  step any more — the write *is* the delivery.
- **Source of truth**: the worker reads the transcript straight off the share,
  so **correcting a transcript by hand changes what the next summary is built
  from**. That was the whole point of the NAS-as-truth change. The notes cache
  would have reintroduced exactly that staleness for long transcripts (a repeat
  job reuses `<stem>.notes.md` and skips the condense entirely), so the cache is
  **mtime-invalidated**: `.notes.md` older than the transcript is treated as
  absent and re-condensed. No manual cache deletion needed after an edit.
- **systemd**: `summarize-worker.service` (oneshot, **root** — no DynamicUser) +
  `.path` (`DirectoryNotEmpty=…/inbox`) + a 1-min sweep timer (short because it
  also retries jobs queued while the NAS was down); and
  `summarize-control.service` + `.path` (`…/control`). Mirrors the `whisper-worker`
  / `whisper-control` trio. `TimeoutStartSec=12h` because a job blocks on the GPU
  flock while a transcription runs and may itself be a multi-pass condense.
- **Worker algorithm** (pure-stdlib Python, drains inbox one job at a time):
  move spec `inbox → work` (this **is** the "running" signal the UI polls) →
  estimate tokens (~4 chars/tok) → take the GPU flock → branch → release lock →
  write outputs → move spec out of `work/` (success removes it; any error moves
  it to `failed/`, kept for inspection).
  - **Fits one pass** (est ≤ `0.8·num_ctx`): single Ollama call, `keep_alive=0`.
  - **Too big → chunked condense.** Break the transcript on **line boundaries**
    (never mid-segment) into ~12k-token chunks. **Refine / rolling carry-over:**
    maintain a bounded, purpose-**neutral** running-notes digest; each pass gets
    *(notes so far + next chunk) → (updated notes)*. The condense instruction is
    "capture everything faithfully", **NOT** the user's purpose prompt — applying
    "list action items" per chunk would discard context later chunks need. The
    user's prompt is applied only in a **final render pass** over the completed
    notes. **The model is kept WARM across chunk passes** (per-call
    `keep_alive="10m"`) under the single held GPU lock, and only force-unloaded at
    the very end — reloading ~9 GB per chunk is the whole reason chunking and the
    GPU lock are co-designed.
  - **Notes cache**: the digest is saved as `<stem>.notes.md` (surfaced as a link
    in the UI). A later job for the **same long stem** skips chunking entirely and
    does only the fast final render over the cached notes. Short transcripts never
    produce a notes file.
  - **Live chunk progress**: while a chunked job runs, the worker publishes its
    position as an **empty marker file** in `work/`, the counts encoded in the
    filename: `<jobid>.progress.<phase>.<done>.<total>` (`phase` =
    `condense`|`render`). One marker per job (previous unlinked before the next),
    cleared in `process()`'s `finally`. The UI already polls the `work/`
    autoindex, so it reads live progress from the **filename alone** — no body
    fetch, no extra endpoint (the `specIds`/running-signal logic ignores non-JSON
    names, so markers don't disturb it). Progress is cosmetic: a marker write that
    fails never fails the job. The UI *also* predicts the chunk count up front
    from the source size using the worker's own budget (`SUMMARIZE_CHUNK_CHARS` =
    `max(1000, num_ctx−3800)·4` chars/chunk), shown in the long-transcript note.
- **GPU lock (VRAM 11 GB, shared with whisper)**: Qwen3-14B weights are ~9 GB, so
  the two serialize via `flock` on `/run/whisper-gpu.lock` (`0660 root:whisper`).
  The worker takes it around **all** its Ollama calls for a job and holds it until
  the model is confirmed unloaded (final call `keep_alive=0`, `/api/ps` polled;
  on cancel/error a `force_unload` is issued first). The whisper side holds the
  lock per container run, so a summary slips in between queued whisper jobs. A
  queued summary simply **waits (blocking flock)** for an in-flight transcription
  — there is no synchronous caller, hence **no timeout and no 503** any more.
- **Cancel semantics** (best-effort, per design): a **queued** job — `summarize-control`
  moves its spec `inbox → failed` and clears the sentinel. A **running** job —
  control hands the sentinel to the worker by moving it to `work/<jobid>.cancel`
  (this **empties `control/`** so its `DirectoryNotEmpty` path unit doesn't
  busy-loop). The worker's Ollama calls are **streamed** and poll the sentinel
  between tokens (`call_ollama(..., cancel_check)`), so a cancel **aborts the
  in-flight generation** — closing the HTTP connection makes Ollama stop
  generating (it cancels on client disconnect), freeing the GPU within ~a token
  rather than waiting for the chunk to finish. The sentinel is also checked at
  each chunk boundary and in `control/` directly (in case control hasn't run
  yet). Stale sentinels are just cleared.
- **Context window**: `num_ctx` (16k, `SUMMARIZE_NUM_CTX`) is capped by VRAM, not
  Qwen3 (native 32k): ~9 GB weights leave ~2 GB for KV; fp16 KV is ~0.16 MB/token
  (40 layers, 8 GQA KV heads, head-dim 128) → 16k would need ~2.6 GB and spill.
  `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` (q8 KV *requires*
  flash-attn) roughly halve that to ~1.3 GB. 16k is now the **per-pass / per-chunk**
  ceiling, not the whole-transcript ceiling — longer inputs are chunked, not
  truncated. Raising ctx to 24k+ risks OOM on this card.
- **No delivery step**: `<stem>.summary*.md` and `<stem>.notes.md` are written
  straight into the NAS `<stem>/` folder. The old best-effort copy-to-NAS path
  (`deliver_nas`) is **gone**, along with `SUMMARIZE_NAS_ROOT`. The worker runs as
  **root**, which bypasses the CIFS masks, so `dir_mode=0777`/`file_mode=0666` in
  `configuration.nix` is not needed for the workers — but nginx reads the archive
  as user `nginx`, so leave those masks open.
- The worker sends `think:false` (Qwen3 is a thinking model) and strips any stray
  `<think>…</think>` defensively.
- **Model provisioning**: `services.ollama.loadModels = [ "qwen3:14b" ]` pulls the
  model via a separate oneshot (`ollama-model-loader`) after ollama starts — it
  does not block the switch. First deploy: not ready until that ~9 GB pull
  finishes; `journalctl -u ollama-model-loader` to watch.
- **UI integration** (`whisper-ui/index.html`): the **summarize** button now just
  builds a spec and `PUT`s it to `/summaries/inbox/<jobid>.json` (no awaited
  result). In-flight jobs show as **chips** on the matching transcript card
  (`summary · queued/running/failed` + cancel/dismiss), attributed via a
  `localStorage` `jobid → {stem,label}` map (`whispersumjobs`) — single-user, a
  second browser wouldn't know an in-flight job's stem, but the finished file is
  shared regardless. The three `/status/summaries/*` listings are added to
  `poll()`; `reconcileSumjobs()` drops a tracked job once it's `seen` then absent
  (its `.summary.N.md` shows on its own). `.notes.md` is taught to the archive
  grouping (`NOTES_RE`) so it attaches to `<stem>` as a link (like `SUMMARY_RE`
  for summaries), never a bogus group. The `+ prompt` textarea (persisted under
  `whisperprompts`) and numbered `#N view/.md` summary chips are unchanged. The
  token estimate is now **informational** ("longer than one pass; will be
  condensed in chunks"), not a truncation blocker.
- **Two-level archive listing** (`listStems()` in `index.html`): the archive is
  one folder per transcript, so `/status/transcripts/` yields *directories* and
  each stem's files come from `/status/transcripts/<stem>/` (nginx `autoindex`
  serves any depth under an `alias` — the same property `/status/work/<jobdir>/`
  already relied on). Refetching every folder each 4s poll would be absurd, so
  folder listings are **cached and refreshed only when the parent listing shows
  the directory's mtime moved** (CIFS does bump a dir's mtime on file create —
  measured), plus a 60s ceiling to catch in-place edits, which do *not* move it.
  File **content** is always fetched `cache:'no-store'` and never comes from this
  cache. Folder names starting with `_` are the reserved drop dirs, not stems.
  Every artifact URL is `/transcripts/<stem>/<file>` via the `fileUrl()` helper —
  **both** segments need `encodeURIComponent` (stems are user filenames and
  routinely contain spaces and brackets).
- **Poll must not clobber the archive** (`render()`): the 4s poll re-renders, and
  a naive `#archive.innerHTML = …` replaces every node — which resets the scroll
  offset of open transcript/summary `<pre>` previews and drops focus/caret in the
  prompt textarea and the target-words input, every few seconds. Three defenses,
  all required: (1) skip the rebuild entirely while *any* focused
  textarea/input/select lives inside `#archive` (values live in
  `prompts`/`sumWords`, so a later rebuild restores them); (2) compare the freshly
  built markup against `archiveHtml` and skip when identical — the normal idle
  case; (3) when it did change, carry the `scrollTop` of every `[data-scroll]`
  preview across the swap (keys `t:<stem>` / `s:<summary file>`). For (2) to be
  worth anything the markup must be **time-invariant**: per-second counters are
  emitted as *empty* `<span class="elapsed" data-since=…>` and filled in place by
  `tick()` (run at the end of `render()`), never interpolated into the HTML
  string — otherwise a running job makes every poll "different" and rebuilds.
  The top **`#jobs` list** gets defense (2) too, for a different reason: a
  rebuild landing between mousedown and mouseup swallows the click (seen as a
  `dismiss` that never sent its PUT). Since its nodes now persist, a clicked
  control button re-enables itself after 10s (`busy()`) in case nothing changed.
- **Named prompt presets** (`summarize-prompts.nix`): a standalone Nix attrset
  of `name → prompt text` — the one place to add/experiment with reusable
  summary prompts. `whisper.nix` renders it to `/prompts.json` (via
  `pkgs.writeTextDir` + an exact-match nginx location, so it doesn't shadow the
  PUT inbox at `/`); the UI fetches it once on load and shows a `preset…`
  dropdown in each transcript's `+ prompt` box. Picking a preset just drops its
  text into that transcript's prompt textarea (→ the spec's free-text `prompt`
  as usual) — **the worker is untouched**, a preset is nothing but prompt text
  keyed by a friendly name. Add a preset = add an attribute + `nix run .#deploy`.
  Missing/broken `/prompts.json` just hides the dropdown; the free-text box still
  works. Ships with one preset, `diary`.
- **Copy buttons** (transcript `copy` in the card row, per-summary `copy` in
  each `#N` chip) re-fetch the file `no-store` and put it on the clipboard.
  The UI is plain `http://<LAN ip>` — **not a secure context**, so
  `navigator.clipboard` is undefined; `copyText()` falls back to a hidden
  textarea + `execCommand('copy')` (verified working over http). Don't "clean
  up" that fallback.

## Image generation (`comfyui.nix`, `comfyui/`)

ComfyUI at `http://192.168.85.30:8188/`, LAN-only. User docs (start/stop,
models, LoRAs, the torch pin, timings) are in README.md. Non-obvious facts:

- **Image built on the box** by the unit itself (`comfyui-launch`): `podman
  build` of `./comfyui` minus `workflows/`, tagged with that store path's
  hash. Any pin change gives a new tag, so the first start after a deploy
  rebuilds (6–15 min, PyPI ~30 MB/s, slower while the model fetch competes)
  and removes superseded tags. `Type=exec`, so the build never blocks
  `nixos-rebuild switch`.
- **`--network host`, not `-p`**: podman's port publishing DNATs via FORWARD
  and bypasses the NixOS INPUT firewall. LAN-only is enforced by an iptables
  rule with `-s 192.168.85.0/24` in `networking.firewall.extraCommands`.
  Don't move the port to `allowedTCPPorts` (that opens it to every source).
- **GPU lock**: `comfyui/gpu_lock` (a no-node "custom node") wraps
  `execution.PromptExecutor.execute` (v0.42.1 internals, so re-check on a
  ComfyUI bump) and takes `/run/whisper-gpu.lock` blocking per prompt. It keeps
  lock + models for 300 s, then `unload_all_models()` + empty cache, and only
  then releases. Idle CUDA context ~140 MB (box total 175 MiB). The lock gid
  (`whisper`, 991) is not fixed and is looked up at launch.
- **pip policy is a config file, not env vars**: `PIP_USER=1` also makes
  `pip list` show only the user site. Manager reads `pip list`, concluded
  torch was missing, and started "fixing" packages. `pip.conf`'s `[install]`
  section scopes `user=true` + the torch constraint to installs only.
  `[ComfyUI-Manager] PyTorch is not installed` at startup is still printed
  (that check wants torchaudio) and is harmless.
- **Benchmarks (2026-10-21, 1024², warm)**: SDXL 30 steps 98 s (3.2 s/it),
  Z-Image Turbo bf16 8 steps ~72 s (8.6 s/it), FLUX.1-dev Q6_K 20 steps
  ~643 s (32 s/it). All compute in fp32 (ComfyUI's Pascal default).
  `--force-fp16` 2.5× slower; `--force-fp32` = same speed + more VRAM.
  Z-Image bf16 safetensors (12.3 GB, DynamicVRAM-streamed) beat the Q8_0
  GGUF (79 s); Flux Q5_K_S = Q6_K speed (compute-bound). FLUX.1-dev is
  slow because of the card itself; there's no flag to fix it. Faster options:
  fewer steps, a lower resolution, or a distilled model (schnell/Z-Image).
- **Models are ungated**, so no HF token is needed. The Flux VAE
  `ae.safetensors` comes from Comfy-Org's Z-Image repackage (BFL's own copy is
  gated). Z-Image uses the FLUX.1 autoencoder, and it decodes FLUX.1-dev
  correctly (verified by output). `comfyui-models` trusts any existing file (no re-hash) —
  delete one to force a re-download.

## Interactive LLM endpoint (`local-llm.nix`)

`POST http://192.168.85.30:8990/v1/chat/completions` — OpenAI-shaped,
synchronous, same Ollama/Qwen3 as the summarizer. First client: the Emacs
proofreader `tchecker` (`~/config/emacs/modules/tchecker.el`), which tries this
first and falls back to OpenAI when the box is off **or busy**.

- nginx proxies to `llm-proxy.service` (stdlib Python on `127.0.0.1:11435`,
  `DynamicUser` + group `whisper` for the lock file). Ollama itself stays on
  localhost: no auth, and a direct call would bypass the GPU lock.
- **GPU lock, non-blocking**: the proxy `flock -n`s `/run/whisper-gpu.lock`;
  if a transcription or summary holds it → **503 `gpu_busy`** immediately
  (clients fall back, they don't wait). The lock is the only race-free busy
  signal — the `/status/*` listings are a snapshot a job can start right after.
- **Warm window**: after a request the proxy *keeps* the lock and the model
  loaded for `LLM_PROXY_IDLE_SECS` (180s), so back-to-back calls skip the ~9 GB
  reload. On expiry it unloads, waits for `/api/ps` to clear, then releases.
  Lock and warm model are inseparable — a resident model without the lock would
  let whisper start next to it and OOM. Cost: a queued transcription/summary
  waits up to one window.
- The request's `model` is ignored (always `qwen3:14b`); `num_ctx` 8192 (enough
  for tchecker's 10k-char cap in + out). Logs: `journalctl -u llm-proxy`.

## Electricity / idle power (`disk-spindown.nix`)

This is an old Zen1 gaming tower (Ryzen 5 1600X + GTX 1080 Ti + 32GB), a
*high-idle* platform: estimated wall idle ~95-120W (no wall meter yet — AMD
Zen1 RAPL is unreliable, so this is a component budget, not a measurement). At
~€0.35/kWh that's ~€275-370/yr running 24/7 — roughly €180-250/yr *more* than a
purpose-built low-power NAS. Known idle contributors: 1080 Ti ~17W in P8
(measured; Pascal won't idle lower — the standing cost of keeping the card
warm for whisper/ollama), and the spinning HDDs below.

- **HDD spindown**: NixOS only uses the NVMe (ext4 root + ESP). The three
  *rotational* disks (2× internal SATA Windows-NTFS + 1 USB exfat) are never
  mounted/polled by Linux, so `disk-spindown.nix` runs **hd-idle** to park them
  after 10 min idle. Nothing wakes them (no smartd, no udisks2), so they spin
  down once after boot and stay down. Matching is **by-id only** — kernel
  letters (sdb/sdc…) reshuffle between boots here, even between SSH sessions.
  Default `scsi` STOP-UNIT parks the internal SATA disks (verified); USB is
  best-effort. Swapping a disk ⇒ update the `spinDisks` ids.
- The box now sits on a Shelly with a power meter (`192.168.85.203`, see
  **Hangs and self-recovery**) — read idle vs. whisper-job draw there to turn
  the estimate above into fact.

## Gotchas

- First switch after enabling a kernel-module change (e.g. the NVIDIA driver)
  needs a reboot of the box; services like the CDI generator fail until then.
- `hardware-configuration.nix` carries real disk UUIDs — regenerate on the box,
  never hand-edit.
