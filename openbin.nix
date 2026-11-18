{ pkgs, lib, ... }:

# OpenBin — photo-based inventory of the house (workshop first), with local
# photo analysis by qwen3-vl via the GPU-lock proxy (local-llm.nix).
# Usage notes, update and restore procedure: ordnung project README.
#
#   web UI:  http://192.168.85.30:1453/   (LAN + WireGuard only)
#   data:    /var/lib/openbin  (SQLite openbin.db, photos/, .jwt_secret)
#   backup:  nightly to the NAS, see openbin-backup below
#
# Why a container and not a nix package: OpenBin isn't in nixpkgs, and it's a
# Node app with native modules (sharp, better-sqlite3). The upstream image,
# pinned by digest, is reproducible enough; updating = new digest + rebuild.
let
  port = 1453;
  lanSubnet = "192.168.85.0/24";
  dataDir = "/var/lib/openbin";
  # Release 0.2.9 (revision 30698bb, built 2026-05-06). `latest` == 0.2.9 as
  # of 2026-11-18; main also publishes per-commit "edge" tags — avoid those.
  # New digest: `skopeo inspect docker://ghcr.io/akifbayram/openbin:<ver>`.
  image = "ghcr.io/akifbayram/openbin@sha256:bdf97647a649e3473a12af844c85fa104256a158e29ef7dd03c7327118f17848";
  # Container user `node` = uid 1000; rootful podman maps it 1:1, so on the
  # host the files belong to phylax (uid 1000).
  uid = "1000";
  backupDir = "/media/NAS/Netspace/PHYLAX/Backup/openbin";
in
{
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.openbin = {
    inherit image;
    # Host network: reaches the proxy on 127.0.0.1:11435, and podman's -p
    # port publishing would DNAT past the LAN-only firewall rule (comfyui.nix).
    extraOptions = [ "--network=host" ];
    volumes = [ "${dataDir}:/data" ];
    environment = {
      PORT = toString port;
      DATABASE_PATH = "/data/openbin.db";
      PHOTO_STORAGE_PATH = "/data/photos";
      # Seeded once on first boot; the random password is printed to the
      # journal (`journalctl -u podman-openbin | grep -i password`). Change it
      # in the UI. Further users: invite from the admin account.
      ADMIN_EMAIL = "admin@inventar.local";
      REGISTRATION_MODE = "invite";

      # Several shots per container (e.g. paint cans from the side). Uploads
      # are compressed client-side to 1920 px JPEG first, so 10 MB is only
      # the cap for the raw-upload fallback.
      MAX_PHOTOS_PER_BIN = "30";
      MAX_PHOTO_SIZE_MB = "10";

      # Local AI for everything (vision + text tasks). The proxy holds the GPU
      # lock, translates to Ollama's native API and transcodes WebP -> JPEG.
      # The API key is a dummy; the proxy has no auth (bound to 127.0.0.1).
      # Fallback to Anthropic: see README ("Switch AI provider").
      AI_PROVIDER = "openai-compatible";
      AI_ENDPOINT_URL = "http://127.0.0.1:11435/v1";
      AI_MODEL = "qwen3-vl:8b-instruct";
      AI_API_KEY = "local";
      # 5 photos/request (default) x ~1k tokens fits the proxy's 16k num_ctx.
      AI_MAX_PHOTOS_PER_REQUEST = "5";

      # Plain HTTP over LAN/WireGuard, no reverse proxy. Do NOT set
      # TRUST_PROXY=true (or NODE_ENV=production): either makes the session
      # cookies `Secure`, and login over http://192.168.85.30 then silently
      # fails (401 after sign-in). Set it only once a TLS proxy is in front.
      TRUST_PROXY = "false";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 ${uid} 100 -"
    "d ${dataDir}/photos 0750 ${uid} 100 -"
  ];

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s ${lanSubnet} --dport ${toString port} -j nixos-fw-accept
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -p tcp -s ${lanSubnet} --dport ${toString port} -j nixos-fw-accept || true
  '';

  # Nightly backup to the NAS (PHYLAX share -> rsnapshot offsite to the
  # Hetzner Storage Box). The box is often off at night: Persistent=true runs
  # a missed backup at the next boot. Consistent DB copy via SQLite's online
  # backup API while OpenBin runs; photos are immutable files -> rsync.
  #   db/openbin-<date>.db   one per day, 60 kept
  #   photos/                mirror (deletions propagate; history = rsnapshot)
  #   jwt_secret             so sessions/API keys survive a restore
  systemd.services.openbin-backup = {
    description = "Back up OpenBin (SQLite + photos) to the NAS";
    after = [ "network-online.target" "podman-openbin.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.sqlite pkgs.rsync pkgs.coreutils pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      # Same uid as the container's `node` user: a root sqlite3 could leave
      # root-owned -wal/-shm files behind that OpenBin then can't open. The
      # CIFS share is mounted uid=1000, so phylax can write there too.
      User = "phylax";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    script = ''
      set -euo pipefail
      # Touching the path triggers the CIFS automount; fail loudly if the NAS
      # is away rather than writing into the empty mountpoint.
      if ! ls ${builtins.dirOf backupDir} >/dev/null 2>&1; then
        echo "NAS share not reachable, skipping"; exit 1
      fi
      mkdir -p ${backupDir}/db ${backupDir}/photos
      stamp=$(date +%F)
      tmp=$(mktemp -p ${dataDir} .backup-XXXXXX.db)
      sqlite3 ${dataDir}/openbin.db ".backup '$tmp'"
      sqlite3 "$tmp" "PRAGMA integrity_check" | grep -qx ok
      cp "$tmp" ${backupDir}/db/openbin-$stamp.db.part
      mv ${backupDir}/db/openbin-$stamp.db.part ${backupDir}/db/openbin-$stamp.db
      rm -f "$tmp"
      rsync -rt --delete ${dataDir}/photos/ ${backupDir}/photos/
      cp ${dataDir}/.jwt_secret ${backupDir}/jwt_secret
      ls -1t ${backupDir}/db/openbin-*.db | tail -n +61 | xargs -r rm -f
      echo "backup ok: $stamp, $(du -sh ${backupDir} | cut -f1)"
    '';
  };
  systemd.timers.openbin-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
  };
}
