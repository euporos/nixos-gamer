{ pkgs, lib, ... }:

# German speech-to-text pipeline with speaker diarization.
#
#   upload:      curl -T aufnahme.m4a http://192.168.85.30:8990/
#                (or: scp aufnahme.m4a phylax@192.168.85.30:/srv/whisper/inbox/)
#   transcripts: /srv/whisper/transcripts/  (also http://192.168.85.30:8990/transcripts/)
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
    runtimeInputs = [ pkgs.podman pkgs.jq pkgs.coreutils ];
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

        if timeout 6h podman run --rm \
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
    "d /var/cache/whisperx 0770 whisper whisper -"
    "d /var/lib/whisper 0750 root whisper -"
  ];

  # Upload endpoint (LAN only, no auth — home network).
  services.nginx = {
    enable = true;
    clientMaxBodySize = "4096m";
    virtualHosts."whisper" = {
      listen = [ { addr = "0.0.0.0"; port = 8990; } ];
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
  # uploads into the inbox must be whitelisted explicitly.
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/srv/whisper/inbox" ];

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
