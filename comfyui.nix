{ config, pkgs, lib, ... }:

# Local image generation: ComfyUI on the 1080 Ti, LAN-only.
#
#   web UI:   http://192.168.85.30:8188/   (firewalled to 192.168.85.0/24)
#   state:    /var/lib/comfyui  (models/, custom_nodes/, user/, output/, input/)
#   logs:     journalctl -u comfyui        models: journalctl -u comfyui-models
#
# RUNS AS A PODMAN CONTAINER BUILT ON THE BOX, like WhisperX runs from an image —
# not a nixpkgs python env: ComfyUI needs PyPI CUDA torch wheels, and the Pascal
# constraint is all about WHICH torch wheel (see comfyui/Containerfile: cu126 is
# the last wheel flavour with sm_6x kernels). The build context is
# ./comfyui minus the workflows; the image tag is that store path's hash, so
# changing any pin (Containerfile, torch-pins.txt, requirements.lock) gives a
# new tag and the next start rebuilds (~6 min, then superseded tags are
# removed). The workflows are copied in separately and do not trigger a build.
#
# GPU SHARING: the card (11 GB) is shared with whisper, summarize and llm-proxy
# via the flock on /run/whisper-gpu.lock. ComfyUI takes it per prompt — a busy
# GPU makes the prompt wait — and holds it, models loaded, for a warm window
# afterwards (COMFY_GPU_IDLE_SECS) before unloading and releasing. See
# comfyui/gpu_lock/__init__.py. Idle, the process still holds a CUDA context
# (~140 MB measured), which the other jobs fit beside.
#
# --network host instead of -p: podman's port publishing DNATs through the
# FORWARD chain and would bypass the NixOS (INPUT) firewall entirely, making the
# LAN-only rule below meaningless. --log-driver none: the attached `podman run`
# already feeds the unit's journal; podman's journald driver logged every line
# a second time.
let
  uid = 1002;
  stateDir = "/var/lib/comfyui";
  port = 8188;
  lanSubnet = "192.168.85.0/24";

  # Kept warm after a prompt (GPU lock + loaded models); also the worst-case
  # extra wait for a transcription queued behind an image session.
  idleSecs = 300;

  # Precision flags: none, on purpose — benchmarked on this card (2026-10-21).
  # On Pascal ComfyUI's default already stores weights in fp16/bf16 and
  # COMPUTES in fp32 ("manual cast: torch.float32"), and the VAE runs fp32, so
  # --fp32-vae is a no-op. SDXL, 30 steps at 1024²: default 98 s / 10.6 GB,
  # --force-fp32 97 s / 10.9 GB (same speed, more VRAM), --force-fp16 240 s
  # (Pascal's fp16 ALU rate is crippled — 2.5x slower). Never force fp16 here.
  extraArgs = [ ];

  context = lib.fileset.toSource {
    root = ./comfyui;
    fileset = lib.fileset.difference ./comfyui ./comfyui/workflows;
  };
  tag = builtins.substring 0 12 (builtins.baseNameOf "${context}");
  image = "localhost/comfyui:${tag}";

  # Models: { dir (under models/), file, HF repo, pinned revision, path in repo,
  # sha256 }, or { dir, file, url, sha256 } for a file whose canonical home is
  # not HF. Ungated repos only — no token needed. If a gated repo is ever
  # added, the fetcher already sends the sops `hf-token` (to HF URLs only).
  models = [
    # SDXL workhorse — Juggernaut XL v9 (photoreal SDXL fine-tune), includes VAE.
    { dir = "checkpoints"; file = "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors";
      repo = "RunDiffusion/Juggernaut-XL-v9"; rev = "cf419233522daa0b9ea36c3aff98fa2cab1fb0fb";
      path = "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors";
      sha256 = "c9e3e68f89b8e38689e1097d4be4573cf308de4e3fd044c64ca697bdb4aa8bca"; }

    # Z-Image Turbo — diffusion model, Qwen3-4B text encoder, Flux VAE. The
    # bf16 original (12.3 GB) does not fit the card, but DynamicVRAM streams
    # the rest and it still beat the Q8_0 GGUF (71 s vs 79 s per image; the
    # GGUF pays per-layer dequant) — at full quality.
    { dir = "diffusion_models"; file = "z_image_turbo_bf16.safetensors";
      repo = "Comfy-Org/z_image_turbo"; rev = "6fc90a3b1b653e935a0d175e260736de25b84df5";
      path = "split_files/diffusion_models/z_image_turbo_bf16.safetensors";
      sha256 = "2407613050b809ffdff18a4ac99af83ea6b95443ecebdf80e064a79c825574a6"; }
    { dir = "text_encoders"; file = "qwen_3_4b.safetensors";
      repo = "Comfy-Org/z_image_turbo"; rev = "6fc90a3b1b653e935a0d175e260736de25b84df5";
      path = "split_files/text_encoders/qwen_3_4b.safetensors";
      sha256 = "6c671498573ac2f7a5501502ccce8d2b08ea6ca2f661c458e708f36b36edfc5a"; }
    # The FLUX.1 autoencoder, from Comfy-Org's ungated Z-Image repackage
    # (black-forest-labs' own ae.safetensors is gated). Shared by Z-Image and
    # FLUX.1 [dev]; decodes both correctly.
    { dir = "vae"; file = "ae.safetensors";
      repo = "Comfy-Org/z_image_turbo"; rev = "6fc90a3b1b653e935a0d175e260736de25b84df5";
      path = "split_files/vae/ae.safetensors";
      sha256 = "afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38"; }

    # FLUX.1 [dev] as GGUF + CLIP-L + T5-XXL (GGUF Q8_0). Q6_K (9.9 GB) loads
    # fully (peak ~9.8 GB at 1024²; the encoders are offloaded before
    # sampling). Q5_K_S measured the same speed — compute-bound in fp32 — so
    # the larger quant costs nothing.
    { dir = "diffusion_models"; file = "flux1-dev-Q6_K.gguf";
      repo = "city96/FLUX.1-dev-gguf"; rev = "3c60ac659f4b1f2ab3ca8bd4488272069b36a148";
      path = "flux1-dev-Q6_K.gguf";
      sha256 = "9566d56031d7f8de184bb5a0393073956ec4e28b32db3f860bd2b87edca04d13"; }
    { dir = "text_encoders"; file = "clip_l.safetensors";
      repo = "comfyanonymous/flux_text_encoders"; rev = "6af2a98e3f615bdfa612fbd85da93d1ed5f69ef5";
      path = "clip_l.safetensors";
      sha256 = "660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd"; }
    { dir = "text_encoders"; file = "t5-v1_1-xxl-encoder-Q8_0.gguf";
      repo = "city96/t5-v1_1-xxl-encoder-gguf"; rev = "005a6ea51a7d0b84d677b3e633bb52a8c85a83d9";
      path = "t5-v1_1-xxl-encoder-Q8_0.gguf";
      sha256 = "9ec60f6028534b7fe5af439fcb535d75a68592a9ca3fcdeb175ef89e3ee99825"; }

    # Upscalers (ESRGAN family, loaded by spandrel), ~64 MB each.
    # Real-ESRGAN: BSD, general-purpose, from xinntao's own release (the HF
    # copies are third-party mirrors). Loaded weights-only, so the .pth
    # pickle is not executed.
    { dir = "upscale_models"; file = "RealESRGAN_x4plus.pth";
      url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth";
      sha256 = "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1"; }
    # 4x-UltraSharp: crisper on generated images; CC BY-NC-SA 4.0 (personal
    # use). From the author's own repo.
    { dir = "upscale_models"; file = "4x-UltraSharp.safetensors";
      repo = "Kim2091/UltraSharp"; rev = "920fe218c211f831b43cb30327f203e2b59f5dab";
      path = "4x-UltraSharp.safetensors";
      sha256 = "36a340b5509b699d2c06cb445ddc1d3d39199ac734d889ed6d7915f60e05bcbc"; }
  ];

  manifest = pkgs.writeText "comfyui-models.txt" (lib.concatMapStrings (m:
    "${m.dir} ${m.file} ${m.url or "https://huggingface.co/${m.repo}/resolve/${m.rev}/${m.path}"} ${m.sha256}\n"
  ) models);

  # Idempotent: a file that exists is trusted (hashing ~50 GB on every boot is
  # not worth it); a new one is downloaded to .part (resumable), verified, and
  # only then renamed into place — ComfyUI never sees a half file.
  fetchModels = pkgs.writeShellApplication {
    name = "comfyui-fetch-models";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      auth=()
      if [ -r /run/secrets/hf-token ]; then
        # shellcheck disable=SC1091
        . /run/secrets/hf-token
        [ -n "''${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN")
      fi
      rc=0
      while read -r dir file url sha; do
        dest=${stateDir}/models/$dir/$file
        [ -e "$dest" ] && continue
        install -d -o ${toString uid} -g ${toString uid} "$(dirname "$dest")"
        echo "fetching $dir/$file"
        # The token is for HF; never hand it to another host.
        hdr=()
        [[ $url == https://huggingface.co/* ]] && hdr=("''${auth[@]}")
        if ! curl -fsSL --retry 5 --retry-delay 10 -C - "''${hdr[@]}" -o "$dest.part" "$url"; then
          echo "FAILED: $dir/$file (gated repo? check the hf-token secret)" >&2; rc=1; continue
        fi
        if [ "$(sha256sum "$dest.part" | cut -d' ' -f1)" != "$sha" ]; then
          echo "FAILED: $dir/$file sha256 mismatch, discarded" >&2; rm -f "$dest.part"; rc=1; continue
        fi
        chown ${toString uid}:${toString uid} "$dest.part"
        mv "$dest.part" "$dest"
        echo "ok: $dir/$file"
      done < ${manifest}
      exit "$rc"
    '';
  };

  launch = pkgs.writeShellApplication {
    name = "comfyui-launch";
    runtimeInputs = [ pkgs.podman pkgs.coreutils pkgs.gnugrep pkgs.getent pkgs.findutils ];
    text = ''
      if ! podman image exists ${image}; then
        echo "building ${image} (first start after a pin change, takes minutes)"
        podman build --pull=missing -t ${image} -f ${context}/Containerfile ${context}
        podman images --format '{{.Repository}}:{{.Tag}}' \
          | grep '^localhost/comfyui:' | grep -vx ${image} | xargs -r podman rmi || true
        podman image prune -f >/dev/null || true
      fi

      # Repo-managed workflows are reinstalled on every start (the repo is their
      # source of truth) — save edits in the UI under a different name.
      find ${./comfyui/workflows} -maxdepth 1 -name '*.json' -exec \
        install -o ${toString uid} -g ${toString uid} -m 0644 -t ${stateDir}/user/default/workflows/ {} +

      # The lock file is 0660 root:whisper; whisper's gid is not fixed, so look
      # it up rather than hard-coding it.
      wgid="$(getent group whisper | cut -d: -f3)"

      exec podman run --rm --replace --name comfyui \
        --network host \
        --device nvidia.com/gpu=all \
        --user ${toString uid}:${toString uid} --group-add "$wgid" \
        --cap-drop all --security-opt no-new-privileges \
        --log-driver none \
        -v ${stateDir}:/data \
        -v /run/whisper-gpu.lock:/run/gpu.lock \
        -e GPU_LOCK=/run/gpu.lock \
        -e COMFY_GPU_IDLE_SECS=${toString idleSecs} \
        ${image} --listen 0.0.0.0 --port ${toString port} ${lib.escapeShellArgs extraArgs}
    '';
  };
in
{
  users.users.comfyui = {
    inherit uid;
    isSystemUser = true;
    group = "comfyui";
    home = stateDir;
  };
  users.groups.comfyui.gid = uid;

  systemd.tmpfiles.rules = map (d: "d ${stateDir}${d} 0755 comfyui comfyui -") [
    ""
    "/models" "/models/checkpoints" "/models/diffusion_models" "/models/text_encoders"
    "/models/vae" "/models/loras" "/models/upscale_models"
    "/custom_nodes" "/input" "/output" "/home" "/.local"
    "/user" "/user/default" "/user/default/workflows"
  ];

  systemd.services.comfyui = {
    description = "ComfyUI image generation (podman, GTX 1080 Ti)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nvidia-container-toolkit-cdi-generator.service" "systemd-tmpfiles-setup.service" ];
    wants = [ "network-online.target" "nvidia-container-toolkit-cdi-generator.service" ];
    serviceConfig = {
      # Same boot race as ollama (summarize.nix): /dev/nvidia-uvm appears ~2 min
      # into boot. Fail rather than start on CPU; Restart retries.
      ExecStartPre = pkgs.writeShellScript "comfyui-wait-gpu" ''
        for _ in $(${pkgs.coreutils}/bin/seq 120); do
          [ -e /dev/nvidia-uvm ] && exit 0
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "/dev/nvidia-uvm absent after 120s" >&2; exit 1
      '';
      ExecStart = "${launch}/bin/comfyui-launch";
      ExecStop = "${pkgs.podman}/bin/podman stop -t 30 comfyui";
      # Type=exec: a first start that has to build the image must not block
      # `nixos-rebuild switch` for minutes.
      Type = "exec";
      Restart = "on-failure";
      RestartSec = "15s";
      TimeoutStopSec = "60s";
    };
  };

  systemd.services.comfyui-models = {
    description = "Download pinned ComfyUI models";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "exec";   # ~50 GB on first deploy; don't hold up the switch
      ExecStart = "${fetchModels}/bin/comfyui-fetch-models";
      Restart = "on-failure";
      RestartSec = "5min";
    };
  };

  # LAN only. Not allowedTCPPorts, which would open it to every source
  # (including IPv6) — ComfyUI has no auth and Manager can install code.
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s ${lanSubnet} --dport ${toString port} -j nixos-fw-accept
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -p tcp -s ${lanSubnet} --dport ${toString port} -j nixos-fw-accept || true
  '';
}
