{ config, pkgs, lib, ... }:

# German speech-to-text pipeline with speaker diarization.
#
#   web UI:      http://192.168.85.30:8990/  (upload, live job status, cancel,
#                requeue, transcript browser — static page, no backend daemon)
#   upload:      curl -T aufnahme.m4a http://192.168.85.30:8990/
#                (or: scp aufnahme.m4a phylax@192.168.85.30:/srv/whisper/inbox/,
#                 or: copy it into the NAS drop dir .../transcriptions/_inbox/)
#   archive:     THE NAS IS THE SOURCE OF TRUTH. Everything durable lives in
#                /media/NAS/Netspace/artifacts/transcriptions/<stem>/ — the
#                source audio, every transcript format, and the summaries
#                summarize.nix writes alongside. Served read-only for the UI at
#                http://192.168.85.30:8990/transcripts/<stem>/. Nothing durable
#                is kept on the SSD: /srv/whisper is scratch (upload staging,
#                the podman job dir, UI sentinels) and can be wiped at will.
#
# Why NAS-as-truth rather than the old "local truth + delivery copy": with two
# copies, a transcript corrected by hand on the share was invisible to the
# summarizer, which re-read the untouched local original. One copy, one truth.
#
# The share is an automounted CIFS mount that can be offline (headless box, WoL)
# — so the worker probes it and no-ops when it is down, and queued audio just
# waits for the next sweep. Nothing is lost; jobs are only delayed.
#
# TWO DROP POINTS, TWO TRIGGER MECHANISMS: the local inbox is watched by a
# systemd .path unit (instant). The NAS one CANNOT be — inotify does not see
# changes another host makes over CIFS (measured on this box: inotifywait saw
# nothing when a second machine created files on the share), so .path units are
# blind to it. It is polled by the sweep timer instead, hence the 30s period.
#
# The UI has no state of its own: it polls nginx autoindex-JSON listings of
# inbox/nas-inbox/work/failed/transcripts (so jobs started via curl/scp/NAS-copy
# show up too) and requests cancel/requeue by PUTting "<name>.cancel"/
# "<name>.requeue" sentinel files into /srv/whisper/control, which the
# whisper-control path unit acts on.
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

  # THE archive root — source of truth, not a delivery copy. One folder per
  # transcript (<stem>/), plus two reserved underscore-prefixed dirs: _inbox/
  # (audio drop) and _failed/. On the automounted CIFS share, so every consumer
  # has to tolerate it being briefly absent. summarize.nix points at the same
  # path; keep the two in sync.
  nasRoot = "/media/NAS/Netspace/artifacts/transcriptions";

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
      # The NAS is the SOURCE OF TRUTH (not a delivery copy any more): every
      # durable artifact — the source audio, all transcript formats and the
      # summaries — lives in one folder per transcript under $NASROOT/<stem>/.
      # Nothing durable is kept on the SSD, so a transcript hand-edited on the
      # share is the file the summarizer later reads.
      NASROOT=${nasRoot}
      # Second audio drop point, on the share itself: copy a file in from any
      # machine and it gets transcribed. It is POLLED (the sweep timer), not
      # watched — inotify does not see remote changes on CIFS, so a systemd
      # .path unit is blind to files another host creates. Verified on this box.
      NASINBOX=$NASROOT/_inbox
      NASFAIL=$NASROOT/_failed
      # Local dirs are pure scratch now. $INBOX only stages HTTP/scp uploads
      # (atomic + fast, and it keeps working while the NAS is down); $WORK holds
      # the per-job container dir, which must stay on ext4 — bind-mounting a
      # CIFS path into podman and running WhisperX against it would be dire.
      INBOX=/srv/whisper/inbox
      WORK=/srv/whisper/work
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

      # The NAS holds every durable output, so there is nothing useful to do
      # while it is unreachable — bail out and let the 30s sweep timer retry.
      # Queued audio simply waits in whichever inbox it sits in; nothing is lost.
      # Probe by actually writing: /media/NAS/Netspace is an autofs trigger, so
      # `mountpoint` can report success on the trigger itself while the CIFS
      # mount underneath failed. A create is the only honest test.
      nas_ready() {
        mkdir -p "$NASROOT" "$NASINBOX" "$NASFAIL" 2>/dev/null || return 1
        touch "$NASROOT/.writable" 2>/dev/null || return 1
        rm -f "$NASROOT/.writable"
      }

      if ! nas_ready; then
        echo "NAS unreachable at $NASROOT — nothing to do; retrying on the next sweep"
        exit 0
      fi

      # A file may still be mid-upload (scp writes in place, and a copy onto the
      # NAS inbox from another machine lands byte by byte). Wait until its
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
      # Drain both drop points: the local staging inbox (HTTP PUT / scp) and the
      # NAS one (files copied in from any machine). Same handling either way.
      for audio in "$INBOX"/* "$NASINBOX"/*; do
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
          rm -f "$job"/L.wav "$job"/R.wav "$job"/L.json "$job"/R.json
          # $job now holds the source audio plus exactly this transcript's
          # outputs. Move the lot into the NAS folder for this stem — that
          # folder IS the archive: source audio (under its original name, so
          # any .2ch/.lang-XX marker stays visible) next to every text format,
          # and later the summaries the summarize worker writes alongside.
          # A failure here fails the job on purpose: without the NAS there is
          # nowhere to put the result, and the audio must go back in a queue.
          #
          # ORDER MATTERS: the outputs go first and the source audio LAST. The
          # share can die halfway through (it is an automounted CIFS mount on a
          # box that is off most of the time), and the audio is the only thing
          # here that cannot be regenerated — so it must stay in $job, the one
          # place the requeue below can always find it, until everything else
          # has landed. Moving it first meant a mid-move failure requeued
          # nothing (the file had already gone to $dest) and then `rm -rf $job`
          # deleted the transcripts: the job reported FAILED, nothing retried,
          # and the GPU work was lost. Partial outputs left in $dest by such a
          # failure are harmless — the retry re-transcribes and overwrites them.
          dest=$NASROOT/$outstem
          moved=1
          if mkdir -p "$dest" 2>/dev/null; then
            for f in "$job"/*; do
              # exact string compare, not a find/-name glob: stems are user
              # filenames and routinely contain brackets and spaces.
              if [ "$f" = "$job/$input" ]; then continue; fi
              mv -f "$f" "$dest"/ 2>/dev/null || { moved=0; break; }
            done
          else
            moved=0
          fi
          # Only now the audio, under its original upload name so any
          # .2ch/.lang-XX marker stays visible in the archive.
          if [ "$moved" = 1 ] && mv -f "$job/$input" "$dest/$name" 2>/dev/null; then
            rmdir "$job" 2>/dev/null || true
            echo "done: $name -> $dest/"
          else
            echo "FAILED: $name — NAS write to $dest failed (share offline?); requeueing audio"
            # Guaranteed to still be here: nothing above moves it unless every
            # output already landed. Back to the LOCAL inbox, which is always
            # writable even while the share is down.
            mv -f "$job/$input" "$INBOX/$name" 2>/dev/null || true
            rm -rf "$job"
          fi
        else
          echo "FAILED: $name — moving audio to $NASFAIL"
          mv -f "$job/$input" "$NASFAIL/$name" 2>/dev/null \
            || mv -f "$job/$input" "$INBOX/$name" 2>/dev/null || true
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
      # Queued audio can sit in either drop point (local HTTP/scp staging or the
      # NAS one); failed/cancelled audio always parks on the NAS, beside nothing
      # in particular, so a requeue is reachable from any machine.
      INBOX=/srv/whisper/inbox
      NASROOT=${nasRoot}
      NASINBOX=$NASROOT/_inbox
      FAILED=$NASROOT/_failed
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
        if { [ -f "$INBOX/$name" ] && mv "$INBOX/$name" "$FAILED/$name" 2>/dev/null; } \
           || { [ -f "$NASINBOX/$name" ] && mv "$NASINBOX/$name" "$FAILED/$name" 2>/dev/null; }; then
          echo "cancel: $name was still queued -> moved to _failed/"
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
        # Back into the NAS inbox, where the failed audio already lives — a
        # rename on the share, no copy back and forth over the wire.
        if [ -f "$FAILED/$name" ] && mv "$FAILED/$name" "$NASINBOX/$name" 2>/dev/null; then
          echo "requeue: $name -> _inbox"
        fi
      done
    '';
  };

  # One-time move of the pre-NAS-as-truth layout onto the share: the old flat
  # /srv/whisper/transcripts/<stem>.<ext>, the processed audio, and anything
  # parked in the old local failed/ dir. Deliberately NON-DESTRUCTIVE and
  # idempotent — it only copies files the NAS does not already have (most
  # transcripts were delivered there already) and never deletes or overwrites,
  # so it is safe to re-run and safe to interrupt. The old local dirs are left
  # alone for the operator to inspect and remove by hand once satisfied; see the
  # "cleanup after migration" note in CLAUDE.md.
  migrate = pkgs.writeShellApplication {
    name = "whisper-nas-migrate";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      NASROOT=${nasRoot}
      OLDOUT=/srv/whisper/transcripts
      OLDDONE=/srv/whisper/processed
      OLDFAIL=/srv/whisper/failed

      # Create the two reserved dirs unconditionally, before any early exit: the
      # UI lists them over HTTP and would otherwise report the NAS unreachable
      # until the first worker sweep created them.
      if ! { mkdir -p "$NASROOT/_inbox" "$NASROOT/_failed" 2>/dev/null \
             && touch "$NASROOT/.writable" 2>/dev/null; }; then
        echo "NAS unreachable — skipping migration, will retry on the next start"
        exit 0
      fi
      rm -f "$NASROOT/.writable"

      [ -d "$OLDOUT" ] || [ -d "$OLDDONE" ] || [ -d "$OLDFAIL" ] || exit 0

      copied=0; skipped=0

      # Derive <stem> the same way the UI's archive grouping did: strip the
      # longest known transcript/summary/notes suffix. Everything else (i.e. the
      # processed audio) keeps its full name and is filed under its basename.
      stem_of() {
        local n=$1
        case "$n" in
          *.speakers.txt) echo "''${n%.speakers.txt}" ;;
          *.notes.md)     echo "''${n%.notes.md}" ;;
          *.summary.md)   echo "''${n%.summary.md}" ;;
          *.summary.*.md) n=''${n%.md}; echo "''${n%.summary.*}" ;;
          *.txt|*.srt|*.vtt|*.tsv|*.json) echo "''${n%.*}" ;;
          *) echo "''${n%.*}" ;;
        esac
      }

      shopt -s nullglob
      for src in "$OLDOUT"/* "$OLDDONE"/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        stem=$(stem_of "$name")
        dest=$NASROOT/$stem/$name
        if [ -e "$dest" ]; then skipped=$((skipped + 1)); continue; fi
        if mkdir -p "$NASROOT/$stem" 2>/dev/null && cp -p "$src" "$dest.part" 2>/dev/null \
           && mv -n "$dest.part" "$dest" 2>/dev/null; then
          copied=$((copied + 1))
        else
          rm -f "$dest.part" 2>/dev/null || true
          echo "WARN: could not migrate $name"
        fi
      done

      # Old local failures move into the NAS _failed/ queue so the UI's requeue
      # button keeps working for them.
      for src in "$OLDFAIL"/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        if [ -e "$NASROOT/_failed/$name" ]; then skipped=$((skipped + 1)); continue; fi
        cp -p "$src" "$NASROOT/_failed/$name" && copied=$((copied + 1)) || true
      done

      echo "migration: $copied file(s) copied to $NASROOT, $skipped already present"
      echo "the old local dirs are untouched — remove them by hand once you have checked the NAS"
    '';
  };

  # Named summarization prompt presets (summarize-prompts.nix) rendered to a
  # JSON name->text map. The UI fetches it on load to populate the summarize
  # preset dropdown; the worker is untouched (a preset is just prompt text).
  # Editing that file + `nix run .#deploy` is the whole "add a prompt" workflow.
  summaryPromptsDir = pkgs.writeTextDir "prompts.json"
    (builtins.toJSON (import ./summarize-prompts.nix));

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
    # Local dirs are scratch only: inbox stages HTTP/scp uploads, work holds the
    # ext4 job dir podman bind-mounts, control carries UI sentinels. Every
    # durable artifact lives on the NAS (see the worker) — there is deliberately
    # no local transcripts/, processed/ or failed/ any more.
    "d /srv/whisper 0755 whisper whisper -"
    "d /srv/whisper/inbox 2770 whisper whisper -"
    "d /srv/whisper/work 0770 whisper whisper -"
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
      # Named summary prompt presets (summarize-prompts.nix). Exact-match so it
      # never shadows the PUT-only inbox at "/".
      locations."= /prompts.json" = {
        root = "${summaryPromptsDir}";
        tryFiles = "/prompts.json =404";
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
      # The second (NAS) drop point — audio copied onto the share from any
      # machine. The UI merges it with the local staging inbox above.
      locations."/status/nas-inbox/" = statusListing "${nasRoot}/_inbox/";
      locations."/status/work/" = statusListing "/srv/whisper/work/";
      locations."/status/failed/" = statusListing "${nasRoot}/_failed/";
      # The archive root. One directory per transcript, so this listing yields
      # DIRECTORIES; the UI lists a stem's files by requesting the subpath
      # /status/transcripts/<stem>/ — autoindex serves any depth under an alias
      # (exactly how /status/work/<jobdir>/ already works).
      locations."/status/transcripts/" = statusListing "${nasRoot}/";
      locations."/status/summaries/inbox/" = statusListing "/srv/whisper/summaries/inbox/";
      locations."/status/summaries/work/" = statusListing "/srv/whisper/summaries/work/";
      locations."/status/summaries/failed/" = statusListing "/srv/whisper/summaries/failed/";
      # Downloads/previews: /transcripts/<stem>/<file>. nginx only ever READS the
      # share — uploads still land in the local staging inbox — so this needs no
      # relaxation of the unit's ProtectSystem=strict (verified: reads are fine).
      locations."/transcripts/" = {
        alias = "${nasRoot}/";
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

  # Runs on every switch and boot, but is a no-op the moment the old local dirs
  # are gone (or already mirrored) — see the script. Ordered before the worker so
  # a sweep can't interleave with the migration of the same stem.
  systemd.services.whisper-nas-migrate = {
    description = "Migrate the pre-NAS local transcripts/processed dirs onto the share";
    wantedBy = [ "multi-user.target" ];
    before = [ "whisper-worker.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe migrate;
      TimeoutStartSec = "2h";
    };
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

  # This timer is no longer just a safety net for what the path unit misses
  # (files landing mid-run, uploads interrupted by a reboot) — it is the ONLY
  # trigger for the NAS drop dir, which inotify cannot watch (see the header).
  # Hence 30s rather than 10min: that is the pickup latency for a file copied
  # onto the share. A run over two empty inboxes is a few stat()s, and systemd
  # will not start a second instance while a transcription is still running.
  systemd.timers.whisper-worker = {
    description = "Whisper inbox sweep (and the sole trigger for the NAS drop dir)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "30s";
    };
  };
}
