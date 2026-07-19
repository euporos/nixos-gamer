{ pkgs, lib, ... }:

# German speech-to-text pipeline with speaker diarization.
#
#   web UI:      http://192.168.85.30:8990/  (upload, live job status, cancel,
#                requeue, transcript browser — static page, no backend daemon)
#   upload:      curl -T aufnahme.m4a http://192.168.85.30:8990/
#                (or: scp aufnahme.m4a phylax@192.168.85.30:/srv/whisper/inbox/)
#   transcripts: /srv/whisper/transcripts/  (also http://192.168.85.30:8990/transcripts/)
#
# The UI has no state of its own: it polls nginx autoindex-JSON listings of
# inbox/work/failed/transcripts (so jobs started via curl/scp show up too) and
# requests cancel/requeue by PUTting "<name>.cancel"/"<name>.requeue" sentinel
# files into /srv/whisper/control, which the whisper-control path unit acts on.
#
# nginx PUTs uploads atomically into /srv/whisper/inbox; a systemd path unit
# fires the worker, which runs WhisperX (faster-whisper large-v3, German
# alignment, pyannote diarization) in a one-shot GPU container per file, so no
# VRAM is held between jobs. The ghcr.io/jim60105/whisperx images deliberately
# stay on a Pascal-compatible torch build — required for the GTX 1080 Ti,
# which PyTorch >= 2.8 wheels no longer support. --compute_type int8 because
# Pascal (sm_61) has no usable fp16 but does have dp4a int8.
#
# Speaker diarization needs a Hugging Face token (the pyannote models are
# gated). Without one the worker still transcribes, just without speakers:
#   1. Accept the terms of hf.co/pyannote/speaker-diarization-3.1
#      and hf.co/pyannote/segmentation-3.0
#   2. Create a read token at hf.co/settings/tokens
#   3. On the box:  echo 'HF_TOKEN=hf_...' > /var/lib/whisper/hf-token.env  (as root)

let
  # Pinned to the 2024-03-17 build (torch 2.1.1): current builds of this image
  # use torch >= 2.8, whose CUDA wheels dropped Pascal (sm_61) kernels — they
  # die with "no kernel image is available" on the 1080 Ti. Newest archived
  # tag with a Pascal-capable torch:
  image = "ghcr.io/jim60105/whisperx:large-v3-de-67924da";

  worker = pkgs.writeShellApplication {
    name = "whisper-worker";
    runtimeInputs = [ pkgs.podman pkgs.jq pkgs.coreutils pkgs.curl ];
    text = ''
      IMAGE=${lib.escapeShellArg image}
      INBOX=/srv/whisper/inbox
      WORK=/srv/whisper/work
      OUT=/srv/whisper/transcripts
      DONE=/srv/whisper/processed
      FAIL=/srv/whisper/failed
      TOKEN_FILE=/var/lib/whisper/hf-token.env

      HF_TOKEN=""
      if [ -f "$TOKEN_FILE" ]; then
        # shellcheck disable=SC1090
        . "$TOKEN_FILE"
      fi

      # A file may still be mid-upload (scp writes in place). Wait until its
      # size has been stable for 5s; give up after ~1h.
      wait_until_stable() {
        local f=$1 prev=-1 size tries=0
        while :; do
          size=$(stat -c %s "$f" 2>/dev/null) || return 1
          if [ "$size" = "$prev" ] && [ "$size" != "0" ]; then return 0; fi
          prev=$size
          tries=$((tries + 1))
          if [ "$tries" -gt 720 ]; then return 1; fi
          sleep 5
        done
      }

      # The whisperx in the pinned image downloads its VAD model from an S3
      # bucket that no longer exists (Access Denied since 2025). Seed the
      # byte-identical file (vad.py verifies this sha256) from the current
      # whisperX repo, which bundles it as a package asset.
      VAD_SHA=0b5b3216d60a2d32fc086b47ea8c67589aaeb26b7e07fcbe620d6d0b83e209ea
      VAD_FILE=/var/cache/whisperx/torch/whisperx-vad-segmentation.bin
      if [ ! -f "$VAD_FILE" ]; then
        mkdir -p /var/cache/whisperx/torch
        curl -fsSL -o "$VAD_FILE.tmp" \
          "https://github.com/m-bain/whisperX/raw/main/whisperx/assets/pytorch_model.bin"
        echo "$VAD_SHA  $VAD_FILE.tmp" | sha256sum -c -
        mv "$VAD_FILE.tmp" "$VAD_FILE"
        chown -R whisper:whisper /var/cache/whisperx
      fi

      shopt -s nullglob
      for audio in "$INBOX"/*; do
        [ -f "$audio" ] || continue
        name=$(basename "$audio")
        stem=''${name%.*}
        echo "picking up: $name"
        if ! wait_until_stable "$audio"; then
          echo "giving up on $name — size never stabilized (upload stalled?)"
          continue
        fi

        job=$(mktemp -d "$WORK/job.XXXXXX")
        mv "$audio" "$job/$name"
        # uid 1001 == our 'whisper' user == the container's non-root user
        chown -R whisper:whisper "$job"
        chmod 770 "$job"

        args=(--compute_type int8 --output_format all --output_dir /app)
        if [ -n "$HF_TOKEN" ]; then
          args+=(--diarize --hf_token "$HF_TOKEN")
        else
          echo "note: no HF token in $TOKEN_FILE — transcribing WITHOUT speaker diarization"
        fi

        # Fixed container name: the worker is strictly serial, so only one job
        # container ever exists. whisper-control kills it by name to cancel;
        # the label lets it verify which file the container is working on.
        # --replace clears a leftover container after an unclean shutdown.
        if timeout 6h podman run --rm --replace \
            --name whisper-job --label "file=$name" \
            --device nvidia.com/gpu=all \
            -v "$job:/app" \
            -v /var/cache/whisperx:/.cache \
            "$IMAGE" -- "''${args[@]}" "$name"; then
          # Distill a readable speaker-labelled transcript out of the json.
          if [ -f "$job/$stem.json" ]; then
            jq -r '
              .segments[]
              | ((.start // 0) | floor) as $t
              | "[\(($t / 60) | floor):\(("0" + (($t % 60) | tostring)) | .[-2:])] \(.speaker // "SPEAKER_?"): \(.text | sub("^\\s+"; ""))"
            ' "$job/$stem.json" > "$job/$stem.speakers.txt" || true
          fi
          mv "$job/$name" "$DONE/$name"
          find "$job" -mindepth 1 -maxdepth 1 -exec mv -t "$OUT" {} +
          rmdir "$job"
          echo "done: $name -> $OUT/$stem.*"
        else
          echo "FAILED: $name — moving audio to $FAIL"
          mv "$job/$name" "$FAIL/$name" || true
          rm -rf "$job"
        fi
      done
    '';
  };

  # Acts on sentinel files the web UI PUTs into /srv/whisper/control:
  #   <name>.cancel   kill the job for <name> — queued (mv inbox -> failed)
  #                   or already running (podman kill the job container)
  #   <name>.requeue  move failed/<name> back into the inbox
  # Sentinels are always consumed, even when nothing matches — a path unit on
  # DirectoryNotEmpty would otherwise re-trigger forever.
  control = pkgs.writeShellApplication {
    name = "whisper-control";
    runtimeInputs = [ pkgs.podman pkgs.coreutils ];
    text = ''
      INBOX=/srv/whisper/inbox
      FAILED=/srv/whisper/failed
      CONTROL=/srv/whisper/control

      current_job() {
        podman inspect whisper-job \
          --format '{{ index .Config.Labels "file" }}' 2>/dev/null || true
      }

      shopt -s nullglob
      for s in "$CONTROL"/*.cancel; do
        name=$(basename "''${s%.cancel}")
        rm -f "$s"
        echo "cancel requested: $name"
        # If the worker snatches the file between test and mv, fall through
        # to the container poll instead of failing.
        if [ -f "$INBOX/$name" ] && mv "$INBOX/$name" "$FAILED/$name" 2>/dev/null; then
          echo "cancel: $name was still queued -> moved to failed/"
          continue
        fi
        # The worker may be between picking the file up and starting the
        # container — poll briefly for the container to appear before giving up.
        for _ in $(seq 1 10); do
          if [ "$(current_job)" = "$name" ]; then
            echo "cancel: killing container for $name"
            podman kill whisper-job || true
            break
          fi
          sleep 2
        done
      done

      for s in "$CONTROL"/*.requeue; do
        name=$(basename "''${s%.requeue}")
        rm -f "$s"
        if [ -f "$FAILED/$name" ] && mv "$FAILED/$name" "$INBOX/$name" 2>/dev/null; then
          echo "requeue: $name -> inbox"
        fi
      done
    '';
  };

  # Read-only JSON directory listing for the UI's status polling.
  statusListing = dir: {
    alias = dir;
    extraConfig = ''
      autoindex on;
      autoindex_format json;
      add_header Cache-Control "no-cache";
    '';
  };
in
{
  virtualisation.podman.enable = true;

  users.groups.whisper.members = [ "nginx" "phylax" ];
  users.users.whisper = {
    isSystemUser = true;
    # Fixed at 1001 so bind-mounted job dirs line up with the container's
    # non-root user (uid 1001) under rootful podman.
    uid = 1001;
    group = "whisper";
    home = "/srv/whisper";
  };

  systemd.tmpfiles.rules = [
    "d /srv/whisper 0755 whisper whisper -"
    "d /srv/whisper/inbox 2770 whisper whisper -"
    "d /srv/whisper/work 0770 whisper whisper -"
    "d /srv/whisper/transcripts 2775 whisper whisper -"
    "d /srv/whisper/processed 2770 whisper whisper -"
    "d /srv/whisper/failed 2770 whisper whisper -"
    "d /srv/whisper/control 2770 whisper whisper -"
    "d /var/cache/whisperx 0770 whisper whisper -"
    "d /var/lib/whisper 0750 root whisper -"
  ];

  # Upload endpoint (LAN only, no auth — home network).
  services.nginx = {
    enable = true;
    clientMaxBodySize = "4096m";
    virtualHosts."whisper" = {
      listen = [ { addr = "0.0.0.0"; port = 8990; } ];
      # The web UI — one self-contained page. Exact-match only, so PUT
      # uploads to /<name> still hit the inbox location below.
      locations."= /" = {
        alias = "${./whisper-ui/index.html}";
        extraConfig = ''
          default_type text/html;
          add_header Cache-Control "no-cache";
        '';
      };
      # PUT /<name> lands atomically in the inbox (nginx writes to a temp
      # file and renames — the worker never sees partial uploads).
      locations."/" = {
        root = "/srv/whisper/inbox";
        extraConfig = ''
          dav_methods PUT;
          create_full_put_path off;
          limit_except PUT { deny all; }
        '';
      };
      # Cancel/requeue channel: the UI PUTs empty <name>.cancel / <name>.requeue
      # sentinels here; the whisper-control path unit reacts to them.
      locations."/control/" = {
        root = "/srv/whisper";
        extraConfig = ''
          dav_methods PUT;
          create_full_put_path off;
          limit_except PUT { deny all; }
        '';
      };
      # JSON listings the UI polls to derive job state — covers jobs started
      # from the CLI too, since they are just files in these directories.
      locations."/status/inbox/" = statusListing "/srv/whisper/inbox/";
      locations."/status/work/" = statusListing "/srv/whisper/work/";
      locations."/status/failed/" = statusListing "/srv/whisper/failed/";
      locations."/status/transcripts/" = statusListing "/srv/whisper/transcripts/";
      locations."/transcripts/" = {
        alias = "/srv/whisper/transcripts/";
        extraConfig = ''
          autoindex on;
          charset utf-8;
        '';
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ 8990 ];

  # The NixOS nginx unit runs with ProtectSystem=strict — writing PUT
  # uploads into the inbox/control dirs must be whitelisted explicitly.
  systemd.services.nginx.serviceConfig.ReadWritePaths = [
    "/srv/whisper/inbox"
    "/srv/whisper/control"
  ];

  systemd.services.whisper-worker = {
    description = "Transcribe audio from /srv/whisper/inbox via WhisperX";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe worker;
      TimeoutStartSec = "12h";
    };
  };

  systemd.paths.whisper-worker = {
    description = "Watch the whisper inbox for new uploads";
    wantedBy = [ "multi-user.target" ];
    pathConfig.DirectoryNotEmpty = "/srv/whisper/inbox";
  };

  systemd.services.whisper-control = {
    description = "Apply cancel/requeue sentinels from /srv/whisper/control";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe control;
      # cancel may poll up to ~20s for the job container to appear
      TimeoutStartSec = "5min";
    };
  };

  systemd.paths.whisper-control = {
    description = "Watch the whisper control dir for cancel/requeue sentinels";
    wantedBy = [ "multi-user.target" ];
    pathConfig.DirectoryNotEmpty = "/srv/whisper/control";
  };

  # Sweeper for anything the path unit misses (files landing mid-run,
  # uploads interrupted by a reboot).
  systemd.timers.whisper-worker = {
    description = "Periodic whisper inbox sweep";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "10min";
    };
  };
}
