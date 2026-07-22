{ config, pkgs, lib, ... }:

# German speech-to-text pipeline with speaker diarization.
#
#   web UI:      http://192.168.85.30:8990/  (upload, live job status, cancel,
#                requeue, transcript browser — static page, no backend daemon)
#   upload:      curl -T aufnahme.m4a http://192.168.85.30:8990/
#                (or: scp aufnahme.m4a phylax@192.168.85.30:/srv/whisper/inbox/)
#   transcripts: /srv/whisper/transcripts/  (also http://192.168.85.30:8990/transcripts/)
#                and delivered (one folder per transcript) to the NAS at
#                /media/NAS/Netspace/artifacts/transcriptions/<stem>/
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
#   3. Put HF_TOKEN=hf_... into the encrypted secrets under the "hf-token" key
#      (sops secrets/secrets.yaml — see sops.nix), then deploy. It is decrypted
#      to /run/secrets/hf-token on the box and sourced below.

let
  # Pinned to the 2024-03-17 build (torch 2.1.1): current builds of this image
  # use torch >= 2.8, whose CUDA wheels dropped Pascal (sm_61) kernels — they
  # die with "no kernel image is available" on the 1080 Ti. Newest archived
  # tag with a Pascal-capable torch:
  image = "ghcr.io/jim60105/whisperx:large-v3-de-67924da";

  # Merge two per-channel WhisperX JSONs (left/right) into one speaker-labelled
  # transcript in every output format, interleaving segments by start time.
  # Pure stdlib. Args: <left.json> <right.json> <out-dir> <stem>. A missing or
  # empty channel json (e.g. a silent side) contributes no segments.
  mergeScript = pkgs.writeText "whisper-merge.py" ''
    import json, os, sys

    def load(path, speaker):
        if not os.path.exists(path):
            return []
        with open(path) as f:
            d = json.load(f)
        out = []
        for s in d.get("segments", []):
            text = (s.get("text") or "").strip()
            if not text:
                continue
            start = float(s.get("start") or 0.0)
            out.append({
                "start": start,
                "end": float(s.get("end") or start),
                "text": text,
                "speaker": speaker,
            })
        return out

    def srt_ts(t):
        t = max(0.0, t)
        h = int(t // 3600); m = int(t % 3600 // 60); s = int(t % 60)
        ms = int(round((t - int(t)) * 1000))
        if ms == 1000:
            ms = 999
        return "%02d:%02d:%02d,%03d" % (h, m, s, ms)

    def mmss(t):
        t = int(t)
        return "%d:%02d" % (t // 60, t % 60)

    left, right, outdir, stem = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    segs = sorted(load(left, "SPEAKER_L") + load(right, "SPEAKER_R"),
                  key=lambda s: (s["start"], s["end"]))
    base = os.path.join(outdir, stem)

    with open(base + ".json", "w") as f:
        json.dump({"segments": segs}, f, ensure_ascii=False)

    with open(base + ".speakers.txt", "w") as f:
        for s in segs:
            f.write("[%s] %s: %s\n" % (mmss(s["start"]), s["speaker"], s["text"]))

    with open(base + ".txt", "w") as f:
        for s in segs:
            f.write(s["text"] + "\n")

    with open(base + ".tsv", "w") as f:
        f.write("start\tend\tspeaker\ttext\n")
        for s in segs:
            f.write("%d\t%d\t%s\t%s\n" % (round(s["start"] * 1000),
                    round(s["end"] * 1000), s["speaker"], s["text"]))

    with open(base + ".srt", "w") as f:
        for i, s in enumerate(segs, 1):
            f.write("%d\n%s --> %s\n%s: %s\n\n" % (i, srt_ts(s["start"]),
                    srt_ts(s["end"]), s["speaker"], s["text"]))

    with open(base + ".vtt", "w") as f:
        f.write("WEBVTT\n\n")
        for s in segs:
            f.write("%s --> %s\n%s: %s\n\n" % (srt_ts(s["start"]).replace(",", "."),
                    srt_ts(s["end"]).replace(",", "."), s["speaker"], s["text"]))
  '';

  worker = pkgs.writeShellApplication {
    name = "whisper-worker";
    runtimeInputs = [ pkgs.podman pkgs.jq pkgs.coreutils pkgs.curl pkgs.ffmpeg pkgs.python3 pkgs.util-linux ];
    text = ''
      IMAGE=${lib.escapeShellArg image}
      INBOX=/srv/whisper/inbox
      WORK=/srv/whisper/work
      OUT=/srv/whisper/transcripts
      DONE=/srv/whisper/processed
      FAIL=/srv/whisper/failed
      # NAS delivery target: one folder per transcript. Automounted CIFS share
      # (configuration.nix), so it may be offline — delivery is best-effort and
      # never fails a job; $OUT stays the local source of truth for the web UI.
      NAS=/media/NAS/Netspace/artifacts/transcriptions
      # HF token (HF_TOKEN=hf_... line), decrypted from the repo by sops-nix
      # to /run/secrets/hf-token at activation (see sops.nix). Sourced below.
      TOKEN_FILE=${config.sops.secrets."hf-token".path}

      # Read the token WITHOUT sourcing it. The value is secret and may contain
      # shell metacharacters () > | etc. — `. "$TOKEN_FILE"` would parse those
      # and abort the whole worker (took down plain transcription too, not just
      # diarization). Read the first line verbatim and strip an optional
      # HF_TOKEN= prefix; pure bash, no shell interpretation of the value.
      HF_TOKEN=""
      if [ -f "$TOKEN_FILE" ]; then
        IFS= read -r HF_TOKEN < "$TOKEN_FILE" || true
        HF_TOKEN=''${HF_TOKEN#HF_TOKEN=}
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

      # One WhisperX container pass over the current job. Callers set $name/$job
      # first (dynamic scope). The fixed container name keeps cancel working —
      # the worker is strictly serial, so only one job container ever exists.
      #
      # flock serializes GPU use with the summarizer (Ollama/Qwen3, summarize.nix):
      # the 1080 Ti's 11 GB can't hold a whisper model and the ~9 GB LLM at once.
      # Both sides take an exclusive lock on /run/whisper-gpu.lock (created by
      # tmpfiles in summarize.nix). The lock is held only for this one container
      # run, so a pending summary can slip in between queued jobs.
      run_whisperx() {
        flock /run/whisper-gpu.lock \
          timeout 6h podman run --rm --replace \
          --name whisper-job --label "file=$name" \
          --device nvidia.com/gpu=all \
          -v "$job:/app" \
          -v /var/cache/whisperx:/.cache \
          "$IMAGE" -- "$@"
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
        echo "picking up: $name"
        if ! wait_until_stable "$audio"; then
          echo "giving up on $name — size never stabilized (upload stalled?)"
          continue
        fi

        # Markers appended before the extension (by the web UI or curl) route
        # the job. ".2ch" = transcribe the left/right channels separately and
        # merge, so speaker labels are exact without pyannote diarization.
        # ".lang-XX" = force the transcription language (de/en/ru/fr). Strip any
        # recognised trailing markers, in any order; language defaults to German
        # (the image also bakes --language de, which our flag overrides). All
        # markers are stripped from output names.
        stem=''${name%.*}
        ext=''${name##*.}
        dual=0
        lang=de
        outstem=$stem
        while :; do
          case "$outstem" in
            *.2ch)     dual=1; outstem=''${outstem%.2ch} ;;
            *.lang-de) lang=de; outstem=''${outstem%.lang-de} ;;
            *.lang-en) lang=en; outstem=''${outstem%.lang-en} ;;
            *.lang-ru) lang=ru; outstem=''${outstem%.lang-ru} ;;
            *.lang-fr) lang=fr; outstem=''${outstem%.lang-fr} ;;
            *) break ;;
          esac
        done
        echo "routing $name: language=$lang dual=$dual"
        # Give the working copy the marker-free name so outputs are clean.
        input=$name
        if [ "$outstem" != "$stem" ]; then input="$outstem.$ext"; fi

        job=$(mktemp -d "$WORK/job.XXXXXX")
        mv "$audio" "$job/$input"

        if [ "$dual" = 1 ]; then
          nch=$(ffprobe -v error -select_streams a:0 \
                  -show_entries stream=channels -of csv=p=0 "$job/$input" || echo 0)
          if [ "$nch" = 2 ]; then
            echo "dual-channel: splitting $name into L/R (16 kHz mono)"
            ffmpeg -nostdin -y -loglevel error -i "$job/$input" \
              -filter_complex "[0:a]channelsplit=channel_layout=stereo[l][r]" \
              -map "[l]" -ar 16000 -c:a pcm_s16le "$job/L.wav" \
              -map "[r]" -ar 16000 -c:a pcm_s16le "$job/R.wav"
          else
            echo "note: $name marked .2ch but has $nch channel(s) — transcribing normally"
            dual=0
          fi
        fi

        # uid 1001 == our 'whisper' user == the container's non-root user
        chown -R whisper:whisper "$job"
        chmod 770 "$job"

        ok=1
        if [ "$dual" = 1 ]; then
          # One WhisperX pass per channel (json only) — each channel is a single
          # known speaker, so diarization is neither needed nor run.
          if run_whisperx --compute_type int8 --output_format json --output_dir /app --language "$lang" L.wav \
             && run_whisperx --compute_type int8 --output_format json --output_dir /app --language "$lang" R.wav; then
            python3 ${mergeScript} "$job/L.json" "$job/R.json" "$job" "$outstem"
          else
            ok=0
          fi
        else
          args=(--compute_type int8 --output_format all --output_dir /app --language "$lang")
          if [ -n "$HF_TOKEN" ]; then
            args+=(--diarize --hf_token "$HF_TOKEN")
          else
            echo "note: no HF token in $TOKEN_FILE — transcribing WITHOUT speaker diarization"
          fi
          if run_whisperx "''${args[@]}" "$input"; then
            # Distill a readable speaker-labelled transcript out of the json.
            if [ -f "$job/$outstem.json" ]; then
              jq -r '
                .segments[]
                | ((.start // 0) | floor) as $t
                | "[\(($t / 60) | floor):\(("0" + (($t % 60) | tostring)) | .[-2:])] \(.speaker // "SPEAKER_?"): \(.text | sub("^\\s+"; ""))"
              ' "$job/$outstem.json" > "$job/$outstem.speakers.txt" || true
            fi
          else
            ok=0
          fi
        fi

        if [ "$ok" = 1 ]; then
          mv "$job/$input" "$DONE/$name"
          rm -f "$job"/L.wav "$job"/R.wav "$job"/L.json "$job"/R.json
          # $job now holds exactly this transcript's output files. Deliver a
          # copy to the NAS, one folder per transcript (best-effort: the share
          # is an automounted CIFS mount that may be offline — never fail the
          # job over it, the local $OUT copy is kept and can be re-synced).
          dest=$NAS/$outstem
          if mkdir -p "$dest" 2>/dev/null && cp -f "$job"/* "$dest"/ 2>/dev/null; then
            echo "delivered: $name -> $dest/"
          else
            echo "WARN: NAS delivery to $dest failed (share offline?) — local copy kept in $OUT"
          fi
          find "$job" -mindepth 1 -maxdepth 1 -exec mv -t "$OUT" {} +
          rmdir "$job"
          echo "done: $name -> $OUT/$outstem.*"
        else
          echo "FAILED: $name — moving audio to $FAIL"
          mv "$job/$input" "$FAIL/$name" || true
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
      # uploads to /<name> still hit the inbox location below. try_files
      # (not alias-to-file or index) because it serves within this location:
      # an index internal-redirect would re-match into the PUT-only location.
      locations."= /" = {
        root = "${./whisper-ui}";
        tryFiles = "/index.html =404";
        extraConfig = ''
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
      # Summarization job intake (async, file-driven — see summarize.nix). The UI
      # PUTs a JSON job spec to /summaries/inbox/<jobid>.json and cancel sentinels
      # to /summaries/control/<jobid>.cancel; root maps the URL straight onto the
      # tmpfiles dirs, exactly like /control/ above (no dav+alias pitfall).
      locations."/summaries/inbox/" = {
        root = "/srv/whisper";
        extraConfig = ''
          dav_methods PUT;
          create_full_put_path off;
          limit_except PUT { deny all; }
        '';
      };
      locations."/summaries/control/" = {
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
      locations."/status/summaries/inbox/" = statusListing "/srv/whisper/summaries/inbox/";
      locations."/status/summaries/work/" = statusListing "/srv/whisper/summaries/work/";
      locations."/status/summaries/failed/" = statusListing "/srv/whisper/summaries/failed/";
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
  # uploads into the inbox/control dirs must be whitelisted explicitly. This
  # covers both the audio inbox/control and the summary job inbox/control.
  systemd.services.nginx.serviceConfig.ReadWritePaths = [
    "/srv/whisper/inbox"
    "/srv/whisper/control"
    "/srv/whisper/summaries/inbox"
    "/srv/whisper/summaries/control"
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
