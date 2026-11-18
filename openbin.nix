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

  # Injected UI fixes (index.html, see postStart below). 1) Capture page
  # (/capture) keeps shots only in browser memory; an accidental
  # pull-to-refresh while scrolling wipes them, and OpenBin has
  # no unsaved-changes guard. This script, injected into index.html, turns
  # off pull-to-refresh there (overscroll-behavior) and asks before
  # reload/close while blob: thumbnails are on screen. External file, not
  # inline: OpenBin's CSP pins its inline scripts by hash, 'self' is allowed.
  # beforeunload is ignored by iOS Safari; the overscroll part still works.
  # 2) Camera option for "Add Photo" on phones (see the comment in the JS).
  captureGuard = pkgs.writeText "openbin-capture-guard.js" ''
    (function () {
      function onCapture() { return location.pathname.indexOf("/capture") === 0; }
      function unsaved() { return onCapture() && !!document.querySelector('img[src^="blob:"]'); }
      addEventListener("beforeunload", function (e) {
        if (unsaved()) { e.preventDefault(); e.returnValue = ""; }
      });
      function sync() {
        var v = onCapture() ? "contain" : "";
        document.documentElement.style.overscrollBehaviorY = v;
        if (document.body) document.body.style.overscrollBehaviorY = v;
      }
      sync();
      setInterval(sync, 500); // SPA route changes don't reload the page

      // "Add Photo" is <input type=file accept=image multiple> without
      // `capture`; Android then opens only the photo picker, no camera. OpenBin
      // opens these inputs via ref.click(), so wrap click(): on touch devices
      // offer Take photo (capture=environment -> camera app) / Gallery. The
      // file still lands in OpenBin's own input, so its upload code runs.
      var origClick = HTMLInputElement.prototype.click;
      function isPhotoInput(el) {
        return el.type === "file" && /image/.test(el.accept || "");
      }
      function coarse() { return matchMedia("(pointer: coarse)").matches; }
      function chooser(input) {
        var bg = document.createElement("div");
        bg.style.cssText = "position:fixed;inset:0;z-index:2147483647;" +
          "background:rgba(0,0,0,.45);display:flex;align-items:flex-end;justify-content:center";
        var box = document.createElement("div");
        box.style.cssText = "width:100%;max-width:480px;display:flex;flex-direction:column;gap:8px;" +
          "padding:12px 12px calc(16px + env(safe-area-inset-bottom))";
        function btn(label, primary, fn) {
          var b = document.createElement("button");
          b.type = "button";
          b.textContent = label;
          b.style.cssText = "font:600 17px system-ui,sans-serif;padding:16px;border:0;border-radius:14px;" +
            (primary ? "background:#0a84ff;color:#fff" : "background:#f2f2f7;color:#000");
          b.addEventListener("click", function (e) {
            e.stopPropagation();
            bg.remove();
            if (fn) fn();
          });
          box.appendChild(b);
        }
        btn("Take photo", true, function () {
          input.setAttribute("capture", "environment");
          origClick.call(input);
          setTimeout(function () { input.removeAttribute("capture"); }, 1000);
        });
        btn("Choose from gallery", false, function () {
          input.removeAttribute("capture");
          origClick.call(input);
        });
        btn("Cancel", false, null);
        bg.addEventListener("click", function () { bg.remove(); });
        bg.appendChild(box);
        document.body.appendChild(bg);
      }
      HTMLInputElement.prototype.click = function () {
        if (isPhotoInput(this) && coarse()) { chooser(this); return; }
        return origClick.apply(this, arguments);
      };
    })();
  '';
in
{
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.openbin = {
    inherit image;
    # Host network: reaches the proxy on 127.0.0.1:11435, and podman's -p
    # port publishing would DNAT past the LAN-only firewall rule (comfyui.nix).
    extraOptions = [ "--network=host" ];
    volumes = [
      "${dataDir}:/data"
      "${captureGuard}:/app/public/openbin-capture-guard.js:ro"
    ];
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
      # One photo per shelf row (paint cans). Measured ~0.5-0.85k tokens per
      # 1024 px photo + ~1.3k base prompt: 20 photos ~ 18-24k, fits the
      # proxy's 32k LLM_PROXY_VISION_NUM_CTX (local-llm.nix) — raise together.
      AI_MAX_PHOTOS_PER_REQUEST = "20";

      # Plain HTTP over LAN/WireGuard, no reverse proxy. Do NOT set
      # TRUST_PROXY=true (or NODE_ENV=production): either makes the session
      # cookies `Secure`, and login over http://192.168.85.30 then silently
      # fails (401 after sign-in). Set it only once a TLS proxy is in front.
      TRUST_PROXY = "false";
    };
  };

  # Hook the guard into index.html. The container is recreated on every
  # start (--rm), so patch each time; idempotent. If a new OpenBin release
  # drops `</head>` from index.html the grep check fails the unit loudly.
  systemd.services.podman-openbin.postStart = ''
    for i in $(seq 1 30); do
      ${pkgs.podman}/bin/podman exec openbin true 2>/dev/null && break
      sleep 1
    done
    ${pkgs.podman}/bin/podman exec -u 0 openbin sh -c '
      f=/app/public/index.html
      grep -q openbin-capture-guard "$f" ||
        sed -i "s|</head>|<script src=\"/openbin-capture-guard.js\"></script></head>|" "$f"
      grep -q openbin-capture-guard "$f"'
  '';

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
